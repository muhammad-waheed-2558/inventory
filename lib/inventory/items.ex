defmodule Inventory.Items do
  @moduledoc """
  Context module — the public boundary for all inventory DB operations.

  This is the single source of truth. The `Inventory.Store` GenServer only
  manages reservation timers (Process.send_after); it never holds item state.

  After every mutation we broadcast on the `"inventory"` PubSub topic so
  LiveView subscribers can update in real time.
  """

  import Ecto.Query, warn: false

  alias Inventory.Repo
  alias Inventory.{Item, Reservation}

  @pubsub Inventory.PubSub
  @topic "inventory"
  @low_stock_threshold 10

  # ─────────────────────────────────────────────────────────────
  # PubSub helpers
  # ─────────────────────────────────────────────────────────────

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  end

  # ─────────────────────────────────────────────────────────────
  # Item CRUD
  # ─────────────────────────────────────────────────────────────

  def list_items do
    Repo.all(from i in Item, order_by: [asc: i.id])
  end

  def get_item!(id), do: Repo.get!(Item, id)

  def get_item(id), do: Repo.get(Item, id)

  def create_item(attrs) do
    %Item{}
    |> Item.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&broadcast({:item_created, &1}))
  end

  def update_item(%Item{} = item, attrs) do
    item
    |> Item.update_changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast({:item_updated, &1}))
  end

  def delete_item(%Item{} = item) do
    Repo.delete(item)
    |> tap_ok(fn _ -> broadcast({:item_deleted, item.id}) end)
  end

  def change_item(%Item{} = item, attrs \\ %{}) do
    Item.changeset(item, attrs)
  end

  # ─────────────────────────────────────────────────────────────
  # Stock operations
  # ─────────────────────────────────────────────────────────────

  @doc """
  Adjust stock by `delta` (positive = restock, negative = sell).
  Uses a DB transaction to read-then-write atomically.
  """
  def update_stock(%Item{} = item, delta) when is_integer(delta) do
    Repo.transaction(fn ->
      # Re-fetch inside transaction with a row lock
      fresh = Repo.get!(Item, item.id)
      new_qty = fresh.quantity + delta

      cond do
        new_qty < 0 ->
          Repo.rollback(:insufficient_stock)

        new_qty < fresh.reserved_qty ->
          Repo.rollback(:insufficient_stock)

        true ->
          {:ok, updated} =
            fresh
            |> Ecto.Changeset.change(quantity: new_qty)
            |> Repo.update()

          updated
      end
    end)
    |> tap_ok(&broadcast({:item_updated, &1}))
  end

  # ─────────────────────────────────────────────────────────────
  # Reservations
  # ─────────────────────────────────────────────────────────────

  @doc """
  Create a reservation for `quantity` units of `item_id`.
  `timeout_ms` controls how long the reservation is valid.

  Returns `{:ok, reservation}` or `{:error, reason}`.
  The caller should then call `Store.track_reservation/2` to
  start the expiry timer.
  """
  def create_reservation(item_id, quantity, timeout_ms) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(timeout_ms, :millisecond)
      |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      item = Repo.get!(Item, item_id)
      available = Item.available(item)

      if available < quantity do
        Repo.rollback(:insufficient_stock)
      else
        # Atomically bump reserved_qty
        {:ok, _} =
          item
          |> Ecto.Changeset.change(reserved_qty: item.reserved_qty + quantity)
          |> Repo.update()

        {:ok, reservation} =
          %Reservation{}
          |> Reservation.changeset(%{
            item_id: item_id,
            quantity: quantity,
            expires_at: expires_at
          })
          |> Repo.insert()

        Repo.preload(reservation, :item)
      end
    end)
    |> tap_ok(&broadcast({:reservation_created, &1}))
  end

  @doc "Confirm a reservation: deduct stock permanently, mark confirmed."
  def confirm_reservation(reservation_id) do
    Repo.transaction(fn ->
      reservation = Repo.get!(Reservation, reservation_id) |> Repo.preload(:item)

      if reservation.status != "pending" do
        Repo.rollback({:invalid_status, reservation.status})
      else
        item = reservation.item

        {:ok, _item} =
          item
          |> Ecto.Changeset.change(
            quantity: item.quantity - reservation.quantity,
            reserved_qty: item.reserved_qty - reservation.quantity
          )
          |> Repo.update()

        {:ok, updated} =
          reservation
          |> Ecto.Changeset.change(status: "confirmed")
          |> Repo.update()

        updated
      end
    end)
    |> tap_ok(&broadcast({:reservation_confirmed, &1}))
  end

  @doc "Cancel a reservation: release reserved stock, mark cancelled."
  def cancel_reservation(reservation_id) do
    Repo.transaction(fn ->
      reservation = Repo.get!(Reservation, reservation_id) |> Repo.preload(:item)

      if reservation.status != "pending" do
        Repo.rollback({:invalid_status, reservation.status})
      else
        item = reservation.item

        {:ok, _} =
          item
          |> Ecto.Changeset.change(reserved_qty: item.reserved_qty - reservation.quantity)
          |> Repo.update()

        {:ok, updated} =
          reservation
          |> Ecto.Changeset.change(status: "cancelled")
          |> Repo.update()

        updated
      end
    end)
    |> tap_ok(&broadcast({:reservation_cancelled, &1}))
  end

  @doc "Called by Store GenServer when a reservation timer fires."
  def expire_reservation(reservation_id) do
    Repo.transaction(fn ->
      reservation = Repo.get(Reservation, reservation_id)

      # Guard: may have been confirmed/cancelled before timer fired
      if reservation && reservation.status == "pending" do
        reservation = Repo.preload(reservation, :item)
        item = reservation.item

        {:ok, _} =
          item
          |> Ecto.Changeset.change(reserved_qty: item.reserved_qty - reservation.quantity)
          |> Repo.update()

        {:ok, updated} =
          reservation
          |> Ecto.Changeset.change(status: "expired")
          |> Repo.update()

        updated
      end
    end)
    |> tap_ok(fn reservation ->
      if reservation, do: broadcast({:reservation_expired, reservation})
    end)
  end

  def list_reservations_for_item(item_id) do
    Repo.all(
      from r in Reservation,
        where: r.item_id == ^item_id,
        order_by: [desc: r.inserted_at]
    )
  end

  def list_pending_reservations do
    Repo.all(from r in Reservation, where: r.status == "pending", preload: [:item])
  end

  # ─────────────────────────────────────────────────────────────
  # Stats + low-stock
  # ─────────────────────────────────────────────────────────────

  def stats do
    total_items = Repo.aggregate(Item, :count)

    total_stock =
      Repo.aggregate(Item, :sum, :quantity) || 0

    low_stock_count =
      Repo.aggregate(
        from(i in Item, where: i.quantity - i.reserved_qty <= ^@low_stock_threshold),
        :count
      )

    active_reservations =
      Repo.aggregate(from(r in Reservation, where: r.status == "pending"), :count)

    %{
      total_items: total_items,
      total_stock: total_stock,
      low_stock_count: low_stock_count,
      active_reservations: active_reservations
    }
  end

  def list_low_stock(threshold \\ @low_stock_threshold) do
    Repo.all(
      from i in Item,
        where: i.quantity - i.reserved_qty <= ^threshold,
        order_by: [asc: i.quantity]
    )
  end

  def low_stock_threshold, do: @low_stock_threshold

  # ─────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────

  defp tap_ok({:ok, val} = result, fun) do
    fun.(val)
    result
  end

  defp tap_ok(result, _fun), do: result
end

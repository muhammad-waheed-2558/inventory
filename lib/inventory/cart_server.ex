defmodule Inventory.CartServer do
  @moduledoc """
  GenServer representing a single shopping cart.

  One process per cart — carts are isolated, can't interfere with each other,
  and each has its own TTL timer. This is the "one process per entity" OTP
  pattern, sometimes called the "actor per resource" pattern.

  ## New GenServer concepts demonstrated

  ### Registry + via tuples
  Instead of a global atom name, each CartServer is registered under its
  `cart_id` in a `Registry`. The `via_tuple/1` helper builds the special
  `{:via, Registry, {registry, key}}` name that GenServer understands.

  This enables:
  - Finding a cart's pid from any process by cart_id
  - Guaranteeing at most one process per cart_id (unique registry)
  - O(log n) lookups instead of a manual pid-tracking map

  ### DynamicSupervisor lifecycle
  Carts are started with `CartSupervisor.start_cart/1` which calls
  `DynamicSupervisor.start_child/2`. The supervisor automatically restarts
  crashed carts. When a cart finishes normally (checkout or TTL), it stops
  with `:normal` and the supervisor does NOT restart it.

  ### TTL via Process.send_after + activity reset
  The cart auto-expires after `@ttl_ms` of inactivity. Each `add_item/3` or
  `remove_item/3` call cancels the old timer and starts a fresh one — a
  "sliding window" TTL. On expiry the process stops normally and the
  supervisor removes it from its child list.

  ### Atomic multi-item checkout with rollback
  `checkout/1` calls `Items.create_reservation/3` for each cart item.
  If any item is out of stock, already-created reservations are rolled back
  using `Items.cancel_reservation/1` before returning an error.

  ## State

      %{
        cart_id:   String.t(),
        items:     %{item_id => quantity},
        timer_ref: reference()
      }

  ## Usage

      # Get or create a cart:
      {:ok, _pid} = Inventory.CartServer.get_or_create("user-123")

      # Add items:
      :ok = Inventory.CartServer.add_item("user-123", item_id, 2)

      # View cart:
      %{item_id => 2} = Inventory.CartServer.get_cart("user-123")

      # Checkout (creates reservations for all items):
      {:ok, reservations} = Inventory.CartServer.checkout("user-123")

      # Cart is now empty; confirm reservations to complete purchase.
  """

  use GenServer

  require Logger

  alias Inventory.{Items, Store}

  # 30 minutes
  @default_ttl_ms 30 * 60 * 1_000
  # 10 minutes to complete purchase
  @checkout_reservation_ms 10 * 60 * 1_000

  # ─────────────────────────────────────────────────────────────
  # Registry helpers
  # ─────────────────────────────────────────────────────────────

  @doc """
  Build the via-tuple used to name and look up this GenServer.

      {:via, Registry, {Inventory.CartRegistry, cart_id}}

  Any GenServer function accepts a via-tuple instead of a pid or atom.
  The Registry resolves it to the pid transparently.
  """
  def via_tuple(cart_id), do: {:via, Registry, {Inventory.CartRegistry, cart_id}}

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  def start_link(cart_id) do
    GenServer.start_link(__MODULE__, cart_id, name: via_tuple(cart_id))
  end

  @doc """
  Get an existing cart process or start a new one.
  Idempotent — safe to call on every request.
  """
  def get_or_create(cart_id) do
    case Registry.lookup(Inventory.CartRegistry, cart_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        Inventory.CartSupervisor.start_cart(cart_id)
    end
  end

  @doc "Add (or increment) `quantity` units of `item_id` in the cart."
  def add_item(cart_id, item_id, quantity \\ 1)
      when is_integer(quantity) and quantity > 0 do
    GenServer.call(via_tuple(cart_id), {:add_item, item_id, quantity})
  end

  @doc "Remove `quantity` units. Removes the line entirely if qty drops to 0."
  def remove_item(cart_id, item_id, quantity \\ 1)
      when is_integer(quantity) and quantity > 0 do
    GenServer.call(via_tuple(cart_id), {:remove_item, item_id, quantity})
  end

  @doc "Return the current cart contents: `%{item_id => quantity}`."
  def get_cart(cart_id) do
    GenServer.call(via_tuple(cart_id), :get)
  end

  @doc "Empty the cart without checking out."
  def clear(cart_id) do
    GenServer.cast(via_tuple(cart_id), :clear)
  end

  @doc """
  Checkout: attempt to reserve all items in the cart.

  Returns `{:ok, [reservation]}` if all succeed.
  Returns `{:error, reason}` if any item is unavailable — all partial
  reservations are automatically rolled back.

  After a successful checkout the cart is emptied.
  """
  def checkout(cart_id) do
    GenServer.call(via_tuple(cart_id), :checkout, 15_000)
  end

  @doc "Returns true if a cart process exists for this cart_id."
  def exists?(cart_id) do
    case Registry.lookup(Inventory.CartRegistry, cart_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  # ─────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(cart_id) do
    Logger.info("CartServer started for cart_id=#{cart_id}")
    timer_ref = schedule_ttl()
    {:ok, %{cart_id: cart_id, items: %{}, timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_call({:add_item, item_id, quantity}, _from, state) do
    new_items = Map.update(state.items, item_id, quantity, &(&1 + quantity))
    {:reply, :ok, reset_ttl(%{state | items: new_items})}
  end

  @impl GenServer
  def handle_call({:remove_item, item_id, quantity}, _from, state) do
    new_items =
      case Map.get(state.items, item_id) do
        nil -> state.items
        current when current <= quantity -> Map.delete(state.items, item_id)
        current -> Map.put(state.items, item_id, current - quantity)
      end

    {:reply, :ok, reset_ttl(%{state | items: new_items})}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state.items, state}
  end

  @impl GenServer
  def handle_call(:checkout, _from, %{items: items} = state) when map_size(items) == 0 do
    {:reply, {:error, :empty_cart}, state}
  end

  def handle_call(:checkout, _from, state) do
    # Try to reserve every item. If any fails, rollback all successes.
    result =
      Enum.reduce_while(state.items, {:ok, []}, fn {item_id, qty}, {:ok, reservations} ->
        case Items.create_reservation(item_id, qty, @checkout_reservation_ms) do
          {:ok, reservation} ->
            Store.track_reservation(reservation.id, @checkout_reservation_ms)
            {:cont, {:ok, [reservation | reservations]}}

          {:error, reason} ->
            {:halt, {:error, reason, reservations}}
        end
      end)

    case result do
      {:ok, reservations} ->
        Logger.info(
          "CartServer #{state.cart_id}: checkout successful, #{length(reservations)} reservation(s)"
        )

        {:reply, {:ok, Enum.reverse(reservations)}, reset_ttl(%{state | items: %{}})}

      {:error, reason, partial_reservations} ->
        # Rollback any reservations that succeeded before the failure
        Enum.each(partial_reservations, fn res ->
          Items.cancel_reservation(res.id)
          Store.cancel_timer(res.id)
        end)

        Logger.warning(
          "CartServer #{state.cart_id}: checkout failed (#{inspect(reason)}), rolled back #{length(partial_reservations)} reservation(s)"
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_cast(:clear, state) do
    {:noreply, reset_ttl(%{state | items: %{}})}
  end

  # TTL expired — stop this cart process normally.
  # DynamicSupervisor will NOT restart on :normal exit.
  @impl GenServer
  def handle_info(:ttl_expire, state) do
    Logger.info("CartServer #{state.cart_id}: TTL expired, shutting down")
    {:stop, :normal, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Process.cancel_timer(state.timer_ref)
    Logger.info("CartServer #{state.cart_id} terminating: #{inspect(reason)}")
    :ok
  end

  # ─────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────

  defp schedule_ttl(ms \\ @default_ttl_ms) do
    Process.send_after(self(), :ttl_expire, ms)
  end

  # Cancel the existing timer and start a fresh one (sliding window TTL)
  defp reset_ttl(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: schedule_ttl()}
  end
end

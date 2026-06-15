defmodule Inventory.StoreTest do
  @moduledoc """
  Tests for Inventory.Store — the reservation timer manager GenServer.

  These tests use DataCase (async: false) because:
  1. Store.init/1 calls Items.list_pending_reservations/0 (hits the DB)
  2. Expiry tests need to write/read reservations from the DB

  The SQL sandbox in shared mode allows the GenServer process to access
  the test's DB transaction automatically.
  """

  use Inventory.DataCase, async: false

  alias Inventory.{Items, Store}

  # ─────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────

  defp start_store do
    # Give each test its own uniquely named Store so they don't collide
    name = :"Store_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Store, name: name})
  end

  defp create_item(attrs \\ %{}) do
    default = %{
      name: "Widget",
      sku: "WGT-#{:erlang.unique_integer([:positive])}",
      quantity: 50,
      price: 999
    }

    {:ok, item} = Items.create_item(Map.merge(default, Map.new(attrs)))
    item
  end

  # ─────────────────────────────────────────────────────────────
  # init/1 — re-hydration from DB
  # ─────────────────────────────────────────────────────────────

  describe "init/1" do
    test "starts with no timers when there are no pending reservations" do
      store = start_store()
      assert Store.dump_timers(store) == %{}
    end

    test "restores timers for pending reservations found in the DB on startup" do
      item = create_item()
      # Create a reservation directly via Items (simulates a reservation
      # that existed before the Store GenServer was started)
      {:ok, reservation} = Items.create_reservation(item.id, 5, 10_000)

      # Start a fresh Store — it should find the pending reservation and set a timer
      store = start_store()
      timers = Store.dump_timers(store)

      assert Map.has_key?(timers, reservation.id)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # track_reservation/2  (handle_cast)
  # ─────────────────────────────────────────────────────────────

  describe "track_reservation/3 (handle_cast)" do
    test "adds a timer ref to state" do
      store = start_store()

      Store.track_reservation(store, 999, 60_000)

      # Synchronise after cast with a subsequent call
      timers = Store.dump_timers(store)
      assert Map.has_key?(timers, 999)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # cancel_timer/2  (handle_cast)
  # ─────────────────────────────────────────────────────────────

  describe "cancel_timer/2 (handle_cast)" do
    test "removes the timer from state" do
      store = start_store()

      Store.track_reservation(store, 42, 60_000)
      Store.cancel_timer(store, 42)

      timers = Store.dump_timers(store)
      refute Map.has_key?(timers, 42)
    end

    test "is safe to call for a non-existent timer" do
      store = start_store()
      # Should not crash
      assert :ok = Store.cancel_timer(store, :does_not_exist)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Reservation expiry  (handle_info via Process.send_after)
  # ─────────────────────────────────────────────────────────────

  describe "reservation expiry via handle_info" do
    test "expired reservation is marked :expired in the DB and stock released" do
      item = create_item(quantity: 20)

      # Create a reservation with a very short timeout
      {:ok, reservation} = Items.create_reservation(item.id, 5, 100)

      store = start_store()
      Store.track_reservation(store, reservation.id, 100)

      # Wait for expiry timer to fire and the async Task to complete
      Process.sleep(400)

      # Reservation should now be expired in the DB
      updated_res = Inventory.Repo.get!(Inventory.Reservation, reservation.id)
      assert updated_res.status == "expired"

      # And the reserved_qty on the item should be back to 0
      updated_item = Items.get_item!(item.id)
      assert updated_item.reserved_qty == 0
    end

    test "timer ref is removed from state after expiry" do
      item = create_item(quantity: 10)
      {:ok, reservation} = Items.create_reservation(item.id, 2, 50)

      store = start_store()
      Store.track_reservation(store, reservation.id, 50)

      Process.sleep(200)

      timers = Store.dump_timers(store)
      refute Map.has_key?(timers, reservation.id)
    end
  end
end

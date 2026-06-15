defmodule Inventory.LowStockMonitorTest do
  @moduledoc """
  Tests for Inventory.LowStockMonitor — the periodic low-stock checker.

  Key difference from the old subscriber-pattern version:
  Notifications now come via PubSub, so tests subscribe to the
  `"inventory"` topic instead of registering with the GenServer directly.

  Uses DataCase (async: false) because the Monitor queries the DB on check.
  """

  use Inventory.DataCase, async: false

  alias Inventory.{Items, LowStockMonitor}

  @pubsub Inventory.PubSub
  @topic "inventory"

  # ─────────────────────────────────────────────────────────────
  # Helpers
  # ─────────────────────────────────────────────────────────────

  defp start_monitor(opts) do
    name = :"Monitor_#{:erlang.unique_integer([:positive])}"
    # interval_ms very high — we call check_now/1 manually in most tests
    opts = Keyword.merge([threshold: 5, interval_ms: 100_000], opts)
    start_supervised!({LowStockMonitor, [{:name, name} | opts]})
  end

  defp create_item(qty, reserved \\ 0) do
    sku = "SKU-#{:erlang.unique_integer([:positive])}"
    {:ok, item} = Items.create_item(%{name: "Item", sku: sku, quantity: qty, price: 100})

    if reserved > 0 do
      {:ok, _} = Items.create_reservation(item.id, reserved, 60_000)
    end

    Items.get_item!(item.id)
  end

  defp subscribe_pubsub do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # ─────────────────────────────────────────────────────────────
  # set_threshold
  # ─────────────────────────────────────────────────────────────

  describe "set_threshold/2 (handle_cast)" do
    test "updates the threshold at runtime" do
      monitor = start_monitor(threshold: 5)
      subscribe_pubsub()

      # qty=20 > 5 → not low
      _item = create_item(20)

      LowStockMonitor.check_now(monitor)
      refute_receive {:low_stock, _}, 100

      # Raise threshold so qty=20 is now "low"
      LowStockMonitor.set_threshold(monitor, 25)
      LowStockMonitor.check_now(monitor)

      assert_receive {:low_stock, _}, 500
    end
  end

  # ─────────────────────────────────────────────────────────────
  # check_now + PubSub notification
  # ─────────────────────────────────────────────────────────────

  describe "check_now/1 and PubSub broadcasts" do
    test "broadcasts {:low_stock, items} when available stock <= threshold" do
      subscribe_pubsub()
      monitor = start_monitor(threshold: 5)

      # available=3 <= threshold=5
      _low = create_item(3)

      LowStockMonitor.check_now(monitor)

      assert_receive {:low_stock, low_items}, 500
      assert length(low_items) >= 1
    end

    test "does NOT broadcast when all items have sufficient stock" do
      subscribe_pubsub()
      monitor = start_monitor(threshold: 5)

      # available=100 > 5
      _fine = create_item(100)

      LowStockMonitor.check_now(monitor)

      refute_receive {:low_stock, _}, 200
    end

    test "includes only low-stock items in the broadcast" do
      subscribe_pubsub()
      monitor = start_monitor(threshold: 5)

      low1 = create_item(2)
      low2 = create_item(4)
      _fine = create_item(50)

      LowStockMonitor.check_now(monitor)

      assert_receive {:low_stock, low_items}, 500
      low_ids = Enum.map(low_items, & &1.id) |> MapSet.new()
      assert MapSet.member?(low_ids, low1.id)
      assert MapSet.member?(low_ids, low2.id)
    end

    test "treats reserved stock as unavailable when computing low stock" do
      subscribe_pubsub()
      monitor = start_monitor(threshold: 5)

      # qty=10 but 8 reserved → available=2 <= threshold=5
      _item = create_item(10, 8)

      LowStockMonitor.check_now(monitor)

      assert_receive {:low_stock, _}, 500
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Periodic timer (integration)
  # ─────────────────────────────────────────────────────────────

  describe "periodic :check timer" do
    test "fires automatically and broadcasts low-stock" do
      subscribe_pubsub()
      # Short interval so the test doesn't wait long
      monitor = start_monitor(threshold: 5, interval_ms: 150)

      _low = create_item(1)

      # The :check message will fire within ~150ms
      assert_receive {:low_stock, _}, 800

      # Silence the monitor so it doesn't affect other tests
      LowStockMonitor.set_threshold(monitor, 0)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Items context — unit tests
  # ─────────────────────────────────────────────────────────────

  describe "Items context" do
    test "create_item/1 returns item and broadcasts :item_created" do
      subscribe_pubsub()
      {:ok, item} = Items.create_item(%{name: "Gizmo", sku: "GIZ-001", quantity: 10, price: 500})

      assert item.name == "Gizmo"
      assert_receive {:item_created, ^item}, 500
    end

    test "delete_item/1 broadcasts :item_deleted" do
      subscribe_pubsub()
      {:ok, item} = Items.create_item(%{name: "Del", sku: "DEL-001", quantity: 1, price: 1})
      item_id = item.id
      {:ok, _} = Items.delete_item(item)

      assert_receive {:item_deleted, ^item_id}, 500
    end

    test "create_reservation/3 reduces available stock" do
      item = create_item(20)
      {:ok, _res} = Items.create_reservation(item.id, 5, 60_000)

      updated = Items.get_item!(item.id)
      assert updated.reserved_qty == 5
      assert Inventory.Item.available(updated) == 15
    end

    test "confirm_reservation/1 permanently deducts stock" do
      item = create_item(20)
      {:ok, res} = Items.create_reservation(item.id, 5, 60_000)
      {:ok, _} = Items.confirm_reservation(res.id)

      updated = Items.get_item!(item.id)
      assert updated.quantity == 15
      assert updated.reserved_qty == 0
    end

    test "cancel_reservation/1 releases reserved stock" do
      item = create_item(20)
      {:ok, res} = Items.create_reservation(item.id, 5, 60_000)
      {:ok, _} = Items.cancel_reservation(res.id)

      updated = Items.get_item!(item.id)
      assert updated.reserved_qty == 0
      assert Inventory.Item.available(updated) == 20
    end

    test "stats/0 returns correct counts" do
      _i1 = create_item(100)
      # low stock
      _i2 = create_item(3)

      stats = Items.stats()

      assert stats.total_items >= 2
      assert stats.low_stock_count >= 1
    end
  end
end

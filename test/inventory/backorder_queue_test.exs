defmodule Inventory.BackorderQueueTest do
  @moduledoc """
  Tests for Inventory.BackorderQueue — cross-process notification when stock returns.
  """

  use Inventory.DataCase, async: false

  alias Inventory.{Items, BackorderQueue}

  defp start_queue do
    name = :"BackorderQueue_#{:erlang.unique_integer([:positive])}"
    start_supervised!({BackorderQueue, name: name})
  end

  defp create_item(qty \\ 0) do
    {:ok, item} =
      Items.create_item(%{
        name: "Widget",
        sku: "WGT-#{:erlang.unique_integer([:positive])}",
        quantity: qty,
        price: 100
      })

    item
  end

  # ─────────────────────────────────────────────────────────────
  # enqueue/3  (handle_call)
  # ─────────────────────────────────────────────────────────────

  describe "enqueue/3" do
    test "returns {:ok, ref} for the caller" do
      queue = start_queue()
      item = create_item(0)

      assert {:ok, ref} = BackorderQueue.enqueue(queue, item.id, 5)
      assert is_reference(ref)
    end

    test "multiple callers can queue for the same item" do
      queue = start_queue()
      item = create_item(0)

      {:ok, ref1} = BackorderQueue.enqueue(queue, item.id, 3)
      {:ok, ref2} = BackorderQueue.enqueue(queue, item.id, 2)

      assert ref1 != ref2
      assert BackorderQueue.count(queue) == 2
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Fulfilment via PubSub  (handle_info {:item_updated, item})
  # ─────────────────────────────────────────────────────────────

  describe "backorder fulfilment" do
    test "caller receives {:backorder_ready, ref, item_id, qty} when stock arrives" do
      queue = start_queue()
      item = create_item(0)

      {:ok, ref} = BackorderQueue.enqueue(queue, item.id, 5)

      # Restock the item — this broadcasts {:item_updated, updated_item}
      # which BackorderQueue picks up via handle_info
      Items.update_stock(item, 10)

      assert_receive {:backorder_ready, ^ref, _item_id, 5}, 500
    end

    test "entries are removed from the queue after fulfilment" do
      queue = start_queue()
      item = create_item(0)

      {:ok, _ref} = BackorderQueue.enqueue(queue, item.id, 5)
      assert BackorderQueue.count(queue) == 1

      Items.update_stock(item, 10)

      # Wait for handle_info to process
      Process.sleep(100)
      assert BackorderQueue.count(queue) == 0
    end

    test "partial fulfilment: only callers whose quantity fits are notified" do
      queue = start_queue()
      item = create_item(0)
      parent = self()

      # Two callers: one wants 3, one wants 8
      {:ok, ref_small} = BackorderQueue.enqueue(queue, item.id, 3)
      {:ok, _ref_large} = BackorderQueue.enqueue(queue, item.id, 8)

      # Restock only 5 — enough for the first (3) but not the second (8)
      Items.update_stock(item, 5)

      assert_receive {:backorder_ready, ^ref_small, _, 3}, 500
      refute_receive {:backorder_ready, _, _, 8}, 200

      # The large backorder is still pending
      assert BackorderQueue.count(queue) == 1

      _ = parent
    end

    test "does not crash when no backorders exist for the restocked item" do
      queue = start_queue()
      item = create_item(0)

      # No backorders registered — restock should be a no-op
      Items.update_stock(item, 10)
      Process.sleep(100)

      assert BackorderQueue.count(queue) == 0
    end
  end

  # ─────────────────────────────────────────────────────────────
  # cancel/2  (handle_cast)
  # ─────────────────────────────────────────────────────────────

  describe "cancel/2" do
    test "removes the entry so the caller is never notified" do
      queue = start_queue()
      item = create_item(0)

      {:ok, ref} = BackorderQueue.enqueue(queue, item.id, 5)
      BackorderQueue.cancel(queue, ref)

      # Allow the cast to be processed
      _ = BackorderQueue.count(queue)

      Items.update_stock(item, 10)

      refute_receive {:backorder_ready, ^ref, _, _}, 200
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Dead subscriber cleanup  (handle_info :DOWN)
  # ─────────────────────────────────────────────────────────────

  describe "dead subscriber cleanup" do
    test "backorder is removed when the enqueuing process dies" do
      queue = start_queue()
      item = create_item(0)
      parent = self()

      # Spawn a temporary process that enqueues and then dies
      sub =
        spawn(fn ->
          {:ok, _ref} = GenServer.call(queue, {:enqueue, item.id, 5})
          send(parent, :enqueued)
          # Die immediately
        end)

      assert_receive :enqueued, 500
      assert BackorderQueue.count(queue) == 1

      # Wait for the process to die and the :DOWN message to be handled
      ref = Process.monitor(sub)

      receive do
        {:DOWN, ^ref, :process, ^sub, _} -> :ok
      end

      Process.sleep(50)
      assert BackorderQueue.count(queue) == 0
    end
  end

  # ─────────────────────────────────────────────────────────────
  # pending/1  (handle_call)
  # ─────────────────────────────────────────────────────────────

  describe "pending/1" do
    test "returns a summary map of item_id => [entries]" do
      queue = start_queue()
      item = create_item(0)

      {:ok, _} = BackorderQueue.enqueue(queue, item.id, 3)
      {:ok, _} = BackorderQueue.enqueue(queue, item.id, 7)

      pending = BackorderQueue.pending(queue)
      entries = Map.get(pending, item.id, [])

      assert length(entries) == 2
      quantities = Enum.map(entries, & &1.quantity) |> Enum.sort()
      assert quantities == [3, 7]
    end
  end
end

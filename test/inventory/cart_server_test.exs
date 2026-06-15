defmodule Inventory.CartServerTest do
  @moduledoc """
  Tests for Inventory.CartServer — one process per cart via DynamicSupervisor + Registry.

  Demonstrates:
  - Registry via-tuples for named process lookup
  - DynamicSupervisor.start_child for runtime process creation
  - Sliding-window TTL via Process.send_after / Process.cancel_timer
  - Atomic checkout with rollback on partial failure
  """

  use Inventory.DataCase, async: false

  alias Inventory.{Items, CartServer, CartSupervisor}

  # ─────────────────────────────────────────────────────────────
  # Test helpers
  # ─────────────────────────────────────────────────────────────

  # Each test uses a unique cart_id to avoid Registry conflicts.
  defp unique_cart_id, do: "cart-#{:erlang.unique_integer([:positive])}"

  # Poll `condition` every 5ms until it returns true or 500ms elapse.
  # Needed when a separate process (Registry) must handle its own :DOWN
  # before our assertion is valid — a fixed sleep is fragile.
  defp wait_until(condition, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> condition.() end)
    |> Stream.each(fn done ->
      unless done do
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("wait_until timed out after #{timeout}ms"),
          else: Process.sleep(5)
      end
    end)
    |> Enum.find(& &1)
  end

  defp create_item(attrs \\ %{}) do
    default = %{
      name: "Widget",
      sku: "WGT-#{:erlang.unique_integer([:positive])}",
      quantity: 20,
      price: 999
    }

    {:ok, item} = Items.create_item(Map.merge(default, Map.new(attrs)))
    item
  end

  # Start a cart via the DynamicSupervisor and ensure cleanup after the test.
  defp start_cart(cart_id) do
    {:ok, pid} = CartSupervisor.start_cart(cart_id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  # ─────────────────────────────────────────────────────────────
  # get_or_create/1 + Registry
  # ─────────────────────────────────────────────────────────────

  describe "get_or_create/1" do
    test "creates a new cart process" do
      cart_id = unique_cart_id()
      refute CartServer.exists?(cart_id)

      {:ok, pid} = CartServer.get_or_create(cart_id)
      assert is_pid(pid)
      assert Process.alive?(pid)
      assert CartServer.exists?(cart_id)

      # cleanup
      GenServer.stop(pid, :normal)
    end

    test "returns the same pid for the same cart_id (idempotent)" do
      cart_id = unique_cart_id()
      {:ok, pid1} = CartServer.get_or_create(cart_id)
      {:ok, pid2} = CartServer.get_or_create(cart_id)

      assert pid1 == pid2

      GenServer.stop(pid1, :normal)
    end

    test "creates a fresh process after old one dies" do
      cart_id = unique_cart_id()
      {:ok, pid1} = CartServer.get_or_create(cart_id)

      # Monitor BEFORE stopping so we know when the process is dead
      ref = Process.monitor(pid1)
      GenServer.stop(pid1, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid1, :normal}, 500

      # The Registry (a separate process) also monitors pid1 and must handle
      # its own :DOWN to remove the entry.  Wait until it does.
      wait_until(fn -> not CartServer.exists?(cart_id) end)

      {:ok, pid2} = CartServer.get_or_create(cart_id)
      assert pid1 != pid2
      assert Process.alive?(pid2)

      GenServer.stop(pid2, :normal)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # add_item/3 + remove_item/3
  # ─────────────────────────────────────────────────────────────

  describe "add_item/3" do
    test "adds an item to the cart" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      assert :ok = CartServer.add_item(cart_id, item.id, 3)
      assert CartServer.get_cart(cart_id) == %{item.id => 3}
    end

    test "increments quantity for an existing item" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      CartServer.add_item(cart_id, item.id, 2)
      CartServer.add_item(cart_id, item.id, 5)

      assert CartServer.get_cart(cart_id) == %{item.id => 7}
    end

    test "supports multiple different items" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      i1 = create_item()
      i2 = create_item()

      CartServer.add_item(cart_id, i1.id, 1)
      CartServer.add_item(cart_id, i2.id, 4)

      cart = CartServer.get_cart(cart_id)
      assert cart[i1.id] == 1
      assert cart[i2.id] == 4
    end
  end

  describe "remove_item/3" do
    test "decrements item quantity" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      CartServer.add_item(cart_id, item.id, 5)
      CartServer.remove_item(cart_id, item.id, 2)

      assert CartServer.get_cart(cart_id) == %{item.id => 3}
    end

    test "removes item completely when quantity reaches zero" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      CartServer.add_item(cart_id, item.id, 3)
      CartServer.remove_item(cart_id, item.id, 3)

      assert CartServer.get_cart(cart_id) == %{}
    end

    test "removing more than present drops the line" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      CartServer.add_item(cart_id, item.id, 2)
      CartServer.remove_item(cart_id, item.id, 99)

      assert CartServer.get_cart(cart_id) == %{}
    end

    test "removing a non-existent item is a no-op" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      CartServer.remove_item(cart_id, item.id, 1)
      assert CartServer.get_cart(cart_id) == %{}
    end
  end

  # ─────────────────────────────────────────────────────────────
  # clear/1
  # ─────────────────────────────────────────────────────────────

  describe "clear/1" do
    test "empties all items from the cart" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item()

      CartServer.add_item(cart_id, item.id, 5)
      CartServer.clear(cart_id)

      # Give the cast time to be processed
      _ = CartServer.get_cart(cart_id)
      assert CartServer.get_cart(cart_id) == %{}
    end
  end

  # ─────────────────────────────────────────────────────────────
  # checkout/1  (handle_call :checkout)
  # ─────────────────────────────────────────────────────────────

  describe "checkout/1" do
    test "succeeds and returns reservations for all items" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item(quantity: 10)

      CartServer.add_item(cart_id, item.id, 3)

      assert {:ok, reservations} = CartServer.checkout(cart_id)
      assert length(reservations) == 1
      [res] = reservations
      assert res.item_id == item.id
      assert res.quantity == 3
      # Ecto stores status as a string column (not Ecto.Enum), so compare to "pending"
      assert res.status == "pending"
    end

    test "cart is emptied after successful checkout" do
      cart_id = unique_cart_id()
      start_cart(cart_id)
      item = create_item(quantity: 10)

      CartServer.add_item(cart_id, item.id, 2)
      {:ok, _} = CartServer.checkout(cart_id)

      assert CartServer.get_cart(cart_id) == %{}
    end

    test "returns {:error, :empty_cart} for an empty cart" do
      cart_id = unique_cart_id()
      start_cart(cart_id)

      assert {:error, :empty_cart} = CartServer.checkout(cart_id)
    end

    test "rolls back partial reservations when one item is out of stock" do
      cart_id = unique_cart_id()
      start_cart(cart_id)

      item_ok = create_item(quantity: 10)
      # no stock
      item_ooc = create_item(quantity: 0)

      CartServer.add_item(cart_id, item_ok.id, 2)
      CartServer.add_item(cart_id, item_ooc.id, 1)

      assert {:error, _reason} = CartServer.checkout(cart_id)

      # No reservations should remain — partial ones are rolled back
      reservations = Inventory.Repo.all(Inventory.Reservation)
      pending = Enum.filter(reservations, &(&1.status == "pending"))
      assert pending == []
    end

    test "handles multiple items in a single checkout" do
      cart_id = unique_cart_id()
      start_cart(cart_id)

      i1 = create_item(quantity: 5)
      i2 = create_item(quantity: 5)
      i3 = create_item(quantity: 5)

      CartServer.add_item(cart_id, i1.id, 1)
      CartServer.add_item(cart_id, i2.id, 2)
      CartServer.add_item(cart_id, i3.id, 3)

      assert {:ok, reservations} = CartServer.checkout(cart_id)
      assert length(reservations) == 3

      reserved_item_ids = Enum.map(reservations, & &1.item_id) |> Enum.sort()
      assert reserved_item_ids == Enum.sort([i1.id, i2.id, i3.id])
    end
  end

  # ─────────────────────────────────────────────────────────────
  # TTL (sliding window timer)
  # ─────────────────────────────────────────────────────────────

  describe "TTL expiry (sliding window)" do
    test "cart process dies after TTL fires" do
      cart_id = unique_cart_id()
      {:ok, pid} = CartServer.get_or_create(cart_id)
      ref = Process.monitor(pid)

      # Send the TTL message directly — no need to wait 30 minutes.
      # CartServer returns {:stop, :normal, state}; with restart: :transient
      # the DynamicSupervisor does NOT restart it.
      send(pid, :ttl_expire)

      # Wait for the process to die, then wait for Registry to remove its entry
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
      wait_until(fn -> not CartServer.exists?(cart_id) end)
      refute CartServer.exists?(cart_id)
    end

    test "activity resets the TTL (sliding window)" do
      # We test the reset indirectly: after add_item the old timer is
      # cancelled, so sending an old ttl_expire reference has no effect.
      cart_id = unique_cart_id()
      {:ok, pid} = CartServer.get_or_create(cart_id)
      item = create_item()

      # Grab state before activity
      old_timer = :sys.get_state(pid).timer_ref

      # Activity should cancel old_timer and create a new one
      CartServer.add_item(cart_id, item.id, 1)

      new_timer = :sys.get_state(pid).timer_ref
      assert old_timer != new_timer

      # Old timer ref was cancelled; the process should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # DynamicSupervisor lifecycle
  # ─────────────────────────────────────────────────────────────

  describe "DynamicSupervisor" do
    test "started under CartSupervisor and visible in its children" do
      cart_id = unique_cart_id()
      {:ok, pid} = CartSupervisor.start_cart(cart_id)

      children_pids =
        DynamicSupervisor.which_children(Inventory.CartSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)

      assert pid in children_pids

      GenServer.stop(pid, :normal)
    end

    test "normal exit removes the child from the supervisor" do
      cart_id = unique_cart_id()
      {:ok, pid} = CartSupervisor.start_cart(cart_id)
      ref = Process.monitor(pid)

      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

      # DynamicSupervisor should no longer list this child
      Process.sleep(50)

      children_pids =
        DynamicSupervisor.which_children(Inventory.CartSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)

      refute pid in children_pids
    end

    test "duplicate cart_id returns an error from DynamicSupervisor" do
      cart_id = unique_cart_id()
      {:ok, pid} = CartSupervisor.start_cart(cart_id)

      # Trying to start again with the same cart_id should fail because the
      # Registry already has the name registered.
      assert {:error, {:already_started, ^pid}} = CartSupervisor.start_cart(cart_id)

      GenServer.stop(pid, :normal)
    end
  end
end

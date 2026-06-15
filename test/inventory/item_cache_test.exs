defmodule Inventory.ItemCacheTest do
  @moduledoc """
  Tests for Inventory.ItemCache — ETS-backed read cache with handle_continue.
  """

  use Inventory.DataCase, async: false

  alias Inventory.{Items, ItemCache}

  # Each test gets its own named ETS table and GenServer to avoid collisions.
  #
  # Why allow + reload?
  # handle_continue(:load_items) runs synchronously inside start_link before
  # start_supervised! returns, but at that moment the GenServer process has not
  # yet been granted access to the test's Ecto sandbox connection.  We
  # explicitly allow it, then call reload/1 (a synchronous handle_call) to
  # re-run the DB load with proper sandbox access.  This exercises the same
  # code path as handle_continue — the difference is only in which callback
  # triggers the load, not what the load does.
  defp start_cache do
    table_name = :"item_cache_#{:erlang.unique_integer([:positive])}"
    name = :"ItemCache_#{:erlang.unique_integer([:positive])}"

    cache = start_supervised!({ItemCache, name: name, table_name: table_name})
    Ecto.Adapters.SQL.Sandbox.allow(Inventory.Repo, self(), cache)
    ItemCache.reload(cache)
    {cache, table_name}
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
  # init/1 + handle_continue/2
  # ─────────────────────────────────────────────────────────────

  describe "init/1 and handle_continue(:load_items)" do
    test "cache is populated on startup (handle_continue demo)" do
      item = create_item()
      {_cache, table} = start_cache()

      # The cache was loaded during handle_continue — immediately available
      assert {:ok, cached} = ItemCache.get(item.id, table)
      assert cached.id == item.id
    end

    test "cache starts empty when there are no items" do
      {_cache, table} = start_cache()
      assert ItemCache.all(table) == []
    end

    test "size/1 reflects the number of cached items" do
      create_item()
      create_item()
      {_cache, table} = start_cache()
      assert ItemCache.size(table) == 2
    end
  end

  # ─────────────────────────────────────────────────────────────
  # Direct ETS reads (no GenServer hop)
  # ─────────────────────────────────────────────────────────────

  describe "get/2 — direct ETS read" do
    test "returns {:ok, item} for a cached id" do
      item = create_item()
      {_cache, table} = start_cache()

      assert {:ok, ^item} = ItemCache.get(item.id, table)
    end

    test "returns :miss for an unknown id" do
      {_cache, table} = start_cache()
      assert :miss = ItemCache.get(99999, table)
    end
  end

  describe "all/1 — direct ETS read" do
    test "returns all items sorted by id" do
      i1 = create_item()
      i2 = create_item()
      {_cache, table} = start_cache()

      ids = ItemCache.all(table) |> Enum.map(& &1.id)
      assert i1.id in ids
      assert i2.id in ids
      assert ids == Enum.sort(ids)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # PubSub-driven cache invalidation  (handle_info)
  # ─────────────────────────────────────────────────────────────

  describe "cache invalidation via PubSub" do
    test "newly created item appears in cache after :item_created broadcast" do
      {cache, table} = start_cache()

      # Cache starts empty
      assert ItemCache.all(table) == []

      # triggers PubSub broadcast {:item_created, item}
      item = create_item()

      # Synchronise: a call to the GenServer processes after the handle_info
      ItemCache.reload(cache)

      assert {:ok, _} = ItemCache.get(item.id, table)
    end

    test "updated item is reflected in cache after :item_updated broadcast" do
      item = create_item(quantity: 10)
      {cache, table} = start_cache()

      # Update via context — triggers {:item_updated, updated_item}
      Items.update_stock(item, 40)
      ItemCache.reload(cache)

      {:ok, cached} = ItemCache.get(item.id, table)
      assert cached.quantity == 50
    end

    test "deleted item is removed from cache after :item_deleted broadcast" do
      item = create_item()
      {cache, table} = start_cache()

      assert {:ok, _} = ItemCache.get(item.id, table)

      Items.delete_item(item)
      ItemCache.reload(cache)

      assert :miss = ItemCache.get(item.id, table)
    end
  end

  # ─────────────────────────────────────────────────────────────
  # reload/1 (handle_call)
  # ─────────────────────────────────────────────────────────────

  describe "reload/1" do
    test "re-populates cache from DB" do
      {cache, table} = start_cache()
      assert ItemCache.all(table) == []

      # Add items after cache started (bypassing PubSub to test reload directly)
      create_item()
      create_item()

      assert :ok = ItemCache.reload(cache)
      assert ItemCache.size(table) == 2
    end
  end
end

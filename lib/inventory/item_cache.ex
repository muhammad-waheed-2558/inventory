defmodule Inventory.ItemCache do
  @moduledoc """
  GenServer that owns an ETS table for sub-microsecond item reads.

  ## Why this exists

  Every `Items.list_items/0` call hits PostgreSQL. Under high read traffic
  (many browser tabs, LiveView re-renders) this becomes a bottleneck.
  This GenServer keeps a copy of all items in an ETS table so reads happen
  in memory — no DB round-trip, no GenServer message, no serialisation.

  ## New GenServer concepts demonstrated

  ### `handle_continue/2`
  Returned from `init/1` as `{:ok, state, {:continue, :load_items}}`.
  This tells the runtime: "finish starting me (register my name, allow calls)
  *then* immediately call handle_continue before processing any other messages."
  It lets init stay fast (no DB call) while still loading data before the
  first real request arrives.

  ### ETS as a read-optimised store owned by a GenServer
  ETS tables live in the process that created them. When the GenServer dies,
  the table is automatically garbage-collected. The GenServer is the single
  writer; any process can read because the table is `:public` with
  `read_concurrency: true`. This means `ItemCache.get/1` and `ItemCache.all/0`
  never send a message to the GenServer — they read ETS directly.

  ### PubSub-driven cache invalidation
  The GenServer subscribes to the "inventory" topic in `init/1`. Whenever
  the `Items` context mutates an item it broadcasts an event; `handle_info/2`
  picks it up and updates the ETS table — keeping the cache consistent
  without polling.

  ## State

      %{table: atom()}   # ETS table name

  ## Usage

      # Reads bypass the GenServer — go straight to ETS:
      {:ok, item} = Inventory.ItemCache.get(1)
      items        = Inventory.ItemCache.all()

      # Cache miss (item not found):
      :miss = Inventory.ItemCache.get(99999)
  """

  use GenServer

  alias Inventory.Items

  @default_table :item_cache

  # ─────────────────────────────────────────────────────────────
  # Public API  — reads go directly to ETS (no GenServer call)
  # ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Look up a single item by id.
  Reads directly from ETS — O(1), no process hop.
  """
  def get(id, table \\ @default_table) do
    case :ets.lookup(table, id) do
      [{^id, item}] -> {:ok, item}
      [] -> :miss
    end
  end

  @doc """
  Return all cached items sorted by id.
  Reads directly from ETS.
  """
  def all(table \\ @default_table) do
    table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.id)
  end

  @doc "Force a full reload from DB (useful after bulk imports)."
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  @doc "Number of cached items (debugging)."
  def size(table \\ @default_table), do: :ets.info(table, :size)

  # ─────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table)

    # Create the ETS table.
    # :named_table    — accessible by atom name from any process
    # :public         — any process can read/write (we only write from this GenServer)
    # :set            — one value per key (like a map)
    # read_concurrency — optimise for many concurrent readers
    table =
      :ets.new(table_name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true
      ])

    # Subscribe to PubSub so we can invalidate on mutations.
    Items.subscribe()

    # Return {:ok, state, {:continue, :load_items}} instead of {:ok, state}.
    # handle_continue(:load_items) runs next, before any call/cast can arrive.
    # This keeps init/1 fast (no DB call) while still ensuring the cache is
    # populated before the first request.
    {:ok, %{table: table}, {:continue, :load_items}}
  end

  @impl GenServer
  def handle_continue(:load_items, state) do
    load_all(state.table)
    {:noreply, state}
  end

  # ── Cache invalidation via PubSub ────────────────────────────

  @impl GenServer
  def handle_info({:item_created, item}, state) do
    :ets.insert(state.table, {item.id, item})
    {:noreply, state}
  end

  def handle_info({:item_updated, item}, state) do
    :ets.insert(state.table, {item.id, item})
    {:noreply, state}
  end

  def handle_info({:item_deleted, id}, state) do
    :ets.delete(state.table, id)
    {:noreply, state}
  end

  # Ignore other PubSub events (reservations, low_stock)
  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(state.table)
    load_all(state.table)
    {:reply, :ok, state}
  end

  # ─────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────

  defp load_all(table) do
    items = Items.list_items()
    :ets.insert(table, Enum.map(items, &{&1.id, &1}))
    items
  end
end

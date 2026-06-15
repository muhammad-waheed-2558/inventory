defmodule Inventory.InventorySupervisor do
  @moduledoc """
  Supervisor for the inventory GenServer tree.

  Children (in start order):
  1. `Inventory.Store`           — reservation timer manager
  2. `Inventory.LowStockMonitor` — periodic low-stock broadcaster

  Store starts first because the Monitor's `init/1` doesn't depend on it,
  but the Store's `init/1` calls `Items.list_pending_reservations/0` which
  hits the DB (not the Store). Both are independent at init time; ordering
  here is just for clarity.

  Strategy: `one_for_one` — a crash in the Monitor doesn't restart the Store
  or lose in-flight timers, and vice-versa.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    threshold = Keyword.get(opts, :low_stock_threshold, 10)
    interval_ms = Keyword.get(opts, :monitor_interval_ms, 30_000)

    children = [
      # Timer manager for reservation expiry
      {Inventory.Store, name: Inventory.Store},
      # Periodic low-stock broadcaster
      {Inventory.LowStockMonitor,
       name: Inventory.LowStockMonitor, threshold: threshold, interval_ms: interval_ms},
      # ETS-backed read cache (starts after Store so PubSub is ready)
      {Inventory.ItemCache, name: Inventory.ItemCache},
      # Backorder queue for out-of-stock items
      {Inventory.BackorderQueue, name: Inventory.BackorderQueue}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end

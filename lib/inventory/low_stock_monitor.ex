defmodule Inventory.LowStockMonitor do
  @moduledoc """
  GenServer that periodically checks the DB for low-stock items and
  broadcasts an alert on the `"inventory"` PubSub topic.

  ## Why PubSub instead of direct process sends?

  The previous version sent messages directly to subscriber PIDs.
  With PubSub, any LiveView (or any process) can subscribe without
  registering with this GenServer. The monitor doesn't need to know
  who's listening — it just broadcasts and the interested parties react.

  ## GenServer concepts demonstrated

  - `:timer.send_interval/2`  — repeating :check messages to self
  - `handle_info/2`            — handles both :check and runtime config changes
  - `handle_call/2`            — `check_now/1` for synchronous on-demand checks
  - `terminate/2`              — cleans up the interval timer
  """

  use GenServer

  require Logger

  alias Inventory.Items

  @pubsub Inventory.PubSub
  @topic "inventory"
  @default_threshold 10
  @default_interval_ms 30_000

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Trigger an immediate low-stock check (skips the timer interval)."
  def check_now(server \\ __MODULE__) do
    GenServer.call(server, :check_now)
  end

  @doc "Change the low-stock threshold at runtime."
  def set_threshold(server \\ __MODULE__, threshold)
      when is_integer(threshold) and threshold >= 0 do
    GenServer.cast(server, {:set_threshold, threshold})
  end

  # ─────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    {:ok, timer_ref} = :timer.send_interval(interval_ms, self(), :check)

    state = %{threshold: threshold, interval_ms: interval_ms, timer_ref: timer_ref}
    Logger.info("LowStockMonitor started (threshold=#{threshold}, interval=#{interval_ms}ms)")
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:check_now, _from, state) do
    do_check(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:set_threshold, threshold}, state) do
    {:noreply, %{state | threshold: threshold}}
  end

  @impl GenServer
  def handle_info(:check, state) do
    do_check(state)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :timer.cancel(state.timer_ref)
    :ok
  end

  # ─────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────

  defp do_check(state) do
    low_items = Items.list_low_stock(state.threshold)

    if low_items != [] do
      Logger.debug("LowStockMonitor: #{length(low_items)} low-stock item(s)")
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:low_stock, low_items})
    end
  end
end

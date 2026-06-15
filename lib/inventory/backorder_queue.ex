defmodule Inventory.BackorderQueue do
  @moduledoc """
  GenServer that queues demand for out-of-stock items and automatically
  notifies waiting processes when stock returns.

  ## Real-world problem this solves

  Without this: a customer tries to buy an item, gets "out of stock",
  and has to keep refreshing manually.

  With this: the customer's process calls `enqueue/2`, receives a reference,
  and is notified asynchronously when stock is replenished — no polling.

  ## New GenServer concepts demonstrated

  ### Complex nested state
  State is a map of maps: `%{item_id => [backorder_entry]}`.
  Each entry tracks the requesting PID, a unique reference (so the caller
  can match the reply), and a monitor reference (for cleanup).

  ### `Process.monitor/1` for subscriber cleanup
  When a process enqueues a backorder, the GenServer monitors it.
  If that process dies before the backorder is fulfilled (e.g. user closes
  the tab), `handle_info/2` receives `{:DOWN, ref, :process, pid, reason}`
  and removes the orphaned entry — preventing memory leaks.

  ### Cross-process messaging with `send/2`
  When stock arrives the GenServer calls `send(waiting_pid, message)`.
  Unlike `GenServer.reply`, this works even though the delivery happens
  inside a *different* `handle_info` call than the original request.

  ### PubSub-triggered fulfilment
  The GenServer subscribes to `{:item_updated, item}` events. When
  `Items.update_stock/2` restocks an item, the broadcast triggers
  `do_fulfill/2` which works through the queue and notifies waiting callers.

  ## State

      %{
        queues: %{
          item_id => [
            %{pid: pid, ref: ref, quantity: integer, monitor_ref: reference}
          ]
        }
      }

  ## Usage

      # Caller registers interest in 5 units of item 1:
      {:ok, backorder_ref} = BackorderQueue.enqueue(item_id, 5)

      # ... later, when someone restocks item 1 via Items.update_stock ...
      # Caller's process receives:
      receive do
        {:backorder_ready, ^backorder_ref, item_id, qty} -> ...
      end

      # List all pending backorders:
      BackorderQueue.pending()
  """

  use GenServer

  require Logger

  alias Inventory.{Item, Items}

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register demand for `quantity` units of `item_id`.

  Returns `{:ok, ref}`. The calling process will receive
  `{:backorder_ready, ref, item_id, quantity}` when stock becomes available.

  Uses `handle_call/3` so the caller gets the ref synchronously.
  """
  def enqueue(server \\ __MODULE__, item_id, quantity)
      when is_integer(quantity) and quantity > 0 do
    GenServer.call(server, {:enqueue, item_id, quantity})
  end

  @doc "Cancel a backorder by its ref."
  def cancel(server \\ __MODULE__, backorder_ref) do
    GenServer.cast(server, {:cancel, backorder_ref})
  end

  @doc "Return a summary of all pending backorders (for debugging/UI)."
  def pending(server \\ __MODULE__) do
    GenServer.call(server, :pending)
  end

  @doc "Total number of backorder entries across all items."
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  end

  # ─────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Subscribe to item updates so we can try to fulfill backorders
    # whenever stock changes
    Items.subscribe()
    {:ok, %{queues: %{}}}
  end

  @impl GenServer
  def handle_call({:enqueue, item_id, quantity}, {pid, _tag}, state) do
    backorder_ref = make_ref()

    # Monitor the caller. If it dies, handle_info(:DOWN) cleans up.
    monitor_ref = Process.monitor(pid)

    entry = %{
      pid: pid,
      ref: backorder_ref,
      quantity: quantity,
      monitor_ref: monitor_ref
    }

    new_queues = Map.update(state.queues, item_id, [entry], &(&1 ++ [entry]))

    Logger.debug("BackorderQueue: enqueued #{quantity} of item #{item_id} for #{inspect(pid)}")

    {:reply, {:ok, backorder_ref}, %{state | queues: new_queues}}
  end

  @impl GenServer
  def handle_call(:pending, _from, state) do
    summary =
      Map.new(state.queues, fn {item_id, entries} ->
        {item_id, Enum.map(entries, &Map.take(&1, [:pid, :quantity, :ref]))}
      end)

    {:reply, summary, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    total = state.queues |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    {:reply, total, state}
  end

  @impl GenServer
  def handle_cast({:cancel, backorder_ref}, state) do
    new_queues = remove_by_ref(state.queues, backorder_ref)
    {:noreply, %{state | queues: new_queues}}
  end

  # ── PubSub: item restocked → try to fulfill backorders ───────

  @impl GenServer
  def handle_info({:item_updated, item}, state) do
    new_state = do_fulfill(item, state)
    {:noreply, new_state}
  end

  # A monitored caller process has died — remove its backorder entries.
  # This is the :DOWN message pattern from Process.monitor/1.
  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    Logger.debug(
      "BackorderQueue: subscriber #{inspect(pid)} died (#{inspect(reason)}), removing entries"
    )

    new_queues =
      Map.new(state.queues, fn {item_id, entries} ->
        {item_id, Enum.reject(entries, &(&1.monitor_ref == monitor_ref))}
      end)
      |> Map.reject(fn {_k, v} -> v == [] end)

    {:noreply, %{state | queues: new_queues}}
  end

  # Ignore unrelated PubSub events
  def handle_info(_other, state), do: {:noreply, state}

  # ─────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────

  defp do_fulfill(item, state) do
    case Map.get(state.queues, item.id) do
      nil ->
        state

      [] ->
        %{state | queues: Map.delete(state.queues, item.id)}

      entries ->
        available = Item.available(item)

        {fulfilled, remaining, _avail_left} =
          Enum.reduce(entries, {[], [], available}, fn entry, {done, left, avail} ->
            if avail >= entry.quantity do
              {[entry | done], left, avail - entry.quantity}
            else
              {done, [entry | left], avail}
            end
          end)

        # Notify fulfilled callers
        Enum.each(fulfilled, fn entry ->
          Process.demonitor(entry.monitor_ref, [:flush])

          send(entry.pid, {:backorder_ready, entry.ref, item.id, entry.quantity})

          Logger.info(
            "BackorderQueue: fulfilled #{entry.quantity} of item #{item.id} for #{inspect(entry.pid)}"
          )
        end)

        new_queues =
          if remaining == [] do
            Map.delete(state.queues, item.id)
          else
            Map.put(state.queues, item.id, Enum.reverse(remaining))
          end

        %{state | queues: new_queues}
    end
  end

  defp remove_by_ref(queues, ref) do
    Map.new(queues, fn {item_id, entries} ->
      {item_id, Enum.reject(entries, &(&1.ref == ref))}
    end)
    |> Map.reject(fn {_k, v} -> v == [] end)
  end
end

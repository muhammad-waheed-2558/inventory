defmodule Inventory.Store do
  @moduledoc """
  GenServer that manages **reservation expiry timers**.

  The DB (`Inventory.Items`) is the source of truth for all item and
  reservation data. This GenServer's only job is to hold the in-memory
  timer references returned by `Process.send_after/3`, so they can be
  cancelled when a reservation is confirmed or cancelled before it expires.

  ## State

      %{timers: %{reservation_id => timer_ref}}

  ## What happens on restart

  On `init/1` we query all pending reservations from the DB and restart
  their timers, adjusting for elapsed time. This means no reservation is
  silently orphaned if the server crashes and restarts.

  ## GenServer concepts demonstrated

  - `handle_cast/2`  — fire-and-forget: track a new timer, cancel a timer
  - `handle_info/2`  — expiry fires here; delegates to `Items.expire_reservation/1`
  - `init/1`         — re-hydrates timer state from the DB on startup
  - `terminate/2`    — cancels all live timers on shutdown
  """

  use GenServer

  require Logger

  alias Inventory.Items

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a new reservation timer.
  Call this immediately after `Items.create_reservation/3` succeeds.
  """
  def track_reservation(server \\ __MODULE__, reservation_id, timeout_ms) do
    GenServer.cast(server, {:track, reservation_id, timeout_ms})
  end

  @doc """
  Cancel the timer for a reservation (called on confirm or manual cancel).
  Safe to call even if the timer has already fired.
  """
  def cancel_timer(server \\ __MODULE__, reservation_id) do
    GenServer.cast(server, {:cancel, reservation_id})
  end

  @doc "Returns the current timer map — useful for debugging."
  def dump_timers(server \\ __MODULE__) do
    GenServer.call(server, :dump_timers)
  end

  # ─────────────────────────────────────────────────────────────
  # GenServer callbacks
  # ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Re-hydrate timers from any pending reservations in the DB.
    # This handles the case where the GenServer (or whole app) was restarted.
    state = %{timers: %{}}

    new_state =
      Items.list_pending_reservations()
      |> Enum.reduce(state, fn reservation, acc ->
        remaining_ms = remaining_ms(reservation.expires_at)

        if remaining_ms <= 0 do
          # Already expired while we were down — expire it now
          Task.start(fn -> Items.expire_reservation(reservation.id) end)
          acc
        else
          ref = Process.send_after(self(), {:expire_reservation, reservation.id}, remaining_ms)
          put_in(acc, [:timers, reservation.id], ref)
        end
      end)

    Logger.info("Store started, tracking #{map_size(new_state.timers)} pending reservation(s)")
    {:ok, new_state}
  end

  @impl GenServer
  def handle_cast({:track, reservation_id, timeout_ms}, state) do
    ref = Process.send_after(self(), {:expire_reservation, reservation_id}, timeout_ms)
    {:noreply, put_in(state, [:timers, reservation_id], ref)}
  end

  @impl GenServer
  def handle_cast({:cancel, reservation_id}, state) do
    {ref, remaining} = Map.pop(state.timers, reservation_id)
    if ref, do: Process.cancel_timer(ref)
    {:noreply, %{state | timers: remaining}}
  end

  @impl GenServer
  def handle_call(:dump_timers, _from, state) do
    {:reply, state.timers, state}
  end

  @impl GenServer
  def handle_info({:expire_reservation, reservation_id}, state) do
    # Remove the timer ref first (it's already fired)
    {_ref, remaining_timers} = Map.pop(state.timers, reservation_id)

    # Delegate DB + PubSub work to the context (outside the GenServer process
    # to keep this callback fast and non-blocking)
    Task.start(fn -> Items.expire_reservation(reservation_id) end)

    {:noreply, %{state | timers: remaining_timers}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cancel all outstanding timers on shutdown
    Enum.each(state.timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    :ok
  end

  # ─────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────

  defp remaining_ms(expires_at) do
    diff = DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
    max(diff, 0)
  end
end

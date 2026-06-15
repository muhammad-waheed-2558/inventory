# inventory

# Inventory Management System — Developer Guide

A Phoenix LiveView application built to learn GenServer in depth.
The system combines OTP process design (GenServers, Supervisors) with Ecto persistence and real-time UI via LiveView and PubSub.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Architecture Overview](#2-architecture-overview)
3. [Component Deep-Dive](#3-component-deep-dive)
   - 3.1 [Inventory.Item — Ecto Schema](#31-inventoryitem--ecto-schema)
   - 3.2 [Inventory.Reservation — Ecto Schema](#32-inventoryreservation--ecto-schema)
   - 3.3 [Inventory.Items — Context](#33-inventoryitems--context)
   - 3.4 [Inventory.Store — GenServer (Timer Manager)](#34-inventorystore--genserver-timer-manager)
   - 3.5 [Inventory.LowStockMonitor — GenServer (Periodic Checker)](#35-inventorylowstockmonitor--genserver-periodic-checker)
   - 3.6 [Inventory.InventorySupervisor — Supervisor](#36-inventoryinventorysupervisor--supervisor)
   - 3.7 [InventoryWeb.InventoryLive.Index — LiveView](#37-inventorywebinventoryliveindex--liveview)
4. [GenServer Callback Reference](#4-genserver-callback-reference)
5. [Data Flow Diagrams](#5-data-flow-diagrams)
6. [Testing Guide](#6-testing-guide)
   - 6.1 [Running the Test Suite](#61-running-the-test-suite)
   - 6.2 [Manual UI Testing Scenarios](#62-manual-ui-testing-scenarios)
   - 6.3 [IEx / Console Testing](#63-iex--console-testing)
7. [PubSub Event Reference](#7-pubsub-event-reference)
8. [Database Schema](#8-database-schema)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Quick Start

```bash
# Install dependencies
mix deps.get

# Create the database and run migrations
mix ecto.create
mix ecto.migrate

# Start the Phoenix server
mix phx.server
```

Open **http://localhost:4000/inventory** in your browser.

To run automated tests:

```bash
# Runs ecto.create + ecto.migrate + test automatically (see mix.exs aliases)
mix test test/inventory/
```

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Phoenix Application                         │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Inventory.InventorySupervisor               │   │
│  │  (one_for_one — crash in one child doesn't restart both) │   │
│  │                                                          │   │
│  │   ┌─────────────────┐    ┌──────────────────────────┐   │   │
│  │   │ Inventory.Store │    │ Inventory.LowStockMonitor │   │   │
│  │   │  (timer mgr)    │    │   (periodic DB checker)   │   │   │
│  │   └────────┬────────┘    └────────────┬─────────────┘   │   │
│  └────────────┼─────────────────────────┼─────────────────┘   │
│               │                         │                       │
│               ▼                         ▼                       │
│        Inventory.Items (Context) ◄──────┘                       │
│        (all DB reads/writes)                                    │
│               │                                                 │
│               │  broadcasts on "inventory" PubSub topic        │
│               ▼                                                 │
│        Phoenix.PubSub                                           │
│               │                                                 │
│               ▼                                                 │
│    InventoryWeb.InventoryLive.Index  (LiveView)                 │
│    (subscribes to PubSub, re-renders on every event)           │
└─────────────────────────────────────────────────────────────────┘
```

### Design Principles

**DB is the single source of truth.** All item quantities, reservation counts, and statuses live in PostgreSQL. The GenServers hold no item state — they only manage ephemeral behaviour (timers, periodic scheduling).

**PubSub decouples writers from readers.** The `Items` context broadcasts an event after every mutation. LiveViews, tests, or any other subscriber react to these events without the writer needing to know who is listening.

**GenServers are small and focused.** Each GenServer has one job:
- `Store` → hold timer references so they can be cancelled
- `LowStockMonitor` → run a DB query every N seconds and broadcast results

---

## 3. Component Deep-Dive

### 3.1 `Inventory.Item` — Ecto Schema

**File:** `lib/inventory/item.ex`

Maps to the `items` table.

| Field         | Type    | Notes                              |
|---------------|---------|------------------------------------|
| `id`          | integer | Auto-generated primary key         |
| `name`        | string  | Required, max 100 chars            |
| `sku`         | string  | Required, unique, immutable        |
| `quantity`    | integer | Total units on hand (≥ 0)         |
| `reserved_qty`| integer | Units held by pending reservations |
| `price`       | integer | Price **in cents** (e.g. 999 = $9.99) |

**Key function:**

```elixir
Item.available(%Item{quantity: 100, reserved_qty: 20})
# => 80
```

Two changesets exist on purpose: `changeset/2` (used on create, validates and locks `sku`) and `update_changeset/2` (used on edit, omits `sku` so it cannot be changed after creation).

---

### 3.2 `Inventory.Reservation` — Ecto Schema

**File:** `lib/inventory/reservation.ex`

Maps to the `reservations` table.

| Field        | Type     | Notes                                     |
|--------------|----------|-------------------------------------------|
| `id`         | integer  | Auto-generated primary key                |
| `item_id`    | integer  | FK → items (cascade delete)               |
| `quantity`   | integer  | Units held (> 0)                          |
| `status`     | string   | `pending` → `confirmed` / `cancelled` / `expired` |
| `expires_at` | datetime | When the reservation auto-expires         |

**Status lifecycle:**

```
pending ──► confirmed   (user clicks Confirm before timer fires)
        ──► cancelled   (user clicks Cancel before timer fires)
        ──► expired     (Process.send_after fires; Store calls Items.expire_reservation)
```

---

### 3.3 `Inventory.Items` — Context

**File:** `lib/inventory/items.ex`

The public API for all inventory operations. Nothing in the rest of the app touches the DB directly — it all goes through this module.

**Item operations:**

| Function | Description |
|---|---|
| `list_items/0` | All items ordered by id |
| `get_item!/1` | Raises if not found |
| `get_item/1` | Returns `nil` if not found |
| `create_item/1` | Inserts + broadcasts `{:item_created, item}` |
| `update_item/2` | Updates name/quantity/price + broadcasts `{:item_updated, item}` |
| `delete_item/1` | Deletes + broadcasts `{:item_deleted, id}` |
| `update_stock/2` | Adjusts quantity by delta inside a transaction; guards against going below `reserved_qty` |

**Reservation operations:**

| Function | Description |
|---|---|
| `create_reservation/3` | Atomically bumps `reserved_qty` + inserts reservation row + broadcasts |
| `confirm_reservation/1` | Deducts stock permanently, sets status `confirmed`, broadcasts |
| `cancel_reservation/1` | Releases reserved stock, sets status `cancelled`, broadcasts |
| `expire_reservation/1` | Called by `Store` GenServer on timer expiry; safe to call on already-resolved reservations |
| `list_reservations_for_item/1` | All reservations for one item, newest first |
| `list_pending_reservations/0` | Used by `Store.init/1` to re-hydrate timers on startup |

**Analytics:**

| Function | Description |
|---|---|
| `stats/0` | `%{total_items, total_stock, low_stock_count, active_reservations}` |
| `list_low_stock/1` | Items where `available ≤ threshold` |

**PubSub subscription:**

```elixir
# In your LiveView mount/3:
Items.subscribe()

# Your process now receives messages like:
# {:item_created, %Item{}}
# {:item_updated, %Item{}}
# {:item_deleted, id}
# {:reservation_created, %Reservation{}}
# {:reservation_confirmed, %Reservation{}}
# {:reservation_cancelled, %Reservation{}}
# {:reservation_expired, %Reservation{}}
# {:low_stock, [%Item{}, ...]}
```

---

### 3.4 `Inventory.Store` — GenServer (Timer Manager)

**File:** `lib/inventory/store.ex`

**State:**

```elixir
%{timers: %{reservation_id => timer_ref}}
```

**Why a GenServer and not just `Process.send_after` from the LiveView?**

LiveView processes are short-lived and per-connection. If the browser disconnects, the LiveView dies and any timers in it are lost. A dedicated GenServer owned by the supervisor tree lives for the lifetime of the application and survives connection drops.

**GenServer callbacks used:**

| Callback | Trigger | What it does |
|---|---|---|
| `init/1` | On startup | Queries `Items.list_pending_reservations/0`; restarts timers for any pending reservations in the DB (adjusting for elapsed time) |
| `handle_cast({:track, id, ms})` | `track_reservation/3` call | Calls `Process.send_after(self(), {:expire_reservation, id}, ms)` and stores the ref |
| `handle_cast({:cancel, id})` | `cancel_timer/2` call | Calls `Process.cancel_timer(ref)` and removes the entry |
| `handle_call(:dump_timers)` | `dump_timers/1` call | Returns the timers map (for debugging/tests) |
| `handle_info({:expire_reservation, id})` | Timer fires | Removes the ref, spawns a `Task` to call `Items.expire_reservation/1` asynchronously so the GenServer callback stays fast |
| `terminate/2` | Process shutdown | Cancels all outstanding timers |

**Why `Task.start` in `handle_info`?**

`Items.expire_reservation/1` is a DB transaction. If it ran directly inside `handle_info`, the GenServer would be blocked and unable to process any other messages (like incoming `track` or `cancel` casts) until the DB query completed. Delegating to a `Task` keeps the callback O(1).

---

### 3.5 `Inventory.LowStockMonitor` — GenServer (Periodic Checker)

**File:** `lib/inventory/low_stock_monitor.ex`

**State:**

```elixir
%{threshold: integer, interval_ms: integer, timer_ref: reference}
```

**GenServer callbacks used:**

| Callback | Trigger | What it does |
|---|---|---|
| `init/1` | On startup | Starts `:timer.send_interval/2` which sends `:check` to self every `interval_ms` ms |
| `handle_call(:check_now)` | `check_now/1` | Runs `do_check/1` immediately (used in tests to skip the timer) |
| `handle_cast({:set_threshold, n})` | `set_threshold/2` | Updates the threshold without restarting |
| `handle_info(:check)` | Periodic timer | Queries `Items.list_low_stock(threshold)`, broadcasts `{:low_stock, items}` if any found |
| `terminate/2` | Process shutdown | Calls `:timer.cancel/1` to stop the interval |

**`:timer.send_interval/2` vs `Process.send_after/3`:**

| | `:timer.send_interval` | `Process.send_after` |
|---|---|---|
| Repeats? | Yes, automatically | No, one-shot |
| Use case | Periodic background work | Timeout / deadline |
| Cancel | `:timer.cancel(ref)` | `Process.cancel_timer(ref)` |

---

### 3.6 `Inventory.InventorySupervisor` — Supervisor

**File:** `lib/inventory/inventory_supervisor.ex`

```elixir
children = [
  {Inventory.Store, name: Inventory.Store},
  {Inventory.LowStockMonitor, name: Inventory.LowStockMonitor, ...}
]
Supervisor.init(children, strategy: :one_for_one)
```

**Strategy: `one_for_one`** — if `Store` crashes, only `Store` restarts. `LowStockMonitor` keeps running. This is correct here because they are independent: `Monitor` does not hold state that `Store` depends on.

**If you needed `rest_for_one`:** use it when later children depend on earlier children's state. For example, if `LowStockMonitor` needed to subscribe to a channel that `Store` manages, you'd want `Monitor` to restart whenever `Store` does.

**Circuit breaker:** `max_restarts: 3, max_seconds: 5` — if either child crashes more than 3 times in 5 seconds, the supervisor itself exits (and the Application supervisor above it decides what to do).

The `InventorySupervisor` is started from `Inventory.Application` after `Inventory.Repo` and `Phoenix.PubSub` are up, because both GenServers depend on those.

---

### 3.7 `InventoryWeb.InventoryLive.Index` — LiveView

**File:** `lib/inventory_web/live/inventory_live/index.ex`

**Routes and live actions:**

| URL | Live Action | What opens |
|---|---|---|
| `/inventory` | `:index` | Item table + dashboard |
| `/inventory/new` | `:new` | Add item modal |
| `/inventory/:id/edit` | `:edit` | Edit item modal |
| `/inventory/:id/stock` | `:stock` | Stock management modal |
| `/inventory/:id/reservations` | `:reservations` | Reservation list modal |

**LiveView callbacks used:**

| Callback | Role |
|---|---|
| `mount/3` | Subscribes to PubSub, loads initial assigns |
| `handle_params/3` | Calls `apply_action/3` based on the current `live_action`; drives which modal is open |
| `handle_event/3` | Handles user clicks: delete, update_stock, reserve, confirm_reservation, cancel_reservation, dismiss_low_stock |
| `handle_info/3` | Handles all PubSub messages; calls `reload/1` to refresh items/stats from DB |

**Why `live_patch` and not `live_navigate`?**

`<.link patch={~p"/inventory/new"}>` uses `live_patch`, which changes the URL and calls `handle_params` **without** remounting the LiveView. State (like flash messages or the item list) is preserved. `live_navigate` would remount from scratch.

---

## 4. GenServer Callback Reference

Quick cheat-sheet for all callbacks used in this project:

```elixir
# Return values for each callback:

def init(args) do
  {:ok, initial_state}
  # or {:stop, reason}
end

def handle_call(request, from, state) do
  {:reply, response, new_state}
  # or {:noreply, new_state}  # reply later with GenServer.reply(from, response)
  # or {:stop, reason, response, new_state}
end

def handle_cast(request, state) do
  {:noreply, new_state}
  # or {:stop, reason, new_state}
end

def handle_info(message, state) do
  {:noreply, new_state}
  # or {:stop, reason, new_state}
end

def terminate(reason, state) do
  # return value is ignored
  :ok
end
```

**When to use `call` vs `cast`:**

| | `handle_call` | `handle_cast` |
|---|---|---|
| Caller blocks? | Yes — waits for reply | No — returns `:ok` immediately |
| Use when | You need a result back | Fire-and-forget; you don't need confirmation |
| Example | `get_item/1`, `reserve_stock/4` | `async_restock/2`, `track_reservation/3` |

**Synchronising after a cast in tests:**

A `cast` is asynchronous — the GenServer may not have processed it yet when you check state. The standard idiom is to follow a `cast` with a `call` (which must be processed after the cast in the mailbox):

```elixir
Store.track_reservation(store, id, 60_000)  # cast
timers = Store.dump_timers(store)            # call — processes after the cast
```

---

## 5. Data Flow Diagrams

### Reserving Stock

```
User clicks "Reserve" in LiveView
        │
        ▼
handle_event("reserve", %{"qty" => "5"}, socket)
        │
        ├─► Items.create_reservation(item_id, 5, 60_000)
        │       │
        │       ├─ DB transaction:
        │       │   1. Lock item row
        │       │   2. Check available >= 5
        │       │   3. UPDATE items SET reserved_qty = reserved_qty + 5
        │       │   4. INSERT reservations (status: "pending", expires_at: now+60s)
        │       │
        │       └─► PubSub.broadcast("inventory", {:reservation_created, reservation})
        │
        ├─► Store.track_reservation(reservation.id, 60_000)  [cast]
        │       │
        │       └─► Process.send_after(self(), {:expire_reservation, id}, 60_000)
        │
        └─► put_flash(:info, "Reserved 5 unit(s)...")
```

### Reservation Expiry (automatic)

```
60 seconds later...

Store receives handle_info({:expire_reservation, id}, state)
        │
        ├─► Remove timer ref from state
        │
        └─► Task.start(fn -> Items.expire_reservation(id) end)
                │
                ├─ DB transaction:
                │   1. Fetch reservation (guard: skip if not "pending")
                │   2. UPDATE items SET reserved_qty = reserved_qty - quantity
                │   3. UPDATE reservations SET status = "expired"
                │
                └─► PubSub.broadcast("inventory", {:reservation_expired, reservation})
                        │
                        ▼
            LiveView receives handle_info({:reservation_expired, _})
                        │
                        └─► reload() + put_flash(:warning, "A reservation expired...")
```

### Low Stock Monitoring

```
Every 30 seconds (configurable):

:timer.send_interval fires → LowStockMonitor receives handle_info(:check, state)
        │
        └─► Items.list_low_stock(threshold)  [DB query]
                │
                └─ if results != [] →
                        PubSub.broadcast("inventory", {:low_stock, [item, ...]})
                                │
                                ▼
                    LiveView receives handle_info({:low_stock, items})
                                │
                                └─► assign(:low_stock_items, items)
                                    → yellow alert banner appears in real time
```

---

## 6. Testing Guide

### 6.1 Running the Test Suite

```bash
# Full test run (handles DB setup automatically via mix.exs alias)
mix test test/inventory/

# Run a single test file
mix test test/inventory/store_test.exs

# Run a single test by line number
mix test test/inventory/store_test.exs:44

# Run with verbose output (see each test name)
mix test test/inventory/ --trace

# Run with seed for reproducibility
mix test test/inventory/ --seed 12345
```

**Test structure:**

```
test/inventory/
├── store_test.exs            # Timer manager GenServer tests (DataCase)
└── low_stock_monitor_test.exs  # Monitor + Items context tests (DataCase)
```

Both files use `use Inventory.DataCase, async: false`.

`async: false` is required because:
1. GenServer processes started by `start_supervised!` run in their own processes, not the test process.
2. Ecto's SQL sandbox in **shared** mode (enabled by `async: false`) allows all processes to share the test's DB transaction, which is rolled back after each test.

---

### 6.2 Manual UI Testing Scenarios

Start the server (`mix phx.server`) and open **http://localhost:4000/inventory**.

#### Scenario 1 — Create items and verify stats

1. Click **+ New Item**.
2. Fill in: Name = `Widget Pro`, SKU = `WGT-001`, Quantity = `50`, Price = `999`.
3. Click **Save Item**.
4. Verify: item appears in the table, "Total Items" counter increments.
5. Create a second item with Quantity = `3` (below threshold of 10).
6. Verify: the "Low Stock" counter turns yellow; item row is highlighted; the yellow alert banner appears.

#### Scenario 2 — Edit and delete

1. Click **Edit** on any item.
2. Change the name. Note: the SKU field is disabled (immutable after creation).
3. Save and verify the table updates.
4. Click **Delete** on an item → confirm the dialog → verify it disappears and stats update.

#### Scenario 3 — Stock update (positive and negative delta)

1. Click **Stock** on an item with Quantity = `50`.
2. The modal shows current available stock.
3. Enter delta = `-10` → click **Apply** → stock becomes 40.
4. Enter delta = `10` → click **Apply** → stock becomes 50 again.
5. Enter delta = `-999` → **Apply** → you should see an error flash: "Insufficient stock".

#### Scenario 4 — Reservation lifecycle (happy path)

1. Click **Stock** on an item (e.g. quantity 50).
2. In the "Reserve Stock" section, enter `5` → click **Reserve**.
3. Flash message: "Reserved 5 unit(s). Expires in 60 seconds."
4. Verify in the table: Qty = 50, Reserved = 5, Available = 45.
5. Click **Reservations** on that item.
6. The modal shows the reservation with status `pending`.
7. Click **Confirm** → reservation status becomes `confirmed`, Available drops to 45 permanently, Reserved goes to 0, Qty becomes 45.

#### Scenario 5 — Reservation cancellation

1. Same as above, but click **Cancel** instead of **Confirm**.
2. Reservation status becomes `cancelled`, Available returns to 50, Reserved goes to 0.

#### Scenario 6 — Reservation expiry (automatic)

The default timeout is 60 seconds. To test quickly, temporarily lower it in `index.ex`:

```elixir
@reserve_timeout_ms 10_000   # 10 seconds for testing
```

Then:

1. Restart the server.
2. Create a reservation.
3. Do **not** confirm or cancel it.
4. Wait ~10 seconds.
5. Observe: the page auto-updates (via PubSub), a warning flash appears ("A reservation expired and stock was released"), and the reservation status in the Reservations modal is now `expired`.

#### Scenario 7 — Real-time multi-tab behaviour

1. Open **http://localhost:4000/inventory** in two browser tabs.
2. In Tab A, add a new item.
3. Observe Tab B updates automatically without a page refresh.
4. In Tab A, make a reservation and let it expire.
5. Observe the expiry warning flash appears in **both** tabs simultaneously.

#### Scenario 8 — Duplicate SKU rejection

1. Add an item with SKU = `WGT-001`.
2. Try to add another item with the same SKU.
3. The form should show a validation error: "has already been taken".

#### Scenario 9 — Overselling protection

1. Create an item with Quantity = `10`.
2. Reserve 8 units (Reserved = 8, Available = 2).
3. In the Stock modal, try to apply delta = `-5`.
4. Error: "Insufficient stock" — you cannot reduce quantity below reserved_qty.

#### Scenario 10 — GenServer crash recovery

Open an IEx session alongside the running app:

```bash
iex -S mix phx.server
```

Then:

```elixir
# Find the Store pid
pid = Process.whereis(Inventory.Store)

# Kill it — the supervisor will restart it within milliseconds
Process.exit(pid, :kill)

# Store is back, timers re-hydrated from DB
Process.whereis(Inventory.Store)  # new pid
Inventory.Store.dump_timers()     # pending reservations are re-tracked
```

Any pending reservations in the DB will have their timers restored automatically.

---

### 6.3 IEx / Console Testing

Run `iex -S mix` (or `iex -S mix phx.server` to have the full app):

```elixir
alias Inventory.{Items, Item, Store}

# --- Item CRUD ---
{:ok, item} = Items.create_item(%{name: "Gizmo", sku: "GIZ-001", quantity: 100, price: 1999})
Items.list_items()
Items.get_item!(item.id)

# --- Stock ---
Items.update_stock(item, -25)
Items.get_item!(item.id)  # quantity now 75

# --- Reservation ---
{:ok, res} = Items.create_reservation(item.id, 10, 30_000)
# Track the timer in the GenServer
Store.track_reservation(res.id, 30_000)

# Check timer is registered
Store.dump_timers()  # => %{res.id => #Reference<...>}

# Confirm it
{:ok, _} = Items.confirm_reservation(res.id)
Store.cancel_timer(res.id)  # cancel the now-unnecessary expiry timer

# Item stock permanently reduced
Items.get_item!(item.id)  # quantity = 65, reserved_qty = 0

# --- Stats ---
Items.stats()
# => %{total_items: 1, total_stock: 65, low_stock_count: 0, active_reservations: 0}

# --- Low stock check ---
Items.list_low_stock(70)  # any item with available <= 70

# --- Trigger monitor check manually ---
Inventory.LowStockMonitor.check_now()
Inventory.LowStockMonitor.set_threshold(80)  # runtime config change

# --- Inspect supervisor ---
Supervisor.which_children(Inventory.InventorySupervisor)
```

**Subscribing to PubSub from IEx:**

```elixir
Phoenix.PubSub.subscribe(Inventory.PubSub, "inventory")

# Now in another IEx session or via the UI, create an item.
# You'll receive the broadcast in this process:
flush()
# => {:item_created, %Inventory.Item{...}}
# => :ok
```

---

## 7. PubSub Event Reference

All events are broadcast on the `"inventory"` topic. Subscribe with `Items.subscribe()` in a LiveView's `mount/3` or directly with `Phoenix.PubSub.subscribe(Inventory.PubSub, "inventory")`.

| Message | Emitted by | When |
|---|---|---|
| `{:item_created, %Item{}}` | `Items.create_item/1` | New item inserted |
| `{:item_updated, %Item{}}` | `Items.update_item/2`, `Items.update_stock/2` | Item fields changed |
| `{:item_deleted, id}` | `Items.delete_item/1` | Item removed |
| `{:reservation_created, %Reservation{}}` | `Items.create_reservation/3` | New reservation pending |
| `{:reservation_confirmed, %Reservation{}}` | `Items.confirm_reservation/1` | Reservation confirmed |
| `{:reservation_cancelled, %Reservation{}}` | `Items.cancel_reservation/1` | Reservation cancelled |
| `{:reservation_expired, %Reservation{}}` | `Items.expire_reservation/1` | Timer fired, auto-expired |
| `{:low_stock, [%Item{}]}` | `LowStockMonitor` | Periodic check found low-stock items |

---

## 8. Database Schema

```sql
-- items
CREATE TABLE items (
  id          SERIAL PRIMARY KEY,
  name        VARCHAR NOT NULL,
  sku         VARCHAR NOT NULL UNIQUE,
  quantity    INTEGER NOT NULL DEFAULT 0,
  reserved_qty INTEGER NOT NULL DEFAULT 0,
  price       INTEGER NOT NULL DEFAULT 0,   -- cents
  inserted_at TIMESTAMP NOT NULL,
  updated_at  TIMESTAMP NOT NULL
);

-- reservations
CREATE TABLE reservations (
  id          SERIAL PRIMARY KEY,
  item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  quantity    INTEGER NOT NULL,
  status      VARCHAR NOT NULL DEFAULT 'pending',
  expires_at  TIMESTAMP NOT NULL,
  inserted_at TIMESTAMP NOT NULL,
  updated_at  TIMESTAMP NOT NULL
);
```

**Invariants maintained by the context:**

- `quantity >= reserved_qty` — always true after any successful write
- `quantity >= 0` — enforced by `update_stock/2`
- Only `pending` reservations can transition to `confirmed`, `cancelled`, or `expired` — guarded in each context function

---

## 9. Troubleshooting

### "database inventory_dev does not exist"

```bash
mix ecto.create && mix ecto.migrate
```

### "connection refused" on DB startup

PostgreSQL is not running. Start it:

```bash
# macOS with Homebrew
brew services start postgresql@16

# or with pg_ctl
pg_ctl -D /usr/local/var/postgres start
```

### Reservation timers lost after restart

This should not happen — `Store.init/1` re-hydrates from the DB. If timers appear lost, check:

```elixir
# In IEx — are there pending reservations?
Inventory.Items.list_pending_reservations()

# Are the timers loaded?
Inventory.Store.dump_timers()
```

If `list_pending_reservations` returns rows but `dump_timers` is empty, the Store crashed during `init` (likely a DB connectivity issue during startup).

### Low stock banner not appearing

1. Check threshold — default is 10. Items with `available > 10` won't trigger it.
2. Trigger a manual check: `Inventory.LowStockMonitor.check_now()` from IEx.
3. Verify the LiveView is connected (not a static render): PubSub subscriptions only happen when `connected?(socket)` is true.

### Flash message `:warning` not styled

Phoenix's default flash keys are `:info` and `:error`. The `:warning` key used for expiry alerts may not have a style in `core_components.ex`. Add it:

```elixir
# In lib/inventory_web/components/core_components.ex, find the flash component
# and add a clause for :warning, e.g.:
"warning" -> "bg-yellow-50 text-yellow-800 ring-yellow-600/20 fill-yellow-400"
```

### Tests fail with "ownership error" or sandbox issues

This happens when a GenServer process tries to use the DB but isn't allowed by the sandbox. Ensure:

- Tests use `async: false` (shared sandbox mode)
- `start_supervised!` is used (not `GenServer.start_link` directly) so the process is linked to the test

### "CompileError: ^ operator" in tests

You cannot pin a field access:

```elixir
# Wrong:
assert_receive {:item_deleted, ^item.id}

# Correct:
item_id = item.id
assert_receive {:item_deleted, ^item_id}
```

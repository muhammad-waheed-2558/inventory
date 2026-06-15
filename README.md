# Inventory Management System — Developer Guide

A Phoenix LiveView application built to learn GenServer in depth. The system combines five distinct GenServer patterns with Ecto persistence and real-time UI via LiveView and PubSub.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Architecture Overview](#2-architecture-overview)
3. [Why Use GenServer At All? (vs. pure DB)](#3-why-use-genserver-at-all-vs-pure-db)
4. [The Five GenServer Patterns](#4-the-five-genserver-patterns)
   - 4.1 [Store — Timer Manager](#41-inventorystore--timer-manager)
   - 4.2 [LowStockMonitor — Periodic Broadcaster](#42-inventorylowstockmonitor--periodic-broadcaster)
   - 4.3 [ItemCache — ETS-backed Read Cache](#43-inventoryitemcache--ets-backed-read-cache)
   - 4.4 [BackorderQueue — Cross-process Messaging](#44-inventorybackorderqueue--cross-process-messaging)
   - 4.5 [CartServer — One Process Per Entity](#45-inventorycartserver--one-process-per-entity)
5. [Supporting Modules](#5-supporting-modules)
   - 5.1 [Schemas](#51-schemas)
   - 5.2 [Items Context](#52-inventoryitems--context)
   - 5.3 [Supervisors](#53-supervisors)
   - 5.4 [LiveView](#54-liveview)
6. [GenServer Callback Reference](#6-genserver-callback-reference)
7. [Data Flow Diagrams](#7-data-flow-diagrams)
8. [Testing Guide](#8-testing-guide)
   - 8.1 [Running the Test Suite](#81-running-the-test-suite)
   - 8.2 [Why `async: false`](#82-why-async-false)
   - 8.3 [Manual UI Testing Scenarios](#83-manual-ui-testing-scenarios)
   - 8.4 [IEx Console Playground](#84-iex-console-playground)
9. [PubSub Event Reference](#9-pubsub-event-reference)
10. [Database Schema](#10-database-schema)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Quick Start

```bash
# Install dependencies
mix deps.get

# Create the database and run migrations
mix ecto.create && mix ecto.migrate

# Start the Phoenix server
mix phx.server
```

Open **http://localhost:4000/inventory** in your browser.

```bash
# Run all GenServer unit tests
mix test test/inventory/

# Run with verbose output (each test name visible)
mix test test/inventory/ --trace
```

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           Phoenix Application                                │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐    │
│  │                    Inventory.InventorySupervisor                     │    │
│  │                        (one_for_one strategy)                        │    │
│  │                                                                      │    │
│  │  ┌──────────────┐  ┌──────────────────┐  ┌───────────┐  ┌────────┐  │    │
│  │  │ Store        │  │ LowStockMonitor  │  │ ItemCache │  │Backord-│  │    │
│  │  │ (timer mgr)  │  │ (periodic check) │  │ (ETS)     │  │erQueue │  │    │
│  │  └──────────────┘  └──────────────────┘  └───────────┘  └────────┘  │    │
│  └──────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────┐                │
│  │              Inventory.CartSupervisor (DynamicSupervisor)│                │
│  │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │                │
│  │   │ CartServer   │  │ CartServer   │  │ CartServer   │  │                │
│  │   │ cart-abc     │  │ cart-def     │  │ cart-xyz     │  │                │
│  │   └──────────────┘  └──────────────┘  └──────────────┘  │                │
│  └─────────────────────────────────────────────────────────┘                │
│                  ▲ Registry.CartRegistry (via-tuples)                        │
│                                                                              │
│  Inventory.Items (context — ALL DB reads and writes)                         │
│         │                                                                    │
│         │  broadcasts on "inventory" PubSub topic after every mutation       │
│         ▼                                                                    │
│  Phoenix.PubSub ──► InventoryWeb.InventoryLive.Index (LiveView)              │
│                 └──► ItemCache (cache invalidation)                          │
│                 └──► BackorderQueue (fulfilment trigger)                     │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Core design principle: DB is the single source of truth.** PostgreSQL holds all item quantities, reservation counts, and statuses. The GenServers hold only ephemeral state — timer references, queue entries, a cache copy — that would be acceptable to lose and regenerate after a restart.

---

## 3. Why Use GenServer At All? (vs. pure DB)

This is the first question to ask before reaching for GenServer. Here's a candid comparison:

### What PostgreSQL gives you that GenServer cannot

PostgreSQL provides ACID transactions, crash durability (data survives server restarts), horizontal scaling via read replicas, and decades of query tooling. For anything that must persist and be correct, the DB wins.

### What GenServer gives you that PostgreSQL cannot

**1. Sub-microsecond in-memory reads (ItemCache)**

An ETS lookup is ~100ns. A DB round-trip on the same machine is ~1ms. At 1,000 reads per second that's the difference between 0.1ms and 1,000ms total latency. Once your item catalogue is read far more than it is written, a GenServer-owned ETS table eliminates DB load entirely for reads.

**2. Stateful timers across the process boundary (Store)**

Reservations expire after 60 seconds. You could poll the DB every second — but that's wasteful. Instead, `Process.send_after/3` fires a single message at exactly the right time. The problem: timer references are per-process memory. A DB cannot hold a timer reference. A GenServer can, and if it crashes its supervisor restarts it, `init/1` re-reads pending reservations from the DB, and timers are reconstructed.

**3. Coordinated multi-party notification (BackorderQueue)**

"Tell me when item #42 is back in stock" cannot be expressed as a DB query. The DB has no way to push a message to a waiting process. A GenServer can monitor waiting PIDs, and when stock arrives (via PubSub), send each caller exactly the message it is waiting for — with no polling.

**4. Per-entity isolated state (CartServer)**

A shopping cart lives for 30 minutes, belongs to one user, and needs its own TTL timer. Creating one process per cart means carts are completely isolated: a bug in cart A cannot corrupt cart B. The OS scheduler handles concurrency for free. And when a cart is checked out, its process stops cleanly.

**5. Coordinated background work (LowStockMonitor)**

Running "check low stock" on a schedule is awkward in a DB. You need an external cron job, a polling loop somewhere, or a job queue library. A GenServer can schedule its own next wakeup with `:timer.send_interval/2` and run the check inline.

### The rule of thumb for this project

| Concern | Where it lives | Why |
|---|---|---|
| Item data, quantities, prices | PostgreSQL | Must survive restarts; ACID required |
| Reservation records and status | PostgreSQL | Must survive restarts |
| Reservation expiry timers | Store GenServer | Timers are in-memory references; re-hydrated from DB on restart |
| Periodic low-stock checks | LowStockMonitor GenServer | Background scheduling |
| Item read cache | ItemCache GenServer + ETS | Read performance; invalidated by PubSub |
| Backorder demand queue | BackorderQueue GenServer | Multi-party async notification |
| Shopping cart contents + TTL | CartServer GenServer | Isolated per-user state; short-lived |

---

## 4. The Five GenServer Patterns

Each GenServer in this project teaches a distinct concept. They are ordered from simplest to most advanced.

---

### 4.1 `Inventory.Store` — Timer Manager

**File:** `lib/inventory/store.ex`

**Core concept:** `handle_cast/2`, `handle_info/2`, timer references, non-blocking DB calls via `Task.start/1`

**State:**

```elixir
%{timers: %{reservation_id => timer_ref}}
```

The Store's only job is to hold timer references in memory so they can be cancelled if a reservation is confirmed or cancelled before it expires. It does not store any item or reservation data — that all lives in PostgreSQL.

**GenServer callbacks:**

| Callback | Trigger | What it does |
|---|---|---|
| `init/1` | On startup | Queries `Items.list_pending_reservations()`, re-creates timers for each, adjusting for elapsed time. Reservations that already expired while the server was down are immediately expired via `Task.start/1`. |
| `handle_cast({:track, id, ms})` | `track_reservation/3` | Calls `Process.send_after(self(), {:expire_reservation, id}, ms)`, stores the ref |
| `handle_cast({:cancel, id})` | `cancel_timer/2` | Calls `Process.cancel_timer(ref)`, removes the entry |
| `handle_call(:dump_timers)` | `dump_timers/1` | Returns the full timers map — useful for testing and debugging |
| `handle_info({:expire_reservation, id})` | Timer fires | Removes the ref, spawns a `Task` to call `Items.expire_reservation/1` |
| `terminate/2` | Process shutdown | Cancels all outstanding timers |

**Key learning — why `Task.start` in `handle_info`:**

`Items.expire_reservation/1` runs a DB transaction. If it executed directly inside `handle_info`, the GenServer would be blocked — unable to process any new `track` or `cancel` casts — until the DB query completed. `Task.start` delegates to a separate process, keeping every callback O(1). The GenServer's mailbox never backs up.

**Key learning — why `handle_cast` for track/cancel:**

The caller doesn't need a result — it just wants the timer registered. Using `cast` instead of `call` means the caller is never blocked. The timer will be tracked; there's no error case to return.

**IEx example:**

```elixir
alias Inventory.{Items, Store}

{:ok, item} = Items.create_item(%{name: "Gizmo", sku: "GIZ-001", quantity: 50, price: 999})
{:ok, res}  = Items.create_reservation(item.id, 10, 30_000)
Store.track_reservation(res.id, 30_000)

Store.dump_timers()
# => %{1 => #Reference<0.123.0.1>}

# Cancel before expiry
Items.confirm_reservation(res.id)
Store.cancel_timer(res.id)
Store.dump_timers()
# => %{}
```

---

### 4.2 `Inventory.LowStockMonitor` — Periodic Broadcaster

**File:** `lib/inventory/low_stock_monitor.ex`

**Core concept:** `:timer.send_interval/2` for repeating timers, runtime configuration via `handle_cast/2`

**State:**

```elixir
%{threshold: integer, interval_ms: integer, timer_ref: reference}
```

**GenServer callbacks:**

| Callback | Trigger | What it does |
|---|---|---|
| `init/1` | On startup | Calls `:timer.send_interval(interval_ms, self(), :check)` to schedule repeating wakeups |
| `handle_info(:check)` | Every `interval_ms` | Queries `Items.list_low_stock(threshold)`, broadcasts `{:low_stock, items}` if any found |
| `handle_call(:check_now)` | `check_now/1` | Runs the check immediately — used in tests to skip the timer |
| `handle_cast({:set_threshold, n})` | `set_threshold/2` | Updates the threshold at runtime without restarting |
| `terminate/2` | Process shutdown | Calls `:timer.cancel(state.timer_ref)` |

**`:timer.send_interval/2` vs `Process.send_after/3`:**

| | `:timer.send_interval` | `Process.send_after` |
|---|---|---|
| Repeats? | Yes, automatically | No — one-shot |
| Use case | Periodic background work | Timeout / deadline |
| Cancel | `:timer.cancel(ref)` | `Process.cancel_timer(ref)` |

**IEx example:**

```elixir
# Trigger a check immediately (skips the 30-second wait)
Inventory.LowStockMonitor.check_now()

# Lower the threshold at runtime
Inventory.LowStockMonitor.set_threshold(5)
```

---

### 4.3 `Inventory.ItemCache` — ETS-backed Read Cache

**File:** `lib/inventory/item_cache.ex`

**Core concept:** `handle_continue/2`, ETS as a GenServer-owned read store, PubSub-driven cache invalidation

**State:**

```elixir
%{table: atom()}   # ETS table name
```

**The `handle_continue/2` callback:**

```
init/1 returns {:ok, state, {:continue, :load_items}}
         │
         │  GenServer is now registered (accepts calls)
         │  but before ANY external message is processed:
         ▼
handle_continue(:load_items, state)  ← runs here
         │
         └─► Items.list_items() → :ets.insert(table, ...)
```

`handle_continue/2` is the correct way to do deferred initialisation. The alternative — running the DB query inside `init/1` — blocks the supervisor and makes startup slower for all siblings. With `handle_continue`, the process is registered and ready, but the expensive work happens in a guaranteed-first callback.

**ETS table properties:**

```elixir
:ets.new(table_name, [
  :named_table,      # accessible by atom from any process
  :public,           # any process can read (only this GenServer writes)
  :set,              # one value per key (like a map)
  read_concurrency: true
])
```

The critical benefit: `ItemCache.get/1` and `ItemCache.all/0` read ETS **directly** — no message is sent to the GenServer, no blocking. At high read volume, thousands of processes can read concurrently with zero serialisation.

**GenServer callbacks:**

| Callback | Trigger | What it does |
|---|---|---|
| `init/1` | On startup | Creates ETS table, subscribes to PubSub, returns `{:continue, :load_items}` |
| `handle_continue(:load_items)` | Immediately after init | Loads all items into ETS from DB |
| `handle_info({:item_created, item})` | PubSub broadcast | `ets.insert(table, {item.id, item})` |
| `handle_info({:item_updated, item})` | PubSub broadcast | `ets.insert(table, {item.id, item})` (upsert) |
| `handle_info({:item_deleted, id})` | PubSub broadcast | `ets.delete(table, id)` |
| `handle_call(:reload)` | `reload/1` | Clears and reloads from DB — for bulk imports |

**IEx example:**

```elixir
alias Inventory.ItemCache

# Direct ETS read — no GenServer call, no message:
ItemCache.get(1)       # => {:ok, %Item{...}}
ItemCache.get(99999)   # => :miss
ItemCache.all()        # => [%Item{...}, ...]
ItemCache.size()       # => 42

# Force full reload:
ItemCache.reload()     # => :ok
```

---

### 4.4 `Inventory.BackorderQueue` — Cross-process Messaging

**File:** `lib/inventory/backorder_queue.ex`

**Core concept:** `Process.monitor/1` for subscriber cleanup, deferred cross-process `send/2`, complex nested state

**State:**

```elixir
%{
  queues: %{
    item_id => [
      %{pid: pid, ref: reference, quantity: integer, monitor_ref: reference}
    ]
  }
}
```

**The cross-process messaging pattern:**

```
Caller process                    BackorderQueue GenServer
─────────────                     ─────────────────────────
enqueue(item_id, qty)  ────call──► handle_call({:enqueue, ...})
                                     backorder_ref = make_ref()
{:ok, ref}            ◄───reply──    monitor_ref = Process.monitor(pid)
                                     store entry in queues map
                       ...wait...

                                   handle_info({:item_updated, item})
                                     available = Item.available(item)
                                     fulfilled = pick entries that fit
                                     send(entry.pid, {:backorder_ready, ref, item_id, qty})
{:backorder_ready,     ◄───send──
  ref, item_id, qty}
```

This is fundamentally different from `GenServer.reply/2`: the GenServer sends the notification inside a **different** callback (`handle_info`) than the one that received the original request (`handle_call`). The caller registered its PID, got a reference, and waits for a message that arrives later — truly asynchronous.

**Dead subscriber cleanup via `Process.monitor/1`:**

If the calling process dies before its backorder is filled (e.g. the user closes their browser tab), the GenServer receives `{:DOWN, monitor_ref, :process, pid, reason}` via `handle_info`. It removes that entry from the queue — preventing a memory leak of indefinitely accumulating dead backorders.

**Partial fulfilment:** When stock arrives, the queue is consumed greedily in FIFO order. If the restocked quantity fits the first entry but not the second, only the first caller is notified. The second stays in the queue.

**IEx example:**

```elixir
alias Inventory.{Items, BackorderQueue}

# Item with no stock
{:ok, item} = Items.create_item(%{name: "Widget", sku: "WGT-1", quantity: 0, price: 500})

# Register demand
{:ok, ref} = BackorderQueue.enqueue(item.id, 5)

# Restock the item — BackorderQueue receives {:item_updated, item} via PubSub
Items.update_stock(item, 10)

# Your process receives:
receive do
  {:backorder_ready, ^ref, item_id, qty} ->
    IO.puts("Backorder ready: #{qty} units of item #{item_id}")
end

# View pending backorders
BackorderQueue.pending()
# => %{1 => [%{pid: #PID<...>, quantity: 5, ref: #Reference<...>}]}
```

---

### 4.5 `Inventory.CartServer` — One Process Per Entity

**File:** `lib/inventory/cart_server.ex`
**Supervisor:** `lib/inventory/cart_supervisor.ex`

**Core concept:** `DynamicSupervisor`, `Registry` with via-tuples, sliding-window TTL, atomic checkout with rollback

**State:**

```elixir
%{cart_id: String.t(), items: %{item_id => quantity}, timer_ref: reference}
```

#### Registry and via-tuples

Instead of a single global name, each CartServer registers under its `cart_id` in a `Registry`:

```elixir
def via_tuple(cart_id), do: {:via, Registry, {Inventory.CartRegistry, cart_id}}

# GenServer.start_link accepts a via-tuple as the :name option
GenServer.start_link(__MODULE__, cart_id, name: via_tuple(cart_id))

# Any GenServer call also accepts a via-tuple — Registry resolves to the PID
GenServer.call(via_tuple(cart_id), :get)
```

Benefits: O(log n) lookup, guaranteed at-most-one process per cart_id, no manual pid tracking.

#### DynamicSupervisor

Carts are started at runtime — you don't know cart IDs at compile time:

```elixir
# CartSupervisor.start_cart/1:
DynamicSupervisor.start_child(__MODULE__, {Inventory.CartServer, cart_id})
```

The supervisor automatically restarts crashed carts. When a cart finishes normally (checkout or TTL expiry), it returns `{:stop, :normal, state}` — the supervisor sees `:normal` and does **not** restart it.

#### Sliding-window TTL

The cart expires after 30 minutes of inactivity. Each `add_item/3` or `remove_item/3` call resets the timer:

```elixir
defp reset_ttl(state) do
  Process.cancel_timer(state.timer_ref)           # cancel old timer
  %{state | timer_ref: schedule_ttl()}            # start fresh 30-min timer
end
```

If the user keeps adding items, the cart never expires. If they abandon the cart for 30 minutes, `handle_info(:ttl_expire, state)` fires and the process stops cleanly.

#### Atomic checkout with rollback

```elixir
result = Enum.reduce_while(state.items, {:ok, []}, fn {item_id, qty}, {:ok, reservations} ->
  case Items.create_reservation(item_id, qty, @checkout_reservation_ms) do
    {:ok, reservation} -> {:cont, {:ok, [reservation | reservations]}}
    {:error, reason}   -> {:halt, {:error, reason, reservations}}
  end
end)

case result do
  {:ok, reservations} -> ...
  {:error, reason, partial_reservations} ->
    # Roll back everything that succeeded before the failure
    Enum.each(partial_reservations, fn res ->
      Items.cancel_reservation(res.id)
      Store.cancel_timer(res.id)
    end)
end
```

This ensures checkout is all-or-nothing from the user's perspective: either all items are reserved or none are.

**IEx example:**

```elixir
alias Inventory.{Items, CartServer}

# Create items
{:ok, i1} = Items.create_item(%{name: "A", sku: "A-1", quantity: 10, price: 100})
{:ok, i2} = Items.create_item(%{name: "B", sku: "B-1", quantity: 5,  price: 200})

# Get or create a cart
{:ok, _pid} = CartServer.get_or_create("user-42")

# Add items
CartServer.add_item("user-42", i1.id, 2)
CartServer.add_item("user-42", i2.id, 1)

# View cart
CartServer.get_cart("user-42")
# => %{1 => 2, 2 => 1}

# Checkout
{:ok, reservations} = CartServer.checkout("user-42")
# => [{:ok, %Reservation{item_id: 1, quantity: 2, ...}}, ...]

# Cart is now empty
CartServer.get_cart("user-42")
# => %{}
```

---

## 5. Supporting Modules

### 5.1 Schemas

**`Inventory.Item`** (`lib/inventory/item.ex`) — maps to the `items` table.

| Field | Type | Notes |
|---|---|---|
| `id` | integer | Auto-generated primary key |
| `name` | string | Required, max 100 chars |
| `sku` | string | Required, unique, immutable after creation |
| `quantity` | integer | Total units on hand (≥ 0) |
| `reserved_qty` | integer | Units held by pending reservations |
| `price` | integer | Price in cents (e.g. 999 = $9.99) |

`Item.available/1` returns `quantity - reserved_qty`. This is the number of units a customer can actually buy.

Two changesets exist intentionally: `changeset/2` (used on create, validates and locks `sku`) and `update_changeset/2` (used on edit, omits `sku` to prevent changes).

**`Inventory.Reservation`** (`lib/inventory/reservation.ex`) — maps to the `reservations` table.

| Field | Type | Notes |
|---|---|---|
| `id` | integer | Auto-generated |
| `item_id` | integer | FK → items (cascade delete) |
| `quantity` | integer | Units held (> 0) |
| `status` | string | `pending` → `confirmed` / `cancelled` / `expired` |
| `expires_at` | datetime | When the reservation auto-expires |

Status lifecycle:

```
pending ──► confirmed   (user confirms before timer fires)
        ──► cancelled   (user cancels before timer fires)
        ──► expired     (Process.send_after fires; Store calls Items.expire_reservation)
```

---

### 5.2 `Inventory.Items` — Context

**File:** `lib/inventory/items.ex`

All DB operations go through this module. Nothing else in the app touches Ecto directly.

**Item operations:**

| Function | Description |
|---|---|
| `list_items/0` | All items ordered by id |
| `get_item!/1` | Raises if not found |
| `create_item/1` | Inserts + broadcasts `{:item_created, item}` |
| `update_item/2` | Updates fields + broadcasts `{:item_updated, item}` |
| `delete_item/1` | Deletes + broadcasts `{:item_deleted, id}` |
| `update_stock/2` | Adjusts quantity by delta inside a transaction; guards against `quantity < reserved_qty` |

**Reservation operations:**

| Function | Description |
|---|---|
| `create_reservation/3` | Atomically bumps `reserved_qty`, inserts row, broadcasts |
| `confirm_reservation/1` | Deducts stock permanently, sets status `confirmed`, broadcasts |
| `cancel_reservation/1` | Releases reserved stock, sets status `cancelled`, broadcasts |
| `expire_reservation/1` | Called by `Store` on timer expiry; safe to call on already-resolved reservations |
| `list_pending_reservations/0` | Used by `Store.init/1` to re-hydrate timers on startup |

**Analytics:**

| Function | Description |
|---|---|
| `stats/0` | `%{total_items, total_stock, low_stock_count, active_reservations}` |
| `list_low_stock/1` | Items where `available ≤ threshold` |

**PubSub:**

```elixir
# Subscribe from any process:
Items.subscribe()

# Your process then receives these messages:
# {:item_created, %Item{}}
# {:item_updated, %Item{}}
# {:item_deleted, id}
# {:reservation_created, %Reservation{}}
# {:reservation_confirmed, %Reservation{}}
# {:reservation_cancelled, %Reservation{}}
# {:reservation_expired, %Reservation{}}
# {:low_stock, [%Item{}]}
```

---

### 5.3 Supervisors

**`Inventory.InventorySupervisor`** — starts `Store`, `LowStockMonitor`, `ItemCache`, and `BackorderQueue` under `one_for_one`. A crash in any one child does not restart the others.

**`Inventory.CartSupervisor`** — a `DynamicSupervisor` that starts one `CartServer` per cart at runtime. Started from `Application` alongside a `Registry` with `keys: :unique`.

**Start order in `Application.start/2`:**

1. `Inventory.Repo` (DB connection pool)
2. `Phoenix.PubSub` (needed by all GenServers that subscribe)
3. `Inventory.CartRegistry` (needed by CartSupervisor)
4. `Inventory.CartSupervisor` (needed by CartServer.get_or_create)
5. `Inventory.InventorySupervisor` (Store, Monitor, Cache, Queue)
6. `InventoryWeb.Endpoint` (HTTP server, last)

---

### 5.4 LiveView

**`InventoryWeb.InventoryLive.Index`** (`lib/inventory_web/live/inventory_live/index.ex`)

| URL | Live Action | What opens |
|---|---|---|
| `/inventory` | `:index` | Item table + dashboard |
| `/inventory/new` | `:new` | Add item modal |
| `/inventory/:id/edit` | `:edit` | Edit item modal |
| `/inventory/:id/stock` | `:stock` | Stock management modal |
| `/inventory/:id/reservations` | `:reservations` | Reservation list modal |

The LiveView subscribes to PubSub in `mount/3` and reacts to all eight event types in `handle_info/3`. No polling — every UI update is event-driven.

---

## 6. GenServer Callback Reference

```elixir
# Every callback and what it returns:

def init(args) do
  {:ok, initial_state}
  {:ok, initial_state, {:continue, :some_key}}  # triggers handle_continue/2
  {:stop, reason}
end

def handle_continue(key, state) do
  {:noreply, new_state}
end

def handle_call(request, from, state) do
  {:reply, response, new_state}
  {:noreply, new_state}           # reply later with GenServer.reply(from, value)
  {:stop, reason, response, state}
end

def handle_cast(request, state) do
  {:noreply, new_state}
  {:stop, reason, new_state}
end

def handle_info(message, state) do
  {:noreply, new_state}
  {:stop, reason, new_state}
end

def terminate(reason, state) do
  :ok   # return value is ignored
end
```

**When to use `call` vs `cast`:**

| | `handle_call` | `handle_cast` |
|---|---|---|
| Caller blocks? | Yes — waits for reply | No — returns `:ok` immediately |
| Use when | You need a result back | Fire-and-forget |
| Example here | `enqueue/3`, `dump_timers/1` | `track_reservation/3`, `cancel_timer/2`, `clear/1` |

**Synchronising a cast in tests** — since a cast is async, the GenServer may not have processed it when your next assertion runs. The idiom is to follow with a call (which must process after the cast in the mailbox):

```elixir
Store.track_reservation(store, id, 60_000)  # cast — async
timers = Store.dump_timers(store)            # call — forces flush of mailbox
```

---

## 7. Data Flow Diagrams

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
        │       │   4. INSERT reservations (status: pending, expires_at: now+60s)
        │       │
        │       └─► PubSub.broadcast("inventory", {:reservation_created, reservation})
        │
        └─► Store.track_reservation(reservation.id, 60_000)  [cast]
                └─► Process.send_after(self(), {:expire_reservation, id}, 60_000)
```

### Reservation Expiry

```
60 seconds later...

Store receives: handle_info({:expire_reservation, id}, state)
        │
        ├─► Remove timer ref from state
        └─► Task.start(fn -> Items.expire_reservation(id) end)
                │
                ├─ DB transaction:
                │   1. Fetch reservation (skip if not "pending")
                │   2. UPDATE items SET reserved_qty = reserved_qty - quantity
                │   3. UPDATE reservations SET status = "expired"
                │
                └─► PubSub.broadcast("inventory", {:reservation_expired, reservation})
                        │
                        ▼
            LiveView handle_info({:reservation_expired, _})
                        └─► reload() + put_flash(:warning, "A reservation expired...")
```

### Backorder Fulfilment

```
Caller process                BackorderQueue              Items context + PubSub
──────────────                ──────────────              ──────────────────────
enqueue(item_id, 5) ──call──► handle_call(:enqueue)
{:ok, ref}          ◄─reply─    monitor_ref = Process.monitor(pid)
                                store {pid, ref, 5, monitor_ref} in queues

                              ...other operations...

                                                   Items.update_stock(item, 20)
                                                   broadcast({:item_updated, item})

                              handle_info({:item_updated, item})
                                available = Item.available(item)  # 20
                                entry.quantity == 5 ≤ 20 → fulfill
                                Process.demonitor(monitor_ref)
{:backorder_ready,  ◄─send─   send(entry.pid, {:backorder_ready, ref, item_id, 5})
  ref, item_id, 5}
```

### CartServer Checkout with Rollback

```
CartServer.checkout("user-42")
        │
        ├─► Enum.reduce_while(items, {:ok, []}, fn {item_id, qty}, {:ok, reservations} ->
        │       case Items.create_reservation(item_id, qty, 10_min) do
        │         {:ok, res}         -> {:cont, {:ok, [res | reservations]}}
        │         {:error, :no_stock} -> {:halt, {:error, :no_stock, reservations}}
        │       end
        │   end)
        │
        ├─ All succeed:
        │     {:reply, {:ok, Enum.reverse(reservations)}, reset_ttl(empty_state)}
        │
        └─ One fails after 2 succeed:
              Enum.each(partial_reservations, fn res ->
                Items.cancel_reservation(res.id)
                Store.cancel_timer(res.id)
              end)
              {:reply, {:error, :no_stock}, state}
```

---

## 8. Testing Guide

### 8.1 Running the Test Suite

```bash
# Full suite
mix test test/inventory/

# Single file
mix test test/inventory/store_test.exs

# Single test by line number
mix test test/inventory/cart_server_test.exs:55

# Verbose (see each test name)
mix test test/inventory/ --trace

# Reproducible run
mix test test/inventory/ --seed 12345
```

Test files and what each covers:

| File | GenServer tested | Key concepts |
|---|---|---|
| `store_test.exs` | `Store` | Timer re-hydration on startup, track/cancel cast, expiry via `handle_info` |
| `low_stock_monitor_test.exs` | `LowStockMonitor` | PubSub broadcast, set_threshold cast, periodic timer |
| `item_cache_test.exs` | `ItemCache` | `handle_continue`, ETS direct reads, PubSub invalidation, reload |
| `backorder_queue_test.exs` | `BackorderQueue` | `Process.monitor` cleanup, cross-process `send`, partial fulfilment |
| `cart_server_test.exs` | `CartServer` | Registry via-tuple, DynamicSupervisor, sliding-window TTL, checkout rollback |

---

### 8.2 Why `async: false`

Every test file uses `use Inventory.DataCase, async: false`. Here's why this is necessary and what it means:

**The problem:** `start_supervised!/1` starts a real GenServer in a separate OS process. That process is not the test process. Ecto's SQL sandbox grants DB access to one process at a time. When the GenServer's `init/1` calls `Items.list_pending_reservations()`, it's a different process — the sandbox rejects it.

**The solution:** `async: false` enables Ecto's **shared sandbox mode**. In shared mode, any process can access the test's DB connection. The trade-off is that tests in the same file cannot run in parallel.

```elixir
# This is set automatically by DataCase when async: false:
Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

# Now when the GenServer's init/1 calls the DB:
# - Sandbox sees: unknown PID
# - Shared mode: allows it, uses the test's transaction
# - After the test: transaction is rolled back, DB is clean
```

**Unique process names in tests:** Each test starts its own GenServer with a unique name to avoid conflicts when tests run sequentially in the same module:

```elixir
defp start_queue do
  name = :"BackorderQueue_#{:erlang.unique_integer([:positive])}"
  start_supervised!({BackorderQueue, name: name})
end
```

---

### 8.3 Manual UI Testing Scenarios

Start the server (`mix phx.server`) and open **http://localhost:4000/inventory**.

**Scenario 1 — Create and verify stats**
1. Click **+ New Item**, fill in Name/SKU/Quantity/Price, save.
2. Create a second item with Quantity = `3` (below threshold of 10).
3. Verify: "Low Stock" counter turns yellow, item row is highlighted, alert banner appears.

**Scenario 2 — SKU is immutable**
1. Edit any item — the SKU field is disabled.
2. Try to create a duplicate SKU — form shows "has already been taken".

**Scenario 3 — Overselling protection**
1. Create an item with Quantity = `10`. Reserve 8 units (Available = 2).
2. Try to apply delta = `-5` in the Stock modal → "Insufficient stock" error.

**Scenario 4 — Reservation happy path**
1. Click **Stock** on an item, reserve 5 units.
2. Qty stays the same; Reserved = 5; Available drops by 5.
3. Open Reservations modal → Click **Confirm** → stock permanently deducted.

**Scenario 5 — Reservation expiry**
Temporarily lower the timeout for testing:
```elixir
# lib/inventory_web/live/inventory_live/index.ex
@reserve_timeout_ms 10_000   # 10 seconds
```
Restart, create a reservation, don't touch it. After 10 seconds the page auto-updates with a warning flash and the reservation shows `expired`.

**Scenario 6 — Real-time multi-tab**
1. Open two browser tabs on `/inventory`.
2. Add an item in Tab A — Tab B updates instantly.
3. Let a reservation expire — both tabs show the warning simultaneously.

**Scenario 7 — GenServer crash recovery**
```bash
iex -S mix phx.server
```
```elixir
# Kill the Store — supervisor restarts it within milliseconds
pid = Process.whereis(Inventory.Store)
Process.exit(pid, :kill)

# New pid, timers re-hydrated from DB
Process.whereis(Inventory.Store)
Inventory.Store.dump_timers()
```

**Scenario 8 — CartServer TTL**
```elixir
{:ok, pid} = Inventory.CartServer.get_or_create("test-cart")

# Simulate TTL expiry directly (no need to wait 30 minutes)
send(pid, :ttl_expire)

# Process is gone
Process.alive?(pid)  # => false
Inventory.CartServer.exists?("test-cart")  # => false
```

**Scenario 9 — BackorderQueue from IEx**
```elixir
alias Inventory.{Items, BackorderQueue}

{:ok, item} = Items.create_item(%{name: "Rare Widget", sku: "RW-1", quantity: 0, price: 500})

Phoenix.PubSub.subscribe(Inventory.PubSub, "inventory")

{:ok, ref} = BackorderQueue.enqueue(item.id, 3)
IO.puts("Waiting for ref #{inspect(ref)}...")

Items.update_stock(item, 10)

receive do
  {:backorder_ready, ^ref, item_id, qty} ->
    IO.puts("Ready! #{qty} units of item #{item_id}")
after 2000 ->
  IO.puts("Timed out")
end
```

---

### 8.4 IEx Console Playground

```elixir
iex -S mix phx.server

alias Inventory.{Items, Item, Store, ItemCache, BackorderQueue, CartServer}

# ── ItemCache ────────────────────────────────────────
ItemCache.size()        # number of cached items
ItemCache.all()         # all items from ETS
ItemCache.get(1)        # {:ok, %Item{}} or :miss
ItemCache.reload()      # force reload from DB

# ── BackorderQueue ───────────────────────────────────
{:ok, item} = Items.create_item(%{name: "X", sku: "X-1", quantity: 0, price: 100})
{:ok, ref}  = BackorderQueue.enqueue(item.id, 5)
BackorderQueue.pending()   # show all queued backorders
BackorderQueue.count()     # total entries
Items.update_stock(item, 10)   # triggers PubSub → BackorderQueue → send to self

receive do
  {:backorder_ready, ^ref, id, qty} -> IO.puts("#{qty} units of item #{id} ready!")
after 2000 -> IO.puts("no message")
end

# ── CartServer ───────────────────────────────────────
{:ok, _} = CartServer.get_or_create("my-cart")
CartServer.add_item("my-cart", item.id, 3)
CartServer.get_cart("my-cart")      # %{item_id => 3}
CartServer.remove_item("my-cart", item.id, 1)
CartServer.exists?("my-cart")       # true

# Check how many cart processes are alive
DynamicSupervisor.which_children(Inventory.CartSupervisor)

# ── Supervisor inspection ─────────────────────────────
Supervisor.which_children(Inventory.InventorySupervisor)
# => [{Store, #PID<...>}, {LowStockMonitor, #PID<...>}, ...]

# ── PubSub from IEx ──────────────────────────────────
Phoenix.PubSub.subscribe(Inventory.PubSub, "inventory")
Items.create_item(%{name: "PubSub Test", sku: "PST-1", quantity: 10, price: 100})
flush()
# => {:item_created, %Inventory.Item{...}}
```

---

## 9. PubSub Event Reference

All events are broadcast on the `"inventory"` topic. Subscribe with `Items.subscribe()`.

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

All of these also trigger `ItemCache.handle_info/2` for cache invalidation (for the item-related events), and `BackorderQueue.handle_info/2` for fulfilment checks (for `{:item_updated}`).

---

## 10. Database Schema

```sql
CREATE TABLE items (
  id           SERIAL PRIMARY KEY,
  name         VARCHAR NOT NULL,
  sku          VARCHAR NOT NULL UNIQUE,
  quantity     INTEGER NOT NULL DEFAULT 0,
  reserved_qty INTEGER NOT NULL DEFAULT 0,
  price        INTEGER NOT NULL DEFAULT 0,   -- cents
  inserted_at  TIMESTAMP NOT NULL,
  updated_at   TIMESTAMP NOT NULL
);

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
- Only `pending` reservations can transition — guarded in each context function

---

## 11. Troubleshooting

**"database inventory_dev does not exist"**
```bash
mix ecto.create && mix ecto.migrate
```

**"connection refused" on DB startup**
```bash
brew services start postgresql@16
```

**Reservation timers lost after restart**

This should not happen — `Store.init/1` re-hydrates from the DB. If timers appear lost:
```elixir
Inventory.Items.list_pending_reservations()  # any pending reservations?
Inventory.Store.dump_timers()                # are timers loaded?
```
If `list_pending_reservations` returns rows but `dump_timers` is empty, the Store crashed during `init` — check DB connectivity at startup.

**ItemCache returning stale data**
```elixir
Inventory.ItemCache.reload()   # force full reload from DB
```

**Low stock banner not appearing**
1. Default threshold is 10. Items with `available > 10` won't trigger it.
2. Trigger a manual check: `Inventory.LowStockMonitor.check_now()`
3. Verify the LiveView is connected (PubSub subscriptions only happen when `connected?(socket)` is true).

**CartServer raises `{:noproc, ...}`**

The cart process doesn't exist. Either it expired or was never created. Call `CartServer.get_or_create(cart_id)` before any other cart operation.

**Tests fail with "ownership error" or sandbox issues**

Ensure tests use `async: false`. The GenServer processes started by `start_supervised!` need shared sandbox mode to access the test DB connection.

**"^ operator" CompileError in tests**

You cannot pin a field access:
```elixir
# Wrong:
assert_receive {:item_deleted, ^item.id}

# Correct:
item_id = item.id
assert_receive {:item_deleted, ^item_id}
```

**Flash message `:warning` not styled**

Add a clause in `core_components.ex`:
```elixir
"warning" -> "bg-yellow-50 text-yellow-800 ring-yellow-600/20 fill-yellow-400"
```

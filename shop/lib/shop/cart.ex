defmodule Shop.Cart do
  @moduledoc """
  A GenServer that manages a single user's shopping cart.

  ## Why one process per user?
  Instead of one giant CartServer holding all carts in a map, we spawn one
  lightweight process per user. This gives us:
    - True isolation: a crash in one cart doesn't affect others.
    - Natural concurrency: two users can operate their carts simultaneously.
    - Easy cleanup: the process (and its state) disappears when we terminate it.

  ## How processes are found
  `Shop.Cart.Registry` (a `Registry`) maps `user_id => PID`. When you call
  `Shop.Cart.add_item("alice", ...)`, this module looks up Alice's PID in the
  Registry and sends a message to that specific process.

  ## State shape
  %{ product_id => %{name: String.t(), price: float(), quantity: pos_integer()} }
  """

  use GenServer

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a cart for `user_id`.
  Called by DynamicSupervisor – do not call directly; use `ensure_started/1`.
  """
  def start_link(user_id) do
    # Register under {Registry, user_id} so we can look the PID up later.
    GenServer.start_link(__MODULE__, user_id,
      name: via_registry(user_id)
    )
  end

  @doc """
  Ensure a cart process exists for `user_id`, starting one if needed.
  Idempotent – safe to call multiple times.
  """
  def ensure_started(user_id) do
    case DynamicSupervisor.start_child(
           Shop.CartSupervisor,
           {__MODULE__, user_id}
         ) do
      {:ok, pid}                       -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error                            -> error
    end
  end

  @doc "Add `quantity` units of a product to the cart."
  def add_item(user_id, product_id, name, price, quantity \\ 1) do
    ensure_started(user_id)
    GenServer.call(via_registry(user_id), {:add_item, product_id, name, price, quantity})
  end

  @doc "Remove a product from the cart entirely."
  def remove_item(user_id, product_id) do
    GenServer.call(via_registry(user_id), {:remove_item, product_id})
  end

  @doc "Update the quantity of a product already in the cart."
  def update_quantity(user_id, product_id, new_quantity) do
    GenServer.call(via_registry(user_id), {:update_quantity, product_id, new_quantity})
  end

  @doc "Return all items in the cart."
  def view(user_id) do
    ensure_started(user_id)
    GenServer.call(via_registry(user_id), :view)
  end

  @doc "Return the total price across all cart items."
  def total(user_id) do
    ensure_started(user_id)
    GenServer.call(via_registry(user_id), :total)
  end

  @doc """
  Checkout: reserves stock in Inventory for every item, then clears the cart.
  Returns {:ok, order_summary} or {:error, reason}.
  """
  def checkout(user_id) do
    GenServer.call(via_registry(user_id), :checkout)
  end

  @doc "Empty the cart without checking out."
  def clear(user_id) do
    GenServer.cast(via_registry(user_id), :clear)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(user_id) do
    Logger.info("Cart started for user: #{user_id}")
    # State is a tuple so we can track user_id alongside the items map.
    {:ok, {user_id, %{}}}
  end

  # --- add_item ---
  @impl true
  def handle_call({:add_item, product_id, name, price, quantity}, _from, {user_id, items}) do
    updated_items =
      Map.update(
        items,
        product_id,
        # Default if product isn't in cart yet:
        %{name: name, price: price, quantity: quantity},
        # Merge function if it already exists – just bump quantity:
        fn existing -> Map.update!(existing, :quantity, &(&1 + quantity)) end
      )

    {:reply, {:ok, updated_items[product_id]}, {user_id, updated_items}}
  end

  # --- remove_item ---
  @impl true
  def handle_call({:remove_item, product_id}, _from, {user_id, items}) do
    if Map.has_key?(items, product_id) do
      {:reply, :ok, {user_id, Map.delete(items, product_id)}}
    else
      {:reply, {:error, :not_in_cart}, {user_id, items}}
    end
  end

  # --- update_quantity ---
  @impl true
  def handle_call({:update_quantity, product_id, new_quantity}, _from, {user_id, items})
      when new_quantity <= 0 do
    # Treat zero/negative quantity as a removal.
    {:reply, :ok, {user_id, Map.delete(items, product_id)}}
  end

  def handle_call({:update_quantity, product_id, new_quantity}, _from, {user_id, items}) do
    case Map.fetch(items, product_id) do
      :error ->
        {:reply, {:error, :not_in_cart}, {user_id, items}}

      {:ok, item} ->
        updated = Map.put(item, :quantity, new_quantity)
        {:reply, {:ok, updated}, {user_id, Map.put(items, product_id, updated)}}
    end
  end

  # --- view ---
  @impl true
  def handle_call(:view, _from, {_user_id, items} = state) do
    {:reply, items, state}
  end

  # --- total ---
  @impl true
  def handle_call(:total, _from, {_user_id, items} = state) do
    total =
      Enum.reduce(items, 0.0, fn {_id, %{price: price, quantity: qty}}, acc ->
        acc + price * qty
      end)

    {:reply, Float.round(total, 2), state}
  end

  # --- checkout ---
  @impl true
  def handle_call(:checkout, _from, {user_id, items}) do
    # Try to reserve stock for every item in the cart.
    # We do this in a single pass; if any item fails we abort entirely.
    result =
      Enum.reduce_while(items, {:ok, []}, fn {product_id, %{quantity: qty} = item}, {:ok, acc} ->
        case Shop.Inventory.reserve(product_id, qty) do
          {:ok, _updated_product} ->
            {:cont, {:ok, [{product_id, item} | acc]}}

          {:error, reason} ->
            {:halt, {:error, {product_id, reason}}}
        end
      end)

    case result do
      {:ok, reserved_items} ->
        order = %{
          user_id:    user_id,
          items:      reserved_items,
          total:      calc_total(items),
          checked_out_at: DateTime.utc_now()
        }
        Logger.info("Checkout successful for user #{user_id}, total: #{order.total}")
        # Clear cart on success.
        {:reply, {:ok, order}, {user_id, %{}}}

      {:error, _reason} = err ->
        # Leave cart intact so the user can fix the issue.
        {:reply, err, {user_id, items}}
    end
  end

  # --- clear (cast) ---
  @impl true
  def handle_cast(:clear, {user_id, _items}) do
    Logger.info("Cart cleared for user: #{user_id}")
    {:noreply, {user_id, %{}}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # `via_registry/1` returns a tuple that OTP understands as a registered name.
  # GenServer automatically routes calls/casts to the PID stored in the Registry.
  defp via_registry(user_id) do
    {:via, Registry, {Shop.Cart.Registry, user_id}}
  end

  defp calc_total(items) do
    items
    |> Enum.reduce(0.0, fn {_id, %{price: price, quantity: qty}}, acc ->
      acc + price * qty
    end)
    |> Float.round(2)
  end
end

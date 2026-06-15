defmodule Shop.Inventory do
  @moduledoc """
  A GenServer that acts as the single source of truth for all products and
  their stock levels. Because GenServer serialises all messages into a single
  mailbox, we get concurrent-safe reads and writes for free – no explicit
  locking needed.

  ## State shape
  The internal state is a plain map:
    %{ product_id => %{name: String.t(), price: float(), stock: non_neg_integer()} }

  ## Key GenServer callbacks used here
  - init/1        – seeds the server with an optional list of products
  - handle_call/3 – synchronous requests (the caller waits for a reply)
  - handle_cast/2 – asynchronous requests (fire-and-forget, no reply)
  """

  use GenServer

  require Logger

  # ---------------------------------------------------------------------------
  # Public API  (the "client" side – these run in the caller's process)
  # ---------------------------------------------------------------------------

  @doc "Start the Inventory server, optionally pre-loading a list of products."
  def start_link(initial_products \\ []) do
    # The second argument becomes the `args` passed to `init/1`.
    GenServer.start_link(__MODULE__, initial_products, name: __MODULE__)
    # `name: __MODULE__` registers the process under the module name so callers
    # can reference it as `Shop.Inventory` instead of using a PID directly.
  end

  @doc "Add a brand-new product to the catalogue."
  def add_product(id, name, price, stock \\ 0) do
    # `call` is synchronous: the caller blocks until the server replies.
    # Use it when the caller needs confirmation or a return value.
    GenServer.call(__MODULE__, {:add_product, id, name, price, stock})
  end

  @doc "Return a product map, or {:error, :not_found}."
  def get_product(id) do
    GenServer.call(__MODULE__, {:get_product, id})
  end

  @doc "Return all products as a list of {id, product} tuples."
  def list_products do
    GenServer.call(__MODULE__, :list_products)
  end

  @doc "Restock a product by `quantity` units (fire-and-forget)."
  def restock(id, quantity) do
    # `cast` is asynchronous: returns `:ok` immediately.
    # Use it when the caller doesn't need to wait for the result.
    GenServer.cast(__MODULE__, {:restock, id, quantity})
  end

  @doc """
  Reserve `quantity` units of a product.
  Returns {:ok, updated_product} or {:error, reason}.
  Used by the Cart during checkout.
  """
  def reserve(id, quantity) do
    GenServer.call(__MODULE__, {:reserve, id, quantity})
  end

  @doc "Remove a product entirely from the catalogue."
  def remove_product(id) do
    GenServer.call(__MODULE__, {:remove_product, id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks  (run inside the Inventory server process)
  # ---------------------------------------------------------------------------

  @impl true
  def init(initial_products) do
    # Build the initial state map from the provided list.
    # Each element: {id, name, price, stock}
    state =
      Enum.reduce(initial_products, %{}, fn {id, name, price, stock}, acc ->
        Map.put(acc, id, %{name: name, price: price, stock: stock})
      end)

    Logger.info("Inventory started with #{map_size(state)} product(s)")

    # `{:ok, state}` tells OTP the server started successfully.
    {:ok, state}
  end

  # --- handle_call: add_product ---
  @impl true
  def handle_call({:add_product, id, name, price, stock}, _from, state) do
    if Map.has_key?(state, id) do
      # Reply with an error; state is unchanged.
      {:reply, {:error, :already_exists}, state}
    else
      product = %{name: name, price: price, stock: stock}
      new_state = Map.put(state, id, product)
      {:reply, {:ok, product}, new_state}
      # Pattern: {:reply, reply_value, new_state}
    end
  end

  # --- handle_call: get_product ---
  @impl true
  def handle_call({:get_product, id}, _from, state) do
    result = Map.fetch(state, id)  # returns {:ok, val} or :error
    reply =
      case result do
        {:ok, product} -> {:ok, product}
        :error         -> {:error, :not_found}
      end
    {:reply, reply, state}
  end

  # --- handle_call: list_products ---
  @impl true
  def handle_call(:list_products, _from, state) do
    {:reply, Map.to_list(state), state}
  end

  # --- handle_call: reserve ---
  @impl true
  def handle_call({:reserve, id, quantity}, _from, state) do
    case Map.fetch(state, id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %{stock: stock} = product} when stock < quantity ->
        {:reply, {:error, {:insufficient_stock, stock}}, state}

      {:ok, product} ->
        updated = Map.update!(product, :stock, &(&1 - quantity))
        new_state = Map.put(state, id, updated)
        {:reply, {:ok, updated}, new_state}
    end
  end

  # --- handle_call: remove_product ---
  @impl true
  def handle_call({:remove_product, id}, _from, state) do
    if Map.has_key?(state, id) do
      {:reply, :ok, Map.delete(state, id)}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  # --- handle_cast: restock ---
  @impl true
  def handle_cast({:restock, id, quantity}, state) do
    new_state =
      Map.update(state, id, %{}, fn product ->
        Map.update!(product, :stock, &(&1 + quantity))
      end)

    Logger.info("Restocked product #{id} by #{quantity}")

    # Cast handlers return {:noreply, new_state} – no reply is sent.
    {:noreply, new_state}
  end
end

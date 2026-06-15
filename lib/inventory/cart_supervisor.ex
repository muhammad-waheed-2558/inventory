defmodule Inventory.CartSupervisor do
  @moduledoc """
  DynamicSupervisor that manages the pool of CartServer processes.

  ## DynamicSupervisor vs Supervisor

  | | `Supervisor` | `DynamicSupervisor` |
  |---|---|---|
  | Children known at compile time? | Yes | No |
  | Start children at runtime? | Awkward | Yes — `start_child/2` |
  | Use case | Fixed set of workers | One worker per user/session/entity |

  We use `DynamicSupervisor` because we don't know how many carts will exist
  — one is created per shopping session on demand.

  ## Usage

      # Start a cart (or get the existing one):
      {:ok, pid} = Inventory.CartSupervisor.start_cart("cart-abc-123")

      # List running carts:
      DynamicSupervisor.which_children(Inventory.CartSupervisor)
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    # :one_for_one is the only strategy DynamicSupervisor supports
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new CartServer for `cart_id` under this supervisor."
  def start_cart(cart_id) do
    DynamicSupervisor.start_child(__MODULE__, {Inventory.CartServer, cart_id})
  end
end

defmodule Shop.Application do
  @moduledoc """
  The OTP Application entry point.

  When `mix run` or `iex -S mix` starts, BEAM calls `start/2` here, which
  spins up the supervision tree declared in `children`.

  ## Supervision tree

      Shop.Application (Supervisor, strategy: :one_for_one)
      ├── Shop.Cart.Registry       (Registry – maps user_id => cart PID)
      ├── Shop.CartSupervisor      (DynamicSupervisor – spawns/kills Cart processes)
      └── Shop.Inventory           (GenServer – manages product catalogue & stock)

  ### Why :one_for_one?
  Each child is independent. If Inventory crashes, the cart processes should keep
  running (they'll just get errors on checkout until Inventory restarts). OTP
  will automatically restart the crashed child.

  ### Why DynamicSupervisor for carts?
  We don't know at compile time how many users (carts) we'll have. A
  DynamicSupervisor lets us add and remove children at runtime.

  ### Why a Registry?
  A Registry gives us a named lookup: "give me the PID for user_id = 'alice'".
  Without it, we'd have to pass PIDs around or store them ourselves.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Seed some initial products so the demo works out of the box.
    initial_products = [
      {:apple,  "Apple",  0.99, 100},
      {:banana, "Banana", 0.49,  80},
      {:mango,  "Mango",  1.49,  50},
      {:grape,  "Grape",  2.99,  30}
    ]

    children = [
      # 1. Registry – must start before anything that uses it (Cart processes).
      #    `keys: :unique` means each user_id maps to exactly one PID.
      {Registry, keys: :unique, name: Shop.Cart.Registry},

      # 2. DynamicSupervisor – manages Cart processes.
      #    `strategy: :one_for_one` is the only strategy DynamicSupervisor supports.
      {DynamicSupervisor, strategy: :one_for_one, name: Shop.CartSupervisor},

      # 3. Inventory GenServer – starts with the seed products.
      {Shop.Inventory, initial_products}
    ]

    # :one_for_one – if one child crashes, only that child is restarted.
    # Other strategies: :one_for_all, :rest_for_one (see OTP docs).
    opts = [strategy: :one_for_one, name: Shop.Supervisor]

    Supervisor.start_link(children, opts)
  end
end

defmodule Inventory.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InventoryWeb.Telemetry,
      Inventory.Repo,
      {DNSCluster, query: Application.get_env(:inventory, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Inventory.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Inventory.Finch},
      # Registry for cart processes — must start before CartSupervisor
      {Registry, keys: :unique, name: Inventory.CartRegistry},
      # DynamicSupervisor for per-cart GenServers
      Inventory.CartSupervisor,
      # Inventory GenServer tree (Store + LowStockMonitor + ItemCache + BackorderQueue)
      Inventory.InventorySupervisor,
      # Start to serve requests, typically the last entry
      InventoryWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Inventory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InventoryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

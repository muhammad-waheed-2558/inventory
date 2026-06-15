defmodule InventoryWeb.Router do
  use InventoryWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {InventoryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", InventoryWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/inventory", InventoryLive.Index, :index
    live "/inventory/new", InventoryLive.Index, :new
    live "/inventory/:id/edit", InventoryLive.Index, :edit
    live "/inventory/:id/stock", InventoryLive.Index, :stock
    live "/inventory/:id/reservations", InventoryLive.Index, :reservations
  end

  # Other scopes may use custom stacks.
  # scope "/api", InventoryWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:inventory, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: InventoryWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

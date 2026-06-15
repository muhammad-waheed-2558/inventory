defmodule InventoryWeb.InventoryLive.Index do
  @moduledoc """
  Main inventory LiveView.

  Demonstrates:
  - `mount/3`         — subscribe to PubSub, load initial data
  - `handle_params/3` — respond to URL changes (live_action drives modals)
  - `handle_event/3`  — user interactions (delete, stock update, reserve, confirm, cancel)
  - `handle_info/3`   — PubSub messages trigger real-time UI updates
  """

  use InventoryWeb, :live_view

  alias Inventory.{Item, Items}
  alias Inventory.Store
  alias InventoryWeb.InventoryLive.ItemFormComponent

  @reserve_timeout_ms 60_000

  # ─────────────────────────────────────────────────────────────
  # Lifecycle
  # ─────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to PubSub — handle_info will receive inventory events
    if connected?(socket), do: Items.subscribe()

    {:ok,
     socket
     |> assign(:items, Items.list_items())
     |> assign(:stats, Items.stats())
     |> assign(:low_stock_items, Items.list_low_stock())
     |> assign(:selected_item, nil)
     |> assign(:reservations, [])
     |> assign(:stock_delta, 0)
     |> assign(:reserve_qty, 1)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Inventory")
    |> assign(:item, nil)
    |> assign(:selected_item, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Item")
    |> assign(:item, %Item{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    item = Items.get_item!(id)

    socket
    |> assign(:page_title, "Edit Item")
    |> assign(:item, item)
  end

  defp apply_action(socket, :stock, %{"id" => id}) do
    item = Items.get_item!(id)

    socket
    |> assign(:page_title, "Manage Stock")
    |> assign(:selected_item, item)
    |> assign(:stock_delta, 0)
    |> assign(:reserve_qty, 1)
  end

  defp apply_action(socket, :reservations, %{"id" => id}) do
    item = Items.get_item!(id)
    reservations = Items.list_reservations_for_item(id)

    socket
    |> assign(:page_title, "Reservations")
    |> assign(:selected_item, item)
    |> assign(:reservations, reservations)
  end

  # ─────────────────────────────────────────────────────────────
  # PubSub event handlers  (handle_info)
  # ─────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:item_created, _item}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:item_updated, _item}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:item_deleted, _id}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:reservation_created, _res}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:reservation_confirmed, _res}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:reservation_cancelled, _res}, socket) do
    {:noreply, reload(socket)}
  end

  def handle_info({:reservation_expired, _res}, socket) do
    {:noreply,
     socket
     |> reload()
     |> put_flash(:warning, "A reservation expired and stock was released.")}
  end

  def handle_info({:low_stock, items}, socket) do
    {:noreply, assign(socket, :low_stock_items, items)}
  end

  # ─────────────────────────────────────────────────────────────
  # User event handlers  (handle_event)
  # ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    item = Items.get_item!(id)

    case Items.delete_item(item) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Item deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete item.")}
    end
  end

  def handle_event("update_stock", %{"delta" => delta_str}, socket) do
    item = socket.assigns.selected_item
    delta = String.to_integer(delta_str)

    case Items.update_stock(item, delta) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Stock updated.")}

      {:error, :insufficient_stock} ->
        {:noreply, put_flash(socket, :error, "Insufficient stock for that adjustment.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  def handle_event("reserve", %{"qty" => qty_str}, socket) do
    item = socket.assigns.selected_item
    qty = String.to_integer(qty_str)

    case Items.create_reservation(item.id, qty, @reserve_timeout_ms) do
      {:ok, reservation} ->
        # Tell the Store GenServer to track the expiry timer
        Store.track_reservation(reservation.id, @reserve_timeout_ms)

        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Reserved #{qty} unit(s). Expires in 60 seconds.")}

      {:error, :insufficient_stock} ->
        {:noreply, put_flash(socket, :error, "Not enough available stock to reserve.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{inspect(reason)}")}
    end
  end

  def handle_event("confirm_reservation", %{"id" => res_id}, socket) do
    res_id = String.to_integer(res_id)

    case Items.confirm_reservation(res_id) do
      {:ok, _} ->
        # Cancel the expiry timer — no longer needed
        Store.cancel_timer(res_id)

        {:noreply,
         socket
         |> reload_reservations()
         |> reload()
         |> put_flash(:info, "Reservation confirmed. Stock permanently deducted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not confirm: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel_reservation", %{"id" => res_id}, socket) do
    res_id = String.to_integer(res_id)

    case Items.cancel_reservation(res_id) do
      {:ok, _} ->
        Store.cancel_timer(res_id)

        {:noreply,
         socket
         |> reload_reservations()
         |> reload()
         |> put_flash(:info, "Reservation cancelled. Stock released.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_low_stock", _params, socket) do
    {:noreply, assign(socket, :low_stock_items, [])}
  end

  # ─────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 py-6">
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-gray-900">Inventory Management</h1>
        <.link patch={~p"/inventory/new"}>
          <.button>+ New Item</.button>
        </.link>
      </div>

      <%!-- Stats Dashboard --%>
      <div class="grid grid-cols-2 gap-4 sm:grid-cols-4 mb-6">
        <div class="bg-white rounded-lg shadow p-4 text-center">
          <p class="text-sm text-gray-500">Total Items</p>
          <p class="text-3xl font-bold text-gray-900">{@stats.total_items}</p>
        </div>
        <div class="bg-white rounded-lg shadow p-4 text-center">
          <p class="text-sm text-gray-500">Total Units</p>
          <p class="text-3xl font-bold text-blue-600">{@stats.total_stock}</p>
        </div>
        <div class={[
          "rounded-lg shadow p-4 text-center",
          if(@stats.low_stock_count > 0, do: "bg-yellow-50", else: "bg-white")
        ]}>
          <p class="text-sm text-gray-500">Low Stock</p>
          <p class={[
            "text-3xl font-bold",
            if(@stats.low_stock_count > 0, do: "text-yellow-600", else: "text-gray-900")
          ]}>
            {@stats.low_stock_count}
          </p>
        </div>
        <div class="bg-white rounded-lg shadow p-4 text-center">
          <p class="text-sm text-gray-500">Active Reservations</p>
          <p class="text-3xl font-bold text-purple-600">{@stats.active_reservations}</p>
        </div>
      </div>

      <%!-- Low Stock Alert Banner --%>
      <%= if @low_stock_items != [] do %>
        <div class="mb-4 rounded-md bg-yellow-50 border border-yellow-300 p-4 flex items-start justify-between">
          <div>
            <p class="font-semibold text-yellow-800">⚠ Low Stock Alert</p>
            <p class="text-sm text-yellow-700 mt-1">
              {Enum.map_join(@low_stock_items, ", ", fn i ->
                "#{i.name} (#{Item.available(i)} left)"
              end)}
            </p>
          </div>
          <button
            phx-click="dismiss_low_stock"
            class="ml-4 text-yellow-600 hover:text-yellow-900 text-lg font-bold"
          >×</button>
        </div>
      <% end %>

      <%!-- Items Table --%>
      <div class="bg-white shadow rounded-lg overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">ID</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Name</th>
              <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">SKU</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Qty</th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                Reserved
              </th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                Available
              </th>
              <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Price</th>
              <th class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase">
                Actions
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <%= if @items == [] do %>
              <tr>
                <td colspan="8" class="px-4 py-8 text-center text-gray-400 text-sm">
                  No items yet. Click <strong>+ New Item</strong> to add one.
                </td>
              </tr>
            <% end %>
            <%= for item <- @items do %>
              <tr class={if(Item.available(item) <= Items.low_stock_threshold(), do: "bg-yellow-50")}>
                <td class="px-4 py-3 text-sm text-gray-500">{item.id}</td>
                <td class="px-4 py-3 text-sm font-medium text-gray-900">{item.name}</td>
                <td class="px-4 py-3 text-sm text-gray-500 font-mono">{item.sku}</td>
                <td class="px-4 py-3 text-sm text-right text-gray-700">{item.quantity}</td>
                <td class="px-4 py-3 text-sm text-right text-purple-600">{item.reserved_qty}</td>
                <td class={[
                  "px-4 py-3 text-sm text-right font-semibold",
                  if(Item.available(item) <= Items.low_stock_threshold(),
                    do: "text-yellow-600",
                    else: "text-green-600"
                  )
                ]}>
                  {Item.available(item)}
                </td>
                <td class="px-4 py-3 text-sm text-right text-gray-700">
                  ${:erlang.float_to_binary(item.price / 100, decimals: 2)}
                </td>
                <td class="px-4 py-3 text-sm text-center">
                  <div class="flex items-center justify-center gap-2 flex-wrap">
                    <.link
                      patch={~p"/inventory/#{item.id}/stock"}
                      class="text-blue-600 hover:text-blue-900 text-xs font-medium"
                    >
                      Stock
                    </.link>
                    <.link
                      patch={~p"/inventory/#{item.id}/reservations"}
                      class="text-purple-600 hover:text-purple-900 text-xs font-medium"
                    >
                      Reservations
                    </.link>
                    <.link
                      patch={~p"/inventory/#{item.id}/edit"}
                      class="text-gray-600 hover:text-gray-900 text-xs font-medium"
                    >
                      Edit
                    </.link>
                    <button
                      phx-click="delete"
                      phx-value-id={item.id}
                      data-confirm={"Delete #{item.name}?"}
                      class="text-red-600 hover:text-red-900 text-xs font-medium"
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Add / Edit Item Modal --%>
      <%= if @live_action in [:new, :edit] do %>
        <.modal id="item-modal" show on_cancel={JS.patch(~p"/inventory")}>
          <.live_component
            module={ItemFormComponent}
            id={@item.id || :new}
            title={@page_title}
            action={@live_action}
            item={@item}
            patch={~p"/inventory"}
          />
        </.modal>
      <% end %>

      <%!-- Stock Management Modal --%>
      <%= if @live_action == :stock && @selected_item do %>
        <.modal id="stock-modal" show on_cancel={JS.patch(~p"/inventory")}>
          <.header>
            Stock Management — {@selected_item.name}
            <:subtitle>
              SKU: <span class="font-mono">{@selected_item.sku}</span> |
              Available: <strong>{Item.available(@selected_item)}</strong>
            </:subtitle>
          </.header>

          <div class="mt-6 space-y-6">
            <%!-- Update Stock --%>
            <div class="border rounded-lg p-4">
              <h3 class="font-semibold text-gray-800 mb-3">Update Stock</h3>
              <form phx-submit="update_stock" class="flex items-end gap-3">
                <div class="flex-1">
                  <label class="block text-sm font-medium text-gray-700 mb-1">
                    Delta (positive = restock, negative = sell)
                  </label>
                  <input
                    type="number"
                    name="delta"
                    value="0"
                    class="w-full rounded border-gray-300 shadow-sm focus:ring-blue-500"
                  />
                </div>
                <.button type="submit">Apply</.button>
              </form>
            </div>

            <%!-- Reserve Stock --%>
            <div class="border rounded-lg p-4">
              <h3 class="font-semibold text-gray-800 mb-1">Reserve Stock</h3>
              <p class="text-xs text-gray-500 mb-3">
                Reservation holds stock for 60 seconds. Confirm it before it expires.
              </p>
              <form phx-submit="reserve" class="flex items-end gap-3">
                <div class="flex-1">
                  <label class="block text-sm font-medium text-gray-700 mb-1">Quantity</label>
                  <input
                    type="number"
                    name="qty"
                    value="1"
                    min="1"
                    class="w-full rounded border-gray-300 shadow-sm focus:ring-blue-500"
                  />
                </div>
                <.button type="submit">Reserve</.button>
              </form>
            </div>
          </div>
        </.modal>
      <% end %>

      <%!-- Reservations Modal --%>
      <%= if @live_action == :reservations && @selected_item do %>
        <.modal id="reservations-modal" show on_cancel={JS.patch(~p"/inventory")}>
          <.header>
            Reservations — {@selected_item.name}
          </.header>

          <div class="mt-4">
            <%= if @reservations == [] do %>
              <p class="text-sm text-gray-400 text-center py-6">No reservations for this item.</p>
            <% else %>
              <table class="min-w-full text-sm divide-y divide-gray-200">
                <thead>
                  <tr>
                    <th class="text-left py-2 px-2 text-xs text-gray-500">ID</th>
                    <th class="text-right py-2 px-2 text-xs text-gray-500">Qty</th>
                    <th class="text-left py-2 px-2 text-xs text-gray-500">Status</th>
                    <th class="text-left py-2 px-2 text-xs text-gray-500">Expires At</th>
                    <th class="text-center py-2 px-2 text-xs text-gray-500">Actions</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <%= for res <- @reservations do %>
                    <tr>
                      <td class="py-2 px-2 text-gray-500">{res.id}</td>
                      <td class="py-2 px-2 text-right font-medium">{res.quantity}</td>
                      <td class="py-2 px-2">
                        <span class={[
                          "px-2 py-0.5 rounded-full text-xs font-medium",
                          status_class(res.status)
                        ]}>
                          {res.status}
                        </span>
                      </td>
                      <td class="py-2 px-2 text-gray-500 text-xs">
                        {Calendar.strftime(res.expires_at, "%H:%M:%S")}
                      </td>
                      <td class="py-2 px-2 text-center">
                        <%= if res.status == "pending" do %>
                          <button
                            phx-click="confirm_reservation"
                            phx-value-id={res.id}
                            class="text-green-600 hover:text-green-800 text-xs mr-2 font-medium"
                          >Confirm</button>
                          <button
                            phx-click="cancel_reservation"
                            phx-value-id={res.id}
                            class="text-red-500 hover:text-red-700 text-xs font-medium"
                          >Cancel</button>
                        <% else %>
                          <span class="text-gray-400 text-xs">—</span>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </.modal>
      <% end %>
    </div>
    """
  end

  # ─────────────────────────────────────────────────────────────
  # Private helpers
  # ─────────────────────────────────────────────────────────────

  defp reload(socket) do
    socket
    |> assign(:items, Items.list_items())
    |> assign(:stats, Items.stats())
    |> assign(:low_stock_items, Items.list_low_stock())
  end

  defp reload_reservations(socket) do
    item = socket.assigns.selected_item

    if item do
      assign(socket, :reservations, Items.list_reservations_for_item(item.id))
    else
      socket
    end
  end

  defp status_class("pending"), do: "bg-yellow-100 text-yellow-800"
  defp status_class("confirmed"), do: "bg-green-100 text-green-800"
  defp status_class("cancelled"), do: "bg-gray-100 text-gray-600"
  defp status_class("expired"), do: "bg-red-100 text-red-700"
  defp status_class(_), do: "bg-gray-100 text-gray-600"
end

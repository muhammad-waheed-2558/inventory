defmodule InventoryWeb.InventoryLive.ItemFormComponent do
  @moduledoc "LiveComponent for creating and editing inventory items."

  use InventoryWeb, :live_component

  alias Inventory.Items

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
      </.header>

      <.simple_form for={@form} id="item-form" phx-target={@myself} phx-submit="save">
        <.input field={@form[:name]} label="Product Name" placeholder="e.g. Widget Pro" />
        <.input
          field={@form[:sku]}
          label="SKU"
          placeholder="e.g. WGT-001"
          disabled={@action == :edit}
        />
        <.input
          field={@form[:quantity]}
          type="number"
          label="Quantity"
          min="0"
        />
        <.input
          field={@form[:price]}
          type="number"
          label="Price (cents)"
          min="0"
          placeholder="e.g. 999 = $9.99"
        />

        <:actions>
          <.button phx-disable-with="Saving…">Save Item</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{item: item} = assigns, socket) do
    changeset =
      if assigns.action == :new do
        Items.change_item(item)
      else
        Inventory.Item.update_changeset(item, %{})
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("save", %{"item" => item_params}, socket) do
    save_item(socket, socket.assigns.action, item_params)
  end

  defp save_item(socket, :new, item_params) do
    case Items.create_item(item_params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Item created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_item(socket, :edit, item_params) do
    case Items.update_item(socket.assigns.item, item_params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "Item updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end
end

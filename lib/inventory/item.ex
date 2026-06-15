defmodule Inventory.Item do
  @moduledoc "Ecto schema for the `items` table."

  use Ecto.Schema
  import Ecto.Changeset

  schema "items" do
    field :name, :string
    field :sku, :string
    field :quantity, :integer, default: 0
    field :reserved_qty, :integer, default: 0
    field :price, :integer, default: 0

    has_many :reservations, Inventory.Reservation

    timestamps(type: :utc_datetime)
  end

  @doc "Available (unreserved) stock."
  def available(%__MODULE__{quantity: q, reserved_qty: r}), do: q - r

  @doc "Changeset for creating a new item."
  def changeset(item, attrs) do
    item
    |> cast(attrs, [:name, :sku, :quantity, :price])
    |> validate_required([:name, :sku, :quantity, :price])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:sku, min: 1, max: 50)
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> unique_constraint(:sku)
  end

  @doc "Changeset for updating only editable fields (sku is immutable after creation)."
  def update_changeset(item, attrs) do
    item
    |> cast(attrs, [:name, :quantity, :price])
    |> validate_required([:name, :quantity, :price])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:quantity, greater_than_or_equal_to: 0)
    |> validate_number(:price, greater_than_or_equal_to: 0)
  end
end

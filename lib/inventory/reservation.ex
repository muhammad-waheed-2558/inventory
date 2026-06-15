defmodule Inventory.Reservation do
  @moduledoc "Ecto schema for the `reservations` table."

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending confirmed cancelled expired)

  schema "reservations" do
    field :quantity, :integer
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime

    belongs_to :item, Inventory.Item

    timestamps(type: :utc_datetime)
  end

  def changeset(reservation, attrs) do
    reservation
    |> cast(attrs, [:item_id, :quantity, :status, :expires_at])
    |> validate_required([:item_id, :quantity, :expires_at])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:item_id)
  end

  def statuses, do: @statuses
end

defmodule Inventory.Repo.Migrations.CreateReservations do
  use Ecto.Migration

  def change do
    create table(:reservations) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :quantity, :integer, null: false
      # pending | confirmed | cancelled | expired
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:reservations, [:item_id])
    create index(:reservations, [:status])
  end
end

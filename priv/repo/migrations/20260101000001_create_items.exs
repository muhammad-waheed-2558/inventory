defmodule Inventory.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table(:items) do
      add :name, :string, null: false
      add :sku, :string, null: false
      add :quantity, :integer, null: false, default: 0
      add :reserved_qty, :integer, null: false, default: 0
      add :price, :integer, null: false, default: 0, comment: "price in cents"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:sku])
    create index(:items, [:quantity])
  end
end

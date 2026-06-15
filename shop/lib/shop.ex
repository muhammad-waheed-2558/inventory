defmodule Shop do
  @moduledoc """
  Convenience facade so you can type `Shop.xxx` in IEx instead of the full
  module names. All functions delegate to Shop.Inventory or Shop.Cart.
  """

  # --- Inventory shortcuts ---
  defdelegate add_product(id, name, price, stock \\ 0), to: Shop.Inventory
  defdelegate get_product(id),                          to: Shop.Inventory
  defdelegate list_products(),                          to: Shop.Inventory
  defdelegate restock(id, quantity),                    to: Shop.Inventory
  defdelegate remove_product(id),                       to: Shop.Inventory

  # --- Cart shortcuts ---
  defdelegate add_to_cart(user, product_id, name, price, qty \\ 1), to: Shop.Cart, as: :add_item
  defdelegate remove_from_cart(user, product_id),                    to: Shop.Cart, as: :remove_item
  defdelegate view_cart(user),                                        to: Shop.Cart, as: :view
  defdelegate cart_total(user),                                       to: Shop.Cart, as: :total
  defdelegate checkout(user),                                         to: Shop.Cart
  defdelegate clear_cart(user),                                       to: Shop.Cart, as: :clear
end

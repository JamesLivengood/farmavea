class AddPackQuantityToRawListings < ActiveRecord::Migration[8.1]
  def change
    add_column :raw_listings, :pack_quantity, :integer
  end
end

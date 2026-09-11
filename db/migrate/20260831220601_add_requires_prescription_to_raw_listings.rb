class AddRequiresPrescriptionToRawListings < ActiveRecord::Migration[8.1]
  def change
    add_column :raw_listings, :requires_prescription, :boolean
  end
end

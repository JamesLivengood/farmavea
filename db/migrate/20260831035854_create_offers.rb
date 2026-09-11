class CreateOffers < ActiveRecord::Migration[8.1]
  def change
    create_table :offers do |t|
      t.references :medication, null: false, foreign_key: true
      t.references :pharmacy, null: false, foreign_key: true
      t.references :raw_listing, null: false, foreign_key: true
      t.string :city, null: false
      t.integer :price_cents, null: false
      t.decimal :price_per_mg
      t.datetime :scraped_at, null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end
    add_index :offers, [ :city, :medication_id, :active, :price_per_mg ], name: "index_offers_on_city_medication_active_price"
  end
end

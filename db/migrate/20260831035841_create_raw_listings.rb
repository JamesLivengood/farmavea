class CreateRawListings < ActiveRecord::Migration[8.1]
  def change
    create_table :raw_listings do |t|
      t.references :crawl_run, null: false, foreign_key: true
      t.references :pharmacy, null: false, foreign_key: true
      t.string :raw_name, null: false
      t.string :presentation_text
      t.integer :price_cents, null: false
      t.string :product_url
      t.datetime :scraped_at, null: false

      t.timestamps
    end
    add_index :raw_listings, [ :pharmacy_id, :raw_name ]
  end
end

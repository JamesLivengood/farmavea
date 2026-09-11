class CreateUnresolvedListings < ActiveRecord::Migration[8.1]
  def change
    create_table :unresolved_listings do |t|
      t.references :pharmacy, null: false, foreign_key: true
      t.string :raw_name, null: false
      t.text :reason
      t.decimal :confidence

      t.timestamps
    end
    # Uniqueness prevents re-recording (and re-asking Claude about) the same
    # unresolved name on every future crawl - it's genuinely ambiguous, not stale.
    add_index :unresolved_listings, [ :pharmacy_id, :raw_name ], unique: true, name: "index_unresolved_listings_on_pharmacy_and_raw_name"
  end
end

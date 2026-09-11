class AddUniqueIndexToOffersRawListingId < ActiveRecord::Migration[8.1]
  def up
    # Repeated aggregation runs against the same crawl_run (e.g. while debugging an
    # unrelated API-credit issue) created duplicate Offer rows for the same
    # raw_listing_id, since Offer#create! had no uniqueness guard - RawListing
    # already declares has_one :offer, so this was always meant to be 1:1. Keep the
    # most recently created row per raw_listing_id and drop the rest before the
    # unique index can be added.
    execute <<~SQL
      DELETE FROM offers
      WHERE id NOT IN (
        SELECT DISTINCT ON (raw_listing_id) id
        FROM offers
        ORDER BY raw_listing_id, created_at DESC, id DESC
      )
    SQL

    remove_index :offers, :raw_listing_id
    add_index :offers, :raw_listing_id, unique: true
  end

  def down
    remove_index :offers, :raw_listing_id
    add_index :offers, :raw_listing_id
  end
end

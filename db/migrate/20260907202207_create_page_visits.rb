class CreatePageVisits < ActiveRecord::Migration[8.1]
  def change
    create_table :page_visits do |t|
      # A one-way hash of IP + user agent + a server-side secret, NOT the IP
      # itself. This site logs which medications people look up, which is
      # health-adjacent: it identifies a returning visitor for counting purposes
      # while leaving nothing that can be reversed back to a person, leaked, or
      # subpoenaed as a browsing history.
      t.string :visitor_hash, null: false

      t.string :path, null: false
      t.string :page_type            # home / search / medication / other
      t.bigint :medication_id        # set when a medication page was viewed
      t.string :search_query         # set on searches - what people look for

      t.string :referrer_host        # host only ("google.com"), never the full URL
      t.string :device_type          # phone / tablet / desktop / bot
      t.string :browser
      t.string :country

      t.datetime :visited_at, null: false

      t.timestamps
    end

    add_index :page_visits, :visitor_hash
    add_index :page_visits, :visited_at
    add_index :page_visits, :path
    add_index :page_visits, [ :page_type, :visited_at ]
    add_index :page_visits, :medication_id
  end
end

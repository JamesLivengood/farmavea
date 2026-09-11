class CreateCrawlRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :crawl_runs do |t|
      t.references :pharmacy, null: false, foreign_key: true
      t.string :city, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :items_found
      t.text :error_message

      t.timestamps
    end
  end
end

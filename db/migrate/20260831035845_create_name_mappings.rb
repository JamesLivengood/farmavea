class CreateNameMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :name_mappings do |t|
      t.references :pharmacy, null: false, foreign_key: true
      t.string :raw_name, null: false
      t.references :medication, null: false, foreign_key: true
      t.decimal :confidence
      t.string :source, null: false, default: "claude"

      t.timestamps
    end
    add_index :name_mappings, [ :pharmacy_id, :raw_name ], unique: true, name: "index_name_mappings_on_pharmacy_and_raw_name"
  end
end

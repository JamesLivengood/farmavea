class CreateMedications < ActiveRecord::Migration[8.1]
  def change
    create_table :medications do |t|
      t.string :canonical_name, null: false
      t.decimal :strength_value
      t.string :strength_unit
      t.string :form
      t.string :slug, null: false

      t.timestamps
    end
    add_index :medications, :slug, unique: true
    add_index :medications, :canonical_name
  end
end

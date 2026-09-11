class CreatePharmacies < ActiveRecord::Migration[8.1]
  def change
    create_table :pharmacies do |t|
      t.string :name
      t.string :slug
      t.string :base_url
      t.boolean :active, default: true, null: false

      t.timestamps
    end
    add_index :pharmacies, :name, unique: true
    add_index :pharmacies, :slug, unique: true
  end
end

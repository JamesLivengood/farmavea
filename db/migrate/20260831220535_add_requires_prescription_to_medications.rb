class AddRequiresPrescriptionToMedications < ActiveRecord::Migration[8.1]
  def change
    add_column :medications, :requires_prescription, :boolean
  end
end

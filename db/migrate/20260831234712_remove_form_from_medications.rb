class RemoveFormFromMedications < ActiveRecord::Migration[8.1]
  def change
    remove_column :medications, :form, :string
  end
end

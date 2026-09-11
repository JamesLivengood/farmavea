class NameMapping < ApplicationRecord
  belongs_to :pharmacy
  belongs_to :medication

  validates :raw_name, presence: true, uniqueness: { scope: :pharmacy_id }
end

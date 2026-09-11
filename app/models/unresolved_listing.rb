class UnresolvedListing < ApplicationRecord
  belongs_to :pharmacy

  validates :raw_name, presence: true, uniqueness: { scope: :pharmacy_id }
end

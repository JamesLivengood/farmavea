class RawListing < ApplicationRecord
  belongs_to :crawl_run
  belongs_to :pharmacy
  has_one :offer, dependent: :destroy

  validates :raw_name, presence: true
  validates :price_cents, presence: true, numericality: { greater_than: 0 }
  validates :scraped_at, presence: true

  def price
    price_cents / 100.0
  end
end

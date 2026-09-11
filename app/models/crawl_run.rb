class CrawlRun < ApplicationRecord
  STATUSES = %w[pending running succeeded failed].freeze

  belongs_to :pharmacy
  has_many :raw_listings, dependent: :destroy

  validates :city, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :for_today, -> { where(created_at: Time.current.all_day) }

  def mark_running!
    update!(status: "running", started_at: Time.current)
  end

  def mark_succeeded!
    update!(status: "succeeded", finished_at: Time.current, items_found: raw_listings.count)
  end

  def mark_failed!(error)
    update!(status: "failed", finished_at: Time.current, error_message: error.to_s.truncate(2000))
  end
end

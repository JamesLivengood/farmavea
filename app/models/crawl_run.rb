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

  # A crawl that found nothing is a failure, not a success. Del Ahorro's nightly job
  # ran for days against a sitemap whose product URLs had all started 404ing,
  # persisted zero listings each time, and reported "succeeded" - so nothing
  # surfaced the breakage. A crawler that returns nothing is always broken: a real
  # pharmacy never has an empty catalogue.
  def mark_succeeded!
    count = raw_listings.count
    if count.zero?
      update!(status: "failed", finished_at: Time.current, items_found: 0,
              error_message: "Crawl completed but persisted no listings - the crawler is likely broken.")
      Rails.logger.error("[CrawlRun##{id}] #{pharmacy.slug}: completed with zero listings, marked failed")
      return
    end

    update!(status: "succeeded", finished_at: Time.current, items_found: count)
  end

  def mark_failed!(error)
    update!(status: "failed", finished_at: Time.current, error_message: error.to_s.truncate(2000))
  end
end

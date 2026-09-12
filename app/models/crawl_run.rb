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
  # A run that finds far less than the previous one is nearly always truncated - a
  # WAF blocking partway, a page that stopped rendering, a layout change - not a real
  # inventory change. Marking it succeeded makes it the newest run, which then
  # becomes the baseline every later comparison is measured against, and the real
  # catalogue is forgotten. Guadalajara did exactly this: 280 listings against a
  # previous 2,120.
  MIN_SHARE_OF_PREVIOUS = 0.5
  MIN_BASELINE_TO_COMPARE = 200

  def mark_succeeded!
    count = raw_listings.count
    if count.zero?
      update!(status: "failed", finished_at: Time.current, items_found: 0,
              error_message: "Crawl completed but persisted no listings - the crawler is likely broken.")
      Rails.logger.error("[CrawlRun##{id}] #{pharmacy.slug}: completed with zero listings, marked failed")
      return
    end

    previous = previous_listing_count
    if previous >= MIN_BASELINE_TO_COMPARE && count < previous * MIN_SHARE_OF_PREVIOUS
      update!(status: "failed", finished_at: Time.current, items_found: count,
              error_message: "Found #{count} listings against #{previous} in the previous run - " \
                             "looks truncated, so the previous run is kept as authoritative.")
      Rails.logger.error("[CrawlRun##{id}] #{pharmacy.slug}: #{count} vs #{previous} listings, marked failed as truncated")
      return
    end

    update!(status: "succeeded", finished_at: Time.current, items_found: count)
  end

  def succeeded? = status == "succeeded"

  # Listings in the most recent run that actually produced any - a failed or empty
  # run is not a meaningful baseline.
  def previous_listing_count
    previous = self.class.where(pharmacy_id: pharmacy_id)
                   .where.not(id: id)
                   .where(id: RawListing.select(:crawl_run_id).distinct)
                   .order(created_at: :desc)
                   .first
    previous ? previous.raw_listings.count : 0
  end

  def mark_failed!(error)
    update!(status: "failed", finished_at: Time.current, error_message: error.to_s.truncate(2000))
  end
end

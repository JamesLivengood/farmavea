# Nightly crawl, scheduled in config/recurring.yml.
#
# Scoped to Farmacia del Ahorro only. Every other pharmacy exposes its full
# catalog in one pass and is already fully crawled, but Del Ahorro's category
# pages are WAF-blocked, so DelAhorroCrawler works through its sitemap a capped
# ~300 products per run (see DelAhorroCrawler::MAX_PRODUCTS) and skips anything
# already scraped that day. Running it nightly is what fills in the remaining
# backlog - roughly 715 of ~4,400 products so far.
#
# Crawls only - it does NOT run Claude aggregation, so it costs nothing to run
# unattended. Fresh prices reach the site when aggregation is run deliberately
# (bin/rails runner script/aggregate_latest.rb), which is the only step that
# spends money and has no per-run cap.
class DailyPriceUpdateJob < ApplicationJob
  queue_as :crawling

  CITY = "Morelia, Michoacán".freeze
  PHARMACY_SLUGS = %w[del_ahorro].freeze

  def perform
    Pharmacy.active.where(slug: PHARMACY_SLUGS).find_each do |pharmacy|
      CrawlPharmacyJob.perform_later(pharmacy.slug, city: CITY, aggregate: false)
    end
  end
end

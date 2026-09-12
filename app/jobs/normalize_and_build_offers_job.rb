class NormalizeAndBuildOffersJob < ApplicationJob
  queue_as :aggregation

  # existing_medications_block: optional, forwarded to MedicationNormalizer - lets a
  # batch runner processing many pharmacies in one process (script/aggregate_latest.rb)
  # share one cached prompt prefix across all of them. Left nil for the normal
  # production path where Solid Queue runs one of these jobs per pharmacy on its own
  # schedule, so there's no multi-pharmacy batch to share a prefix across anyway.
  def perform(crawl_run_id, existing_medications_block: nil)
    crawl_run = CrawlRun.find(crawl_run_id)
    raw_listings = crawl_run.raw_listings.to_a
    return if raw_listings.empty?

    raw_listing_to_medication = Aggregation::MedicationNormalizer.new(
      pharmacy: crawl_run.pharmacy,
      raw_listings: raw_listings,
      existing_medications_block: existing_medications_block
    ).call

    Aggregation::OfferBuilder.new(
      pharmacy: crawl_run.pharmacy,
      city: crawl_run.city,
      raw_listing_to_medication: raw_listing_to_medication
    ).call

    deactivate_stale_offers(crawl_run)
  end

  private

  # A crawl that found far less than the previous one is nearly always truncated -
  # a WAF blocking partway, a page that stopped rendering, a site layout change.
  # Deactivating on that basis removes products that are still for sale.
  MIN_COVERAGE_TO_DEACTIVATE = 0.5

  # Today's fresh offers for this pharmacy/city should replace yesterday's -
  # otherwise a medication that's gone out of stock keeps showing as "cheapest".
  # But only when this crawl actually covered the catalogue: see above.
  def deactivate_stale_offers(crawl_run)
    unless broad_enough_to_deactivate?(crawl_run)
      Rails.logger.warn(
        "[NormalizeAndBuildOffersJob] crawl_run##{crawl_run.id} (#{crawl_run.pharmacy.slug}) found " \
        "#{crawl_run.raw_listings.count} listings, well under the previous run - keeping existing " \
        "offers active rather than deactivating products that are probably still for sale."
      )
      return
    end

    Offer.where(pharmacy_id: crawl_run.pharmacy_id, city: crawl_run.city)
         .where.not(raw_listing_id: crawl_run.raw_listing_ids)
         .update_all(active: false)
  end

  def broad_enough_to_deactivate?(crawl_run)
    current = crawl_run.raw_listings.count
    return false if current.zero?

    previous = CrawlRun.where(pharmacy_id: crawl_run.pharmacy_id)
                       .where.not(id: crawl_run.id)
                       .where(id: RawListing.select(:crawl_run_id).distinct)
                       .order(created_at: :desc)
                       .first
    return true if previous.nil? # nothing to compare against - first real crawl

    current >= previous.raw_listings.count * MIN_COVERAGE_TO_DEACTIVATE
  end
end

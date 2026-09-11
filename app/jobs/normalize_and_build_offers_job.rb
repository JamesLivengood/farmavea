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

  # Today's fresh offers for this pharmacy/city should replace yesterday's -
  # otherwise a medication that's gone out of stock keeps showing as "cheapest".
  def deactivate_stale_offers(crawl_run)
    Offer.where(pharmacy_id: crawl_run.pharmacy_id, city: crawl_run.city)
         .where.not(raw_listing_id: crawl_run.raw_listing_ids)
         .update_all(active: false)
  end
end

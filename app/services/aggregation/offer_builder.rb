module Aggregation
  # Turns today's RawListings (already mapped to a Medication) into Offer rows,
  # computing price-per-mg deterministically in Ruby so "truly cheapest" is exact
  # arithmetic, not an LLM estimate.
  class OfferBuilder
    def initialize(pharmacy:, city:, raw_listing_to_medication:)
      @pharmacy = pharmacy
      @city = city
      @raw_listing_to_medication = raw_listing_to_medication
    end

    # Del Ahorro's "Requiere receta" field is a verified bidirectional true/false
    # signal (spot-checked against real Rx vs. OTC products). Farmacias ABC's "receta"
    # tag and Vida Farmacias' "Requiere receta" badge are deliberately conservative -
    # each crawler only ever asserts true or nil (unknown), never false, precisely
    # because we couldn't confirm absence means "not prescription" for those two - so
    # they're safe to trust without the false-negative risk that ruled out
    # Guadalajara's free-text legal disclaimer (which had confirmed false positives
    # AND false negatives, and is never written from at all).
    TRUSTED_PRESCRIPTION_SOURCE_SLUGS = %w[del_ahorro farmacias_abc vida_farmacias].freeze

    def call
      RawListing.where(id: raw_listing_to_medication.keys).find_each do |listing|
        medication = raw_listing_to_medication[listing.id]
        next unless medication

        # A RawListing has exactly one Offer (enforced by a unique index on
        # raw_listing_id) - re-running aggregation against the same crawl_run
        # (e.g. after fixing an unrelated bug mid-run) must update that one row
        # rather than create a second, otherwise-identical Offer.
        offer = Offer.find_or_initialize_by(raw_listing: listing)
        offer.update!(
          medication: medication,
          pharmacy: pharmacy,
          city: city,
          price_cents: listing.price_cents,
          price_per_mg: price_per_mg_for(medication, listing),
          scraped_at: listing.scraped_at,
          active: true
        )

        update_prescription_flag(medication, listing)
      end
    end

    private

    attr_reader :pharmacy, :city, :raw_listing_to_medication

    def update_prescription_flag(medication, listing)
      return unless TRUSTED_PRESCRIPTION_SOURCE_SLUGS.include?(pharmacy.slug)
      return if listing.requires_prescription.nil?
      return unless medication.requires_prescription.nil?

      medication.update!(requires_prescription: listing.requires_prescription)
    end

    # peso-per-mg = price / (strength_value_in_mg * pack_quantity). Dividing by the
    # per-pill strength alone (without pack_quantity) would compare box price
    # against a single pill's strength, silently favoring a 10-pack over an
    # otherwise-identical 20-pack that offers twice as much medication for
    # (correctly) about twice the price. Falls back to pack_quantity = 1 when it's
    # unknown, i.e. treats the listing as a single unit - the same behavior as
    # before this field existed, not a new assumption.
    #
    # Returns nil when the medication has no comparable per-mg strength (e.g.
    # topical/device products), in which case the offer is still stored (comparable
    # by raw price) but excluded from price-per-mg rankings by callers that require it.
    def price_per_mg_for(medication, listing)
      return nil if medication.strength_value.blank? || medication.strength_value.zero?

      mg_per_unit = case medication.strength_unit
      when "mg" then medication.strength_value
      when "mcg" then medication.strength_value / 1000.0
      when "g" then medication.strength_value * 1000.0
      else
                   return nil # ml/unit strengths aren't comparable on a per-mg basis
      end

      # No pack size means we genuinely don't know how much medication is in the
      # box, so we can't compute a real per-mg price. This used to fall back to
      # pack_quantity = 1 - dividing a whole box's price by a single tablet's
      # strength - which produced figures wrong by 10-100x and ranked those
      # listings far below equivalent ones (a $497 Quetiapina box showed as 100x
      # pricier per mg than a $296 box of 60). A missing number is honest; a
      # confidently wrong one on a page people use to decide where to spend is not.
      return nil unless listing.pack_quantity.to_i.positive?

      total_mg = mg_per_unit * listing.pack_quantity
      (listing.price / total_mg).round(6)
    end
  end
end

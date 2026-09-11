# Fills in RawListing#pack_quantity from the product URL for listings whose NAME
# doesn't state one, then recomputes price_per_mg for the affected offers.
#
# Costs nothing - pure regex over existing rows, no Claude calls.
#
# Why this exists: some pharmacies put the pack size in the URL slug but strip it
# from the display name. Benavides is the big one - the name is just
# "200 mg Tramadol" while the slug reads ".../200-mg-tramadol-60-tabletas". Reading
# names alone left ~95% of their listings with no pack size, and since
# OfferBuilder#price_per_mg_for can't compute a real per-mg price without it, those
# offers had no comparable price at all.
#
# Run with: bin/rails runner script/backfill_pack_from_urls.rb

URL_PATTERN = Aggregation::LocalMedicationMatcher::PACK_QUANTITY_URL_PATTERN

# A pack count far outside this range is almost certainly something else that
# happened to sit in the slug (a strength, a volume, a product code).
PLAUSIBLE_PACK_RANGE = (1..500)

updated = 0
skipped_implausible = 0
scanned = 0

puts "Scanning listings with no pack_quantity but a product URL..."

RawListing.where(pack_quantity: nil).where.not(product_url: nil).find_each(batch_size: 2_000) do |listing|
  scanned += 1
  match = listing.product_url.match(URL_PATTERN)
  next unless match

  quantity = match[1].to_i
  unless PLAUSIBLE_PACK_RANGE.cover?(quantity)
    skipped_implausible += 1
    next
  end

  listing.update_columns(pack_quantity: quantity)
  updated += 1
  puts "  #{updated} updated..." if (updated % 2_500).zero?
end

puts "Scanned #{scanned}; set pack_quantity on #{updated} (skipped #{skipped_implausible} implausible values)."
puts ""
puts "Recomputing price_per_mg for affected offers..."

recomputed = 0
cleared = 0

Offer.joins(:medication, :raw_listing).includes(:medication, :raw_listing)
     .find_each(batch_size: 1_000) do |offer|
  medication = offer.medication
  listing = offer.raw_listing

  new_value =
    if medication.strength_value.blank? || medication.strength_value.zero?
      nil
    else
      mg_per_unit =
        case medication.strength_unit
        when "mg" then medication.strength_value
        when "mcg" then medication.strength_value / 1000.0
        when "g" then medication.strength_value * 1000.0
        end

      if mg_per_unit.nil? || !listing.pack_quantity.to_i.positive?
        nil
      else
        (listing.price / (mg_per_unit * listing.pack_quantity)).round(6)
      end
    end

  next if offer.price_per_mg.to_s == new_value.to_s

  offer.update_columns(price_per_mg: new_value)
  new_value.nil? ? cleared += 1 : recomputed += 1
end

puts ""
puts "=" * 70
puts "DONE."
puts "  Listings given a pack_quantity from their URL: #{updated}"
puts "  Offers with a recomputed price_per_mg:        #{recomputed}"
puts "  Offers whose price_per_mg was cleared to nil: #{cleared}"
puts "     (pack size genuinely unknown - a missing number beats one that's wrong by 10-100x)"
puts "=" * 70

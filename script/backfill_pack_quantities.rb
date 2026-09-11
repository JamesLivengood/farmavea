# Retroactively fills in RawListing#pack_quantity for listings whose raw_name
# plainly states one ("Caja con 12", "C/20", "30 Tabletas"), then recomputes
# price_per_mg for the affected Offers.
#
# Costs nothing - pure Ruby regex over existing rows, no Claude calls. This exists
# because pack_quantity was added to the schema after most names were already
# resolved and cached in NameMapping, and a cache hit never re-reaches the
# extraction step - so those listings were left with pack_quantity nil and their
# price_per_mg computed as if the whole box were a single pill (making a 20-pack
# look pricier per mg than an otherwise-identical 10-pack).
#
# Run with: bin/rails runner script/backfill_pack_quantities.rb

PATTERNS = Aggregation::LocalMedicationMatcher::PACK_QUANTITY_PATTERNS

def extract_pack_quantity(raw_name)
  PATTERNS.each do |pattern|
    match = raw_name.match(pattern)
    return match[1].to_i if match
  end
  nil
end

updated_listings = 0
scanned = 0

puts "Scanning listings with no pack_quantity..."

RawListing.where(pack_quantity: nil).find_each(batch_size: 2_000) do |listing|
  scanned += 1
  quantity = extract_pack_quantity(listing.raw_name)
  next if quantity.nil? || quantity <= 0

  listing.update_columns(pack_quantity: quantity)
  updated_listings += 1
  puts "  #{updated_listings} listings updated..." if (updated_listings % 1_000).zero?
end

puts "Scanned #{scanned} listings, set pack_quantity on #{updated_listings}."
puts ""
puts "Recomputing price_per_mg for affected offers..."

recomputed = 0
skipped_no_strength = 0

# Only offers whose listing just gained a pack_quantity need recomputing - their
# stored price_per_mg was calculated against an implicit pack of 1.
Offer.joins(:raw_listing, :medication)
     .where.not(raw_listings: { pack_quantity: nil })
     .includes(:raw_listing, :medication)
     .find_each(batch_size: 1_000) do |offer|
  medication = offer.medication
  listing = offer.raw_listing

  if medication.strength_value.blank? || medication.strength_value.zero?
    skipped_no_strength += 1
    next
  end

  mg_per_unit = case medication.strength_unit
  when "mg" then medication.strength_value
  when "mcg" then medication.strength_value / 1000.0
  when "g" then medication.strength_value * 1000.0
  else
                 skipped_no_strength += 1
                 next # ml/unit strengths aren't comparable per-mg
  end

  pack_quantity = listing.pack_quantity.to_i > 0 ? listing.pack_quantity : 1
  new_value = (listing.price / (mg_per_unit * pack_quantity)).round(6)

  next if offer.price_per_mg.present? && offer.price_per_mg.to_f == new_value.to_f

  offer.update_columns(price_per_mg: new_value)
  recomputed += 1
  puts "  #{recomputed} offers recomputed..." if (recomputed % 1_000).zero?
end

puts ""
puts "=" * 70
puts "DONE."
puts "  Listings given a pack_quantity: #{updated_listings}"
puts "  Offers with price_per_mg recomputed: #{recomputed}"
puts "  Offers skipped (no per-mg comparable strength): #{skipped_no_strength}"
puts "=" * 70

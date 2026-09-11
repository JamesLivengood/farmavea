# Runs a small, representative SAMPLE of the pack_quantity/local-matcher backfill -
# not a full run - so real Claude token usage can be measured and sanity-checked
# before committing to the full ~49K-listing backfill. Samples ~5% of each
# pharmacy's raw_listings (not just the first 5% overall, which would be almost
# entirely Benavides given how lopsided the dataset is) so the sample actually
# reflects the mix of pharmacies/name styles a full run would see.
#
# Run with: bin/rails runner script/backfill_sample.rb
#
# Cleans nothing up afterward - unlike script/test_claude_matching.rb, this writes
# real NameMapping/Medication/Offer/pack_quantity data against real pharmacies, on
# purpose: this sample's results should count toward (not be thrown away before) the
# eventual full run.

SAMPLE_FRACTION = 0.05

existing_medications_block = Aggregation::ClaudeMedicationMatcher.build_shared_existing_medications_block

total_sampled = 0
total_claude_calls_before = 0

Pharmacy.active.find_each do |pharmacy|
  all_ids = RawListing.where(pharmacy: pharmacy).pluck(:id)
  next if all_ids.empty?

  sample_size = [ (all_ids.size * SAMPLE_FRACTION).ceil, all_ids.size ].min
  sampled_ids = all_ids.sample(sample_size)
  listings = RawListing.where(id: sampled_ids).to_a

  puts "=" * 70
  puts "[#{Time.current}] #{pharmacy.name}: sampling #{listings.size} of #{all_ids.size} raw_listings"
  puts "=" * 70

  before_mappings = NameMapping.count
  before_unresolved = UnresolvedListing.count

  begin
    raw_listing_to_medication = Aggregation::MedicationNormalizer.new(
      pharmacy: pharmacy, raw_listings: listings,
      existing_medications_block: existing_medications_block
    ).call

    Aggregation::OfferBuilder.new(
      pharmacy: pharmacy, city: "Morelia, Michoacán",
      raw_listing_to_medication: raw_listing_to_medication
    ).call
  rescue StandardError => e
    puts "[#{Time.current}] #{pharmacy.name}: FAILED - #{e.class}: #{e.message}"
    next
  end

  new_mappings = NameMapping.count - before_mappings
  new_unresolved = UnresolvedListing.count - before_unresolved
  total_sampled += listings.size
  puts "[#{Time.current}] #{pharmacy.name}: +#{new_mappings} new NameMappings, +#{new_unresolved} new Unresolved"
end

puts "=" * 70
puts "DONE. Sampled #{total_sampled} raw_listings (~#{(SAMPLE_FRACTION * 100).round}% of #{RawListing.count})."
puts "Check Anthropic console usage/billing to see real token cost, then decide whether to run the full backfill."
puts "=" * 70

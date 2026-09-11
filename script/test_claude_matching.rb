# Cheap, safe smoke test for the Claude matching pipeline - sends only a small,
# hand-picked set of raw names (not a real crawl's worth) so a single run costs at
# most a few cents, then checks the results against hardcoded expectations. Run
# this after ANY change to MedicationNormalizer/ClaudeMedicationMatcher/
# LocalMedicationMatcher/OfferBuilder, before running a real multi-thousand-name
# aggregation - if this fails, the real run would have the same bug, just far more
# expensively.
#
# Run with: bin/rails runner script/test_claude_matching.rb
#
# IMPORTANT: this hits the real Claude API (small real cost, ~$0.01-0.05 total).
# It does NOT touch real pharmacy data - it creates a throwaway test Pharmacy and
# cleans everything up (including any Medication/NameMapping/UnresolvedListing rows
# it created) at the end, success or failure.

TEST_PHARMACY_SLUG = "test_claude_smoke_#{SecureRandom.hex(4)}"

# Each case: a raw_name, and what we expect back. `expect: nil` means we expect it
# to be REJECTED (low confidence / unresolvable) - important to test this path too,
# not just the happy path, since silently over-matching is worse than under-matching.
CASES = [
  # Already-known generics in different word orders - should ideally be caught by
  # LocalMedicationMatcher for free (0 tokens), not billed to Claude at all. This
  # script reports which tier actually resolved each one.
  { raw_name: "Ibuprofeno 400 mg", expect: { canonical_name: "Ibuprofeno", strength_value: 400.0, strength_unit: "mg" } },
  { raw_name: "400 mg Ibuprofeno", expect: { canonical_name: "Ibuprofeno", strength_value: 400.0, strength_unit: "mg" } },

  # A real brand name that requires genuine pharmaceutical knowledge - must go to
  # Claude, and must resolve to the correct generic ingredient.
  { raw_name: "Tylenol 500mg 20 tabletas", expect: { canonical_name: "Paracetamol", strength_value: 500.0, strength_unit: "mg" } },

  # A pack-size-bearing name - checks the pack_quantity extraction/persistence path
  # (added to fix the price-per-mg-ignores-pack-size bug).
  { raw_name: "Amoxicilina 500mg Caja con 12 Cápsulas", expect: { canonical_name: "Amoxicilina", strength_value: 500.0, strength_unit: "mg", pack_quantity: 12 } },

  # Deliberately garbled/unparseable - Claude should REJECT this (return nil /
  # low confidence), not invent a guess. If this ever resolves to something, that's
  # a correctness regression more dangerous than a missed match.
  { raw_name: "XKQ-99 Unidad Especial Ref 4471-B", expect: nil }
].freeze

def cleanup(pharmacy)
  return unless pharmacy

  medication_ids = NameMapping.where(pharmacy: pharmacy).pluck(:medication_id).uniq
  NameMapping.where(pharmacy: pharmacy).delete_all
  UnresolvedListing.where(pharmacy: pharmacy).delete_all
  RawListing.where(pharmacy: pharmacy).delete_all
  CrawlRun.where(pharmacy: pharmacy).delete_all
  # Only remove medications this test run created and that nothing else references -
  # never touch a Medication that has other pharmacies' real offers on it.
  Medication.where(id: medication_ids).each do |m|
    m.destroy! if m.offers.empty? && m.name_mappings.empty?
  end
  pharmacy.destroy!
end

pharmacy = Pharmacy.create!(name: "TEST SMOKE PHARMACY", slug: TEST_PHARMACY_SLUG, base_url: "https://example.invalid", active: false)

begin
  raw_listings = CASES.map.with_index do |c, i|
    RawListing.create!(
      crawl_run: pharmacy.crawl_runs.create!(city: "Test", status: "succeeded"),
      pharmacy: pharmacy,
      raw_name: c[:raw_name],
      price_cents: 1000 + i,
      scraped_at: Time.current
    )
  end

  puts "Sending #{raw_listings.size} test names to the matching pipeline..."
  result = Aggregation::MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: raw_listings).call

  puts "=" * 70
  failures = 0

  CASES.each_with_index do |c, i|
    listing = raw_listings[i]
    medication = result[listing.id]
    listing.reload

    tier = if NameMapping.find_by(pharmacy: pharmacy, raw_name: c[:raw_name])&.source
      NameMapping.find_by(pharmacy: pharmacy, raw_name: c[:raw_name]).source
    elsif UnresolvedListing.exists?(pharmacy: pharmacy, raw_name: c[:raw_name])
      "rejected"
    else
      "unknown"
    end

    if c[:expect].nil?
      if medication.nil?
        puts "PASS  \"#{c[:raw_name]}\" correctly rejected (tier: #{tier})"
      else
        puts "FAIL  \"#{c[:raw_name]}\" should have been rejected but matched #{medication.canonical_name} #{medication.strength_value}#{medication.strength_unit}"
        failures += 1
      end
      next
    end

    if medication.nil?
      puts "FAIL  \"#{c[:raw_name]}\" expected a match but got none (tier: #{tier})"
      failures += 1
      next
    end

    ok = medication.canonical_name == c[:expect][:canonical_name] &&
         medication.strength_value.to_f == c[:expect][:strength_value] &&
         medication.strength_unit == c[:expect][:strength_unit]

    if c[:expect][:pack_quantity]
      ok &&= listing.pack_quantity == c[:expect][:pack_quantity]
    end

    if ok
      puts "PASS  \"#{c[:raw_name]}\" -> #{medication.canonical_name} #{medication.strength_value}#{medication.strength_unit}" \
           "#{listing.pack_quantity ? " x#{listing.pack_quantity}" : ""} (tier: #{tier})"
    else
      puts "FAIL  \"#{c[:raw_name]}\" expected #{c[:expect].inspect}, got " \
           "canonical_name=#{medication.canonical_name} strength=#{medication.strength_value}#{medication.strength_unit} " \
           "pack_quantity=#{listing.pack_quantity.inspect} (tier: #{tier})"
      failures += 1
    end
  end

  puts "=" * 70
  if failures.zero?
    puts "ALL #{CASES.size} CASES PASSED - safe to run a full aggregation."
  else
    puts "#{failures} of #{CASES.size} CASES FAILED - do NOT run a full aggregation until this is fixed."
  end
ensure
  cleanup(pharmacy)
  puts "Test data cleaned up (throwaway pharmacy, its raw_listings/crawl_runs/name_mappings/unresolved removed)."
end

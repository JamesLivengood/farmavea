# Exports the product names that still need identifying, so they can be pasted into
# Claude in a browser instead of going through the paid API.
#
# Writes two files into tmp/manual_matching/:
#   - names_<n>.csv     the id,pharmacy,raw_name rows
#   - prompt_<n>.txt    a ready-to-paste prompt (instructions + the same CSV inline)
#
# Only exports names that would actually cost money: anything already in
# NameMapping (free cache hit) or recently rejected in UnresolvedListing is
# skipped, matching MedicationNormalizer's own tiering. Nothing is written to the
# database - import the result with script/import_manual_matching.rb.
#
# Run with:
#   bin/rails runner script/export_for_manual_matching.rb              # everything pending
#   bin/rails runner script/export_for_manual_matching.rb del_ahorro   # one pharmacy
#   LIMIT=200 bin/rails runner script/export_for_manual_matching.rb    # cap the batch

require "csv"

pharmacy_slug = ARGV.first
limit = ENV["LIMIT"]&.to_i

pharmacies = pharmacy_slug ? Pharmacy.where(slug: pharmacy_slug) : Pharmacy.active
abort "No pharmacy matching #{pharmacy_slug.inspect}" if pharmacies.empty?

retry_after = Aggregation::MedicationNormalizer::RETRY_UNRESOLVED_AFTER

# REVIEW_REJECTED=1 exports names the API already rejected as non-medications,
# instead of the never-tried ones. Worth doing periodically: a sample of these
# turned out to contain real drugs the API had discarded - injectables,
# suspensions and syrups (where strength is per-mL rather than per-tablet) and
# unfamiliar Mexican brand names. A human reviewing them recovers real listings,
# and the import writes a NameMapping that overrides the rejection.
review_rejected = ENV["REVIEW_REJECTED"].present?

# Appended to the prompt in review mode. Without it the reviewer isn't told these
# were already judged once, and can't tell whether the job is to identify them or
# to second-guess a previous decision.
REVIEW_NOTE = <<~NOTE.freeze

  IMPORTANT - these names were ALREADY reviewed once and judged "not a medication".
  That judgement was wrong often enough to be worth a second pass, most commonly for:
    - injectables, suspensions, syrups and drops, where strength is per-mL
      ("Cicloferon Susp 60 Ml", "OXFON 4MG/5ML SOL INY") - these ARE medications;
      use strength_unit "ml" for the per-mL concentration
    - Mexican brand names that may be unfamiliar ("Gliparix", "Hetezon", "Mistan")
    - a bare active ingredient with no strength ("Acido Cromoglicico") - still a
      medication; use 0 / "unit" for strength
  Genuinely non-medication items (baby formula, toothpaste, talc, cosmetics) are
  correctly excluded - keep leaving those empty. Do not force a match to be helpful.
NOTE

rows = []
pharmacies.find_each do |pharmacy|
  names = RawListing.where(pharmacy: pharmacy).distinct.pluck(:raw_name)
  next if names.empty?

  cached = NameMapping.where(pharmacy: pharmacy, raw_name: names).pluck(:raw_name)
  rejected = UnresolvedListing.where(pharmacy: pharmacy, raw_name: names)
                              .where("updated_at > ?", retry_after.ago).pluck(:raw_name)

  pending = review_rejected ? (rejected - cached) : (names - cached - rejected)
  # The local regex tier resolves some of these for free - don't spend a human's
  # attention on them either.
  locally_matched = pending.any? ? Aggregation::LocalMedicationMatcher.new(raw_names: pending).call.keys : []

  (pending - locally_matched).each { |name| rows << [ pharmacy.slug, name ] }
end

if rows.empty?
  puts "Nothing pending - every name is already resolved, recently rejected, or matched locally."
  exit
end

rows = rows.first(limit) if limit&.positive?

dir = Rails.root.join("tmp", "manual_matching")
FileUtils.mkdir_p(dir)
csv_path = dir.join("names_#{rows.size}.csv")
prompt_path = dir.join("prompt_#{rows.size}.txt")

csv_body = CSV.generate do |csv|
  csv << %w[id pharmacy raw_name]
  rows.each_with_index { |(slug, name), i| csv << [ i + 1, slug, name ] }
end
File.write(csv_path, csv_body)

# The instructions deliberately mirror ClaudeMedicationMatcher's system prompt and
# tool schema - the import script validates against the same rules, so answers from
# the browser are held to the same standard as the API's.
File.write(prompt_path, <<~PROMPT)
  You are a pharmacology data-normalization assistant for a Mexican medication
  price-comparison service. Below are raw product names scraped from Mexican
  pharmacy websites. For each one, identify the underlying medication.

  Rules:
  - canonical_name must be the ACTIVE INGREDIENT (generic name), never the brand.
    E.g. "Tylenol 500mg" and "Panadol 500mg" are both "Paracetamol".
  - Use the exact same canonical_name spelling/casing for the same active
    ingredient every time, so records group reliably.
  - For a combination product, use the combination name as Mexican pharmacies
    write it (e.g. "Paracetamol/Cafeina/Acido acetilsalicilico"), consistently.
  - strength_value is the per-unit strength (per tablet/capsule/mL), NOT the total
    in the package. Use 0 if no meaningful strength applies.
  - strength_unit must be exactly one of: mg, mcg, g, ml, unit
    Use "unit" when there is no meaningful mg/mcg/mL strength.
  - pack_quantity is how many tablets/capsules are in the package, or empty if it
    isn't a discrete-unit product (a syrup, cream or spray) or isn't stated.
  - confidence is 0.0-1.0. An INCORRECT match is worse than no match, because it
    silently merges two different drugs' prices. If you cannot determine the
    active ingredient with reasonable confidence, leave canonical_name EMPTY and
    give a low confidence rather than guessing.
  - Many of these are not medications at all (cosmetics, devices, supplements).
    Leave canonical_name empty for those.
  #{review_rejected ? REVIEW_NOTE : ""}
  Reply with ONLY a CSV code block, no commentary. Exactly these columns:

  id,canonical_name,strength_value,strength_unit,pack_quantity,confidence

  One row per input id, including the ones you could not identify (empty
  canonical_name, 0 strength_value, "unit" strength_unit, low confidence).

  Here are the products:

  #{csv_body}
PROMPT

puts "Exported #{rows.size} names needing identification."
puts ""
puts "  CSV:    #{csv_path}"
puts "  Prompt: #{prompt_path}   <- paste this into Claude"
puts ""
puts "Then save Claude's CSV reply and run:"
puts "  bin/rails runner script/import_manual_matching.rb <path-to-reply.csv>"

# Imports medication matches produced by Claude in a browser (see
# script/export_for_manual_matching.rb) instead of through the paid API.
#
# Takes the CSV Claude replied with and applies exactly the same rules the API
# path uses - same confidence threshold, same "reuse an existing Medication rather
# than create a duplicate" lookup, same UnresolvedListing handling - so manually
# matched data is held to the same standard as API-matched data.
#
# Run with:
#   bin/rails runner script/import_manual_matching.rb tmp/manual_matching/reply.csv
#   DRY_RUN=1 bin/rails runner script/import_manual_matching.rb <file>   # preview only
#
# The reply must have these columns:
#   id,canonical_name,strength_value,strength_unit,pack_quantity,confidence
# and `id` must match the ids in the exported names_<n>.csv.

require "csv"

reply_path = ARGV.first
abort "Usage: bin/rails runner script/import_manual_matching.rb <reply.csv>" if reply_path.blank?
abort "No such file: #{reply_path}" unless File.exist?(reply_path)

dry_run = ENV["DRY_RUN"].present?

# Find the export this reply corresponds to, so ids can be mapped back to names.
export_dir = Rails.root.join("tmp", "manual_matching")
exports = Dir.glob(export_dir.join("names_*.csv")).sort_by { |f| File.mtime(f) }
abort "No export found in #{export_dir} - run script/export_for_manual_matching.rb first" if exports.empty?

export_path = exports.last
puts "Matching against export: #{export_path}"

id_to_source = {}
CSV.foreach(export_path, headers: true) do |row|
  id_to_source[row["id"].to_i] = { pharmacy_slug: row["pharmacy"], raw_name: row["raw_name"] }
end

pharmacies = Pharmacy.where(slug: id_to_source.values.map { |v| v[:pharmacy_slug] }.uniq).index_by(&:slug)

threshold = Aggregation::ClaudeMedicationMatcher::ACCEPT_CONFIDENCE_THRESHOLD
valid_units = %w[mg mcg g ml unit]

accepted = 0
rejected = 0
skipped = []

# Strip a markdown fence if the reply was pasted with one.
raw = File.read(reply_path).gsub(/\A\s*```(?:csv)?\s*\n/, "").gsub(/\n```\s*\z/, "")

CSV.parse(raw, headers: true) do |row|
  id = row["id"].to_i
  source = id_to_source[id]
  unless source
    skipped << "id #{row['id'].inspect} is not in the export"
    next
  end

  pharmacy = pharmacies[source[:pharmacy_slug]]
  unless pharmacy
    skipped << "id #{id}: unknown pharmacy #{source[:pharmacy_slug]}"
    next
  end

  raw_name = source[:raw_name]
  canonical_name = row["canonical_name"].to_s.strip.presence
  confidence = row["confidence"].to_f
  strength_value = row["strength_value"].to_s.strip
  strength_unit = row["strength_unit"].to_s.strip.downcase
  pack_quantity = row["pack_quantity"].to_s.strip

  # Same bar as the API path: a wrong match silently merges two drugs' prices, so
  # anything unidentified or low-confidence is recorded as unresolved, not guessed.
  if canonical_name.nil? || confidence < threshold
    rejected += 1
    next if dry_run

    reason = canonical_name.nil? ? "Not identified (manual matching)" : "Confidence #{confidence.round(2)} below accept threshold (#{threshold})"
    unresolved = UnresolvedListing.find_or_initialize_by(pharmacy: pharmacy, raw_name: raw_name)
    unresolved.reason = reason
    unresolved.confidence = confidence
    unresolved.updated_at = Time.current
    unresolved.save!
    next
  end

  unless valid_units.include?(strength_unit)
    skipped << "id #{id}: strength_unit #{strength_unit.inspect} is not one of #{valid_units.join(', ')}"
    next
  end

  accepted += 1
  next if dry_run

  medication = Medication.find_or_create_by!(
    canonical_name: canonical_name,
    strength_value: strength_value.presence || 0,
    strength_unit: strength_unit
  )

  NameMapping.find_or_create_by!(pharmacy: pharmacy, raw_name: raw_name) do |mapping|
    mapping.medication = medication
    mapping.confidence = confidence
    mapping.source = "manual"
  end
  UnresolvedListing.where(pharmacy: pharmacy, raw_name: raw_name).delete_all

  if pack_quantity.to_i.positive?
    RawListing.where(pharmacy: pharmacy, raw_name: raw_name, pack_quantity: nil)
              .update_all(pack_quantity: pack_quantity.to_i)
  end
end

puts ""
puts "=" * 70
puts dry_run ? "DRY RUN - nothing was written." : "IMPORTED."
puts "  accepted (confidence >= #{threshold}): #{accepted}"
puts "  recorded as unresolved:                #{rejected}"
if skipped.any?
  puts "  skipped (#{skipped.size}):"
  skipped.first(10).each { |s| puts "    #{s}" }
  puts "    ...and #{skipped.size - 10} more" if skipped.size > 10
end
puts "=" * 70
unless dry_run
  puts ""
  puts "Now rebuild offers so these appear on the site:"
  puts "  bin/rails runner script/aggregate_latest.rb"
  puts "(that will be nearly free - these names are now cached NameMappings)"
end

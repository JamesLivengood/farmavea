# Like aggregate_only.rb, but scoped to only the most recent succeeded CrawlRun
# per pharmacy - avoids redundantly re-processing (and re-charging Claude API
# calls for) older crawl runs that were already aggregated in a previous pass.
# Run with: bin/rails runner script/aggregate_latest.rb

latest_run_ids = CrawlRun.where(status: "succeeded")
                          .group(:pharmacy_id)
                          .maximum(:id)
                          .values

crawl_runs = CrawlRun.where(id: latest_run_ids).order(:id)
puts "Processing #{crawl_runs.count} crawl runs (latest per pharmacy)"

# Built ONCE for this whole multi-pharmacy run and passed to every pharmacy's job,
# so they all share one byte-identical cached prompt prefix instead of each
# rebuilding (and cache-missing on) its own - see ClaudeMedicationMatcher's
# initialize comment for why a per-pharmacy block silently defeated prompt caching.
existing_medications_block = Aggregation::ClaudeMedicationMatcher.build_shared_existing_medications_block

crawl_runs.find_each do |crawl_run|
  puts "=" * 70
  puts "[#{Time.current}] Aggregating: #{crawl_run.pharmacy.name} (crawl_run##{crawl_run.id}, #{crawl_run.items_found} items)"
  puts "=" * 70

  begin
    NormalizeAndBuildOffersJob.new.perform(crawl_run.id, existing_medications_block: existing_medications_block)
    puts "[#{Time.current}] #{crawl_run.pharmacy.name}: done. Medications=#{Medication.count}, Offers=#{Offer.count}, Unresolved=#{UnresolvedListing.count}"
  rescue StandardError => e
    puts "[#{Time.current}] #{crawl_run.pharmacy.name}: FAILED - #{e.class}: #{e.message}"
  end
end

puts "=" * 70
puts "DONE. Medications=#{Medication.count}, Offers=#{Offer.count}, NameMappings=#{NameMapping.count}, Unresolved=#{UnresolvedListing.count}"
puts "=" * 70

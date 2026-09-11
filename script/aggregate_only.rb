# Runs NormalizeAndBuildOffersJob directly (not via Solid Queue) against every
# successful CrawlRun, so real Medication/NameMapping/Offer records get built from
# the raw crawl data already in the DB. This is the step that costs real Claude API
# money (via Aggregation::ClaudeMedicationMatcher) - run deliberately, not as a
# side effect of crawling. Run with: bin/rails runner script/aggregate_only.rb

crawl_runs = CrawlRun.where(status: "succeeded").order(:id)
puts "Processing #{crawl_runs.count} crawl runs"

crawl_runs.find_each do |crawl_run|
  puts "=" * 70
  puts "[#{Time.current}] Aggregating: #{crawl_run.pharmacy.name} (crawl_run##{crawl_run.id}, #{crawl_run.items_found} items)"
  puts "=" * 70

  begin
    NormalizeAndBuildOffersJob.new.perform(crawl_run.id)
    puts "[#{Time.current}] #{crawl_run.pharmacy.name}: done. Medications=#{Medication.count}, Offers=#{Offer.count}, Unresolved=#{UnresolvedListing.count}"
  rescue StandardError => e
    puts "[#{Time.current}] #{crawl_run.pharmacy.name}: FAILED - #{e.class}: #{e.message}"
  end
end

puts "=" * 70
puts "DONE. Medications=#{Medication.count}, Offers=#{Offer.count}, NameMappings=#{NameMapping.count}, Unresolved=#{UnresolvedListing.count}"
puts "=" * 70

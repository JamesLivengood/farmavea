# Runs the crawlers directly, bypassing CrawlPharmacyJob's automatic hand-off to
# NormalizeAndBuildOffersJob - so RawListing rows land in the DB for review, but
# nothing is sent to Claude. Run with: bin/rails runner script/crawl_only.rb
#
# Progress and a final summary print to stdout so a `tail -f` on the redirected
# output shows real-time status during a long run.

CITY = "Morelia, Michoacán".freeze

CRAWLERS = {
  "del_ahorro" => Crawlers::DelAhorroCrawler,
  "guadalajara" => Crawlers::GuadalajaraCrawler,
  "chedraui" => Crawlers::ChedrauiCrawler,
  "benavides" => Crawlers::BenavidesCrawler,
  "probemedic" => Crawlers::ProbemedicCrawler,
  "fesa" => Crawlers::FesaCrawler,
  "farmacias_abc" => Crawlers::FarmaciasAbcCrawler,
  "proasse" => Crawlers::ProasseCrawler,
  "farmacia_similares" => Crawlers::FarmaciaSimilaresCrawler,
  "farmacia_emergencias" => Crawlers::FarmaciaEmergenciasCrawler,
  "costco" => Crawlers::CostcoCrawler,
  "yza" => Crawlers::YzaCrawler,
  "heb" => Crawlers::HebCrawler,
  "farmalisto" => Crawlers::FarmalistoCrawler,
  "vida_farmacias" => Crawlers::VidaFarmaciasCrawler,
  "vitau" => Crawlers::VitauCrawler,
  "san_pablo" => Crawlers::SanPabloCrawler
}.freeze

Pharmacy.active.find_each do |pharmacy|
  crawler_class = CRAWLERS[pharmacy.slug]
  next unless crawler_class

  puts "=" * 70
  puts "[#{Time.current}] Starting crawl: #{pharmacy.name}"
  puts "=" * 70

  crawl_run = pharmacy.crawl_runs.create!(city: CITY, status: "pending")
  crawl_run.mark_running!

  begin
    count = crawler_class.new(pharmacy: pharmacy, crawl_run: crawl_run).call
    crawl_run.mark_succeeded!
    puts "[#{Time.current}] #{pharmacy.name}: #{count} listings persisted (crawl_run##{crawl_run.id})"
  rescue StandardError => e
    crawl_run.mark_failed!(e)
    puts "[#{Time.current}] #{pharmacy.name}: FAILED - #{e.class}: #{e.message}"
  end
end

puts "=" * 70
puts "DONE. Total raw_listings in DB: #{RawListing.count}"
puts "Nothing was sent to Claude - NameMapping/Medication/Offer tables untouched by this run."
puts "=" * 70

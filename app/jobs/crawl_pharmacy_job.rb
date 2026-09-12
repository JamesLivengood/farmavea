class CrawlPharmacyJob < ApplicationJob
  queue_as :crawling

  CRAWLER_CLASSES = {
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

  # Guadalajara is best-effort (see Crawlers::GuadalajaraCrawler) - failures there
  # must not raise and fail the whole daily job chain.
  retry_on Crawlers::BaseCrawler::CrawlError, wait: 5.minutes, attempts: 2

  # aggregate: whether to hand the crawled listings straight to
  # NormalizeAndBuildOffersJob, which turns them into the offers people actually
  # see. Without it a crawl refreshes the raw data and changes nothing on the site.
  #
  # This used to default to false because aggregation could reach the paid Claude
  # API, and an unattended run after a pharmacy redesign could produce thousands of
  # new names and a surprise bill. That risk now lives behind ALLOW_CLAUDE_API
  # (see MedicationNormalizer#use_claude?), which is unset in production - so the
  # nightly path runs the free tiers only and unmatched names wait for a manual
  # export. Aggregating nightly is what keeps displayed prices current.
  def perform(pharmacy_slug, city:, aggregate: false)
    pharmacy = Pharmacy.find_by!(slug: pharmacy_slug)
    crawler_class = CRAWLER_CLASSES.fetch(pharmacy_slug) { raise ArgumentError, "No crawler for #{pharmacy_slug}" }

    crawl_run = pharmacy.crawl_runs.create!(city: city, status: "pending")
    crawl_run.mark_running!

    begin
      crawler_class.new(pharmacy: pharmacy, crawl_run: crawl_run).call
      crawl_run.mark_succeeded!
      NormalizeAndBuildOffersJob.perform_later(crawl_run.id) if aggregate
    rescue StandardError => e
      crawl_run.mark_failed!(e)
      raise
    end
  end
end

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
  # NormalizeAndBuildOffersJob, which calls the paid Claude API.
  #
  # Defaults to FALSE so the nightly scheduled crawl only gathers raw data, which
  # costs nothing. Aggregation is run deliberately (script/aggregate_latest.rb)
  # rather than unattended: it's the only step that spends money, it has no
  # per-run cap, and a pharmacy redesign or crawler bug could turn one quiet night
  # into thousands of new names and a surprise bill.
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

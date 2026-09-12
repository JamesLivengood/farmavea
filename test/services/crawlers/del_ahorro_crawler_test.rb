require "test_helper"

module Crawlers
  # Del Ahorro is capped at ~300 products per run (its category pages are
  # WAF-blocked, so the crawler works through the sitemap). That cap only fills in
  # the ~4,400 product catalog if each run picks up where the last left off - a
  # regression here silently means the backlog never advances, which is exactly
  # what happened: one night's run of 274 products contained zero that the previous
  # run hadn't already captured.
  class DelAhorroCrawlerTest < ActiveSupport::TestCase
    # Stubs sitemap discovery so these tests don't hit the network.
    class FakeDelAhorro < DelAhorroCrawler
      def initialize(pharmacy:, crawl_run:, urls:)
        super(pharmacy: pharmacy, crawl_run: crawl_run)
        @urls = urls
      end

      private

      def discover_product_urls = @urls
      def known_medication_terms = []
    end

    def build(pharmacy, urls)
      FakeDelAhorro.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), urls: urls)
    end

    test "never-scraped products are prioritised over already-scraped ones" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      old = "https://www.fahorro.com/already-seen-100-mg-10-tabletas.html"
      fresh = "https://www.fahorro.com/never-seen-200-mg-20-tabletas.html"

      create_raw_listing(pharmacy: pharmacy, raw_name: "Already Seen", product_url: old,
        scraped_at: 3.days.ago)

      ordered = build(pharmacy, [ old, fresh ]).send(:prioritized_product_urls)

      assert_equal fresh, ordered.first,
        "a product never scraped before must come before one already captured"
    end

    test "among already-scraped products the stalest comes first" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      recent = "https://www.fahorro.com/recent-100-mg-10-tabletas.html"
      stale = "https://www.fahorro.com/stale-200-mg-20-tabletas.html"

      create_raw_listing(pharmacy: pharmacy, raw_name: "Recent", product_url: recent, scraped_at: 2.days.ago)
      create_raw_listing(pharmacy: pharmacy, raw_name: "Stale", product_url: stale, scraped_at: 30.days.ago)

      ordered = build(pharmacy, [ recent, stale ]).send(:prioritized_product_urls)

      assert_equal stale, ordered.first
    end

    test "products already scraped today are skipped entirely" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      done_today = "https://www.fahorro.com/done-today-100-mg-10-tabletas.html"
      pending = "https://www.fahorro.com/pending-200-mg-20-tabletas.html"

      create_raw_listing(pharmacy: pharmacy, raw_name: "Done Today", product_url: done_today,
        scraped_at: Time.current)

      ordered = build(pharmacy, [ done_today, pending ]).send(:prioritized_product_urls)

      assert_equal [ pending ], ordered,
        "re-scraping something already captured today wastes the run's capped budget"
    end

    test "consecutive runs advance through the catalog instead of repeating" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      urls = (1..10).map { |i| "https://www.fahorro.com/product-#{i}-100-mg-10-tabletas.html" }

      # Simulate a previous run that captured the first four, yesterday.
      urls.first(4).each do |url|
        create_raw_listing(pharmacy: pharmacy, raw_name: "Product #{url}", product_url: url,
          scraped_at: 1.day.ago)
      end

      next_batch = build(pharmacy, urls).send(:prioritized_product_urls).first(4)

      assert_empty(next_batch & urls.first(4),
        "the next run must move on to unseen products, not repeat the previous batch")
    end

    # Records what it scraped and advances its own clock, so the deadline can be
    # exercised without waiting 25 real minutes. Time.current is overridden rather
    # than slept through, keeping the test instant.
    class SlowDelAhorro < FakeDelAhorro
      attr_reader :batches_scraped

      def initialize(pharmacy:, crawl_run:, urls:, seconds_per_batch:)
        super(pharmacy: pharmacy, crawl_run: crawl_run, urls: urls)
        @seconds_per_batch = seconds_per_batch
        @batches_scraped = 0
        @elapsed = 0
        @started_at = Time.current
      end

      private

      # The crawler reads the clock to set and check its deadline; this makes time
      # pass only when a batch is "scraped".
      def current_time = @started_at + @elapsed

      def scrape_batch(url_batch)
        @batches_scraped += 1
        @elapsed += @seconds_per_batch
        url_batch.map { |url| { raw_name: "Producto #{url[-8..]}", price_cents: 1000, product_url: url } }
      end
    end

    # A run that never returns holds a browser open and degrades the site sharing its
    # machine; one production run sat at 0.4% CPU for 45 minutes and lost everything
    # when killed, because results are persisted only at the end.
    test "a run that exceeds its time limit stops and keeps what it already scraped" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      urls = (1..75).map { |i| "https://www.fahorro.com/producto-#{i}-100-mg-10-tabletas.html" }
      # 3 batches of 25; at 20 minutes each the deadline falls partway through.
      crawler = SlowDelAhorro.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy),
                                  urls: urls, seconds_per_batch: 20.minutes)

      count = crawler.call

      assert_equal 2, crawler.batches_scraped, "should stop once the deadline has passed"
      assert_equal 50, count, "the products scraped before the deadline must still be persisted"
      assert_equal 50, RawListing.where(pharmacy: pharmacy).count
    end

    test "a run that finishes within the limit scrapes everything" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      urls = (1..75).map { |i| "https://www.fahorro.com/producto-#{i}-100-mg-10-tabletas.html" }
      crawler = SlowDelAhorro.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy),
                                  urls: urls, seconds_per_batch: 1.second)

      count = crawler.call

      assert_equal 3, crawler.batches_scraped
      assert_equal 75, count
    end
  end
end

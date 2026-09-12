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

      # These tests cover the per-product path, so category scraping is stubbed out.
      # Returning empty puts it below MIN_CATEGORY_YIELD, which is what triggers the
      # per-product fallback being tested here - and that fallback is opt-in, so
      # these fakes enable it directly rather than depending on the environment.
      def scrape_categories = []

      def fetch_listings
        @deadline = current_time + MAX_RUN_DURATION
        scrape_products_individually
      end
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
      # 3 batches of 25. Each batch burns 60% of the whole budget, so the deadline
      # falls after the second - derived from the constant so a change to the run
      # budget does not silently turn this test into a no-op.
      crawler = SlowDelAhorro.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy),
                                  urls: urls, seconds_per_batch: DelAhorroCrawler::MAX_RUN_DURATION * 0.6)

      count = crawler.call

      assert_equal 2, crawler.batches_scraped, "should stop once the deadline has passed"
      assert_equal 50, count, "the products scraped before the deadline must still be persisted"
      assert_equal 50, RawListing.where(pharmacy: pharmacy).count
    end

    # Hangs on one specific URL, the way fahorro's dimenhidrinato page did - twice,
    # each time stalling the entire run until it was killed.
    class HangingDelAhorro < FakeDelAhorro
      def initialize(pharmacy:, crawl_run:, urls:, hang_on:)
        super(pharmacy: pharmacy, crawl_run: crawl_run, urls: urls)
        @hang_on = hang_on
      end

      private

      def new_browser = nil

      def scrape_product(url, _browser)
        sleep 30 if url == @hang_on # longer than the shortened timeout below
        { raw_name: "Producto", price_cents: 1000, product_url: url }
      end
    end

    test "one hung page costs a single product, not the whole run" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      urls = (1..5).map { |i| "https://www.fahorro.com/producto-#{i}-100-mg-10-tabletas.html" }
      crawler = HangingDelAhorro.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy),
                                     urls: urls, hang_on: urls[2])

      # A 1s timeout keeps the test fast; the constant is 45s in production.
      original = DelAhorroCrawler::PRODUCT_TIMEOUT
      DelAhorroCrawler.send(:remove_const, :PRODUCT_TIMEOUT)
      DelAhorroCrawler.const_set(:PRODUCT_TIMEOUT, 1)
      begin
        count = crawler.call

        assert_equal 4, count, "the other four products must still be scraped"
      ensure
        DelAhorroCrawler.send(:remove_const, :PRODUCT_TIMEOUT)
        DelAhorroCrawler.const_set(:PRODUCT_TIMEOUT, original)
      end
    end

    # Category pages carry name, price and URL on every tile - one page load yields
    # ~24 products rather than one render each. This became the primary path when the
    # sitemap went stale and started serving 404s for every product URL.
    class CategoryDelAhorro < DelAhorroCrawler
      def initialize(pharmacy:, crawl_run:, products:)
        super(pharmacy: pharmacy, crawl_run: crawl_run)
        @products = products
      end

      private

      def scrape_categories = @products

      def scrape_products_individually
        raise "must not fall back when categories produced enough products"
      end
    end

    test "category scraping is used and per-product scraping is skipped" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      products = (1..120).map do |i|
        { raw_name: "Producto #{i} 100 mg", price_cents: 1000 + i,
          presentation_text: nil, product_url: "https://www.fahorro.com/producto-#{i}.html" }
      end

      count = CategoryDelAhorro.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy),
                                    products: products).call

      assert_equal 120, count
      assert_equal 120, RawListing.where(pharmacy: pharmacy).count
    end

    test "a tile with no price is skipped rather than stored at zero" do
      crawler = DelAhorroCrawler.allocate
      tile = Struct.new(:html) do
        def css(selector)
          return [ Struct.new(:text).new("Omeprazol 20 mg") ] if selector == ".product-item-link"

          [] # no .price node, and no anchor
        end
      end.new(nil)

      assert_nil crawler.send(:extract_tile, tile)
    end

    test "a tile with a name and price becomes a listing" do
      crawler = DelAhorroCrawler.allocate
      node = Struct.new(:text)
      anchor = Struct.new(:href) do
        def attribute(_name) = href
      end
      tile = Struct.new(:x) do
        def css(selector)
          case selector
          when ".product-item-link" then [ Struct.new(:text).new("Omeprazol 20 mg 30 cápsulas") ]
          when ".price" then [ Struct.new(:text).new("$150.00") ]
          else [ Struct.new(:href) { def attribute(_) = "https://www.fahorro.com/omeprazol.html" }.new(nil) ]
          end
        end
      end.new(nil)

      listing = crawler.send(:extract_tile, tile)

      assert_equal "Omeprazol 20 mg 30 cápsulas", listing[:raw_name]
      assert_equal 15000, listing[:price_cents]
      assert_equal "https://www.fahorro.com/omeprazol.html", listing[:product_url]
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

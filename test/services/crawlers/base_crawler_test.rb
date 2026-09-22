require "test_helper"

module Crawlers
  class BaseCrawlerTest < ActiveSupport::TestCase
    # A minimal concrete crawler for testing BaseCrawler's shared logic
    # (persist/call/parse_price_cents) without touching Ferrum or any real network
    # call - #fetch_listings just returns canned data injected at construction time.
    class FakeCrawler < BaseCrawler
      def initialize(pharmacy:, crawl_run:, listings:)
        super(pharmacy: pharmacy, crawl_run: crawl_run)
        @canned_listings = listings
      end

      def call
        listings = fetch_listings
        persist(listings)
        listings.size
      end

      private

      def fetch_listings
        @canned_listings
      end
    end

    test "call persists valid listings and returns the count" do
      pharmacy = create_pharmacy
      crawl_run = create_crawl_run(pharmacy: pharmacy)
      listings = [
        { raw_name: "Ibuprofeno 400mg", price_cents: 5000, presentation_text: nil, product_url: "https://example.invalid/a" },
        { raw_name: "Paracetamol 500mg", price_cents: 3000, presentation_text: "20 tabs", product_url: "https://example.invalid/b" }
      ]

      count = FakeCrawler.new(pharmacy: pharmacy, crawl_run: crawl_run, listings: listings).call

      assert_equal 2, count
      assert_equal 2, RawListing.where(crawl_run: crawl_run).count
    end

    test "call silently skips a listing with a blank raw_name" do
      pharmacy = create_pharmacy
      crawl_run = create_crawl_run(pharmacy: pharmacy)
      listings = [
        { raw_name: "", price_cents: 5000, presentation_text: nil, product_url: nil },
        { raw_name: "Real Product", price_cents: 5000, presentation_text: nil, product_url: nil }
      ]

      FakeCrawler.new(pharmacy: pharmacy, crawl_run: crawl_run, listings: listings).call

      assert_equal 1, RawListing.where(crawl_run: crawl_run).count
      assert_equal "Real Product", RawListing.where(crawl_run: crawl_run).first.raw_name
    end

    test "call silently skips a listing with a zero or negative price" do
      pharmacy = create_pharmacy
      crawl_run = create_crawl_run(pharmacy: pharmacy)
      listings = [
        { raw_name: "Free Sample", price_cents: 0, presentation_text: nil, product_url: nil },
        { raw_name: "Negative Price Glitch", price_cents: -100, presentation_text: nil, product_url: nil },
        { raw_name: "Real Product", price_cents: 100, presentation_text: nil, product_url: nil }
      ]

      FakeCrawler.new(pharmacy: pharmacy, crawl_run: crawl_run, listings: listings).call

      assert_equal 1, RawListing.where(crawl_run: crawl_run).count
    end

    test "call strips leading/trailing whitespace from raw_name" do
      pharmacy = create_pharmacy
      crawl_run = create_crawl_run(pharmacy: pharmacy)
      listings = [ { raw_name: "  Padded Name  ", price_cents: 100, presentation_text: nil, product_url: nil } ]

      FakeCrawler.new(pharmacy: pharmacy, crawl_run: crawl_run, listings: listings).call

      assert_equal "Padded Name", RawListing.where(crawl_run: crawl_run).first.raw_name
    end

    test "call stores nil presentation_text as nil rather than an empty string" do
      pharmacy = create_pharmacy
      crawl_run = create_crawl_run(pharmacy: pharmacy)
      listings = [ { raw_name: "Product", price_cents: 100, presentation_text: "", product_url: nil } ]

      FakeCrawler.new(pharmacy: pharmacy, crawl_run: crawl_run, listings: listings).call

      assert_nil RawListing.where(crawl_run: crawl_run).first.presentation_text
    end

    test "call with zero valid listings persists nothing and does not error" do
      pharmacy = create_pharmacy
      crawl_run = create_crawl_run(pharmacy: pharmacy)

      count = FakeCrawler.new(pharmacy: pharmacy, crawl_run: crawl_run, listings: []).call

      assert_equal 0, count
      assert_equal 0, RawListing.where(crawl_run: crawl_run).count
    end

    test "parse_price_cents parses a plain peso amount" do
      assert_equal 12345, fake_crawler.send(:parse_price_cents, "$123.45")
    end

    test "parse_price_cents strips thousands separators" do
      assert_equal 123400, fake_crawler.send(:parse_price_cents, "MX$1,234.00")
    end

    test "parse_price_cents returns nil for blank input" do
      crawler = fake_crawler
      assert_nil crawler.send(:parse_price_cents, "")
      assert_nil crawler.send(:parse_price_cents, nil)
    end

    test "parse_price_cents returns nil when there are no digits at all" do
      assert_nil fake_crawler.send(:parse_price_cents, "Precio no disponible")
    end

    # The production container had chromium installed and still raised
    # Ferrum::BinaryNotFoundError, because Ferrum only auto-detects `chrome` /
    # `google-chrome` on PATH and Debian ships it as `chromium`. That failure was
    # silent for days - the nightly crawl just never produced anything.
    test "browser detection looks for the Debian chromium binary, not just Chrome" do
      assert_includes Crawlers::BaseCrawler::BROWSER_PATHS, "/usr/bin/chromium"
      assert_includes Crawlers::BaseCrawler::BROWSER_PATHS, "/usr/bin/google-chrome"
    end

    test "an explicit FERRUM_BROWSER_PATH wins over auto-detection" do
      original = ENV["FERRUM_BROWSER_PATH"]
      ENV["FERRUM_BROWSER_PATH"] = "/custom/browser"

      assert_equal "/custom/browser", fake_crawler.send(:detect_browser_path)
    ensure
      ENV["FERRUM_BROWSER_PATH"] = original
    end

    test "browser detection returns a path that exists on this machine" do
      original = ENV["FERRUM_BROWSER_PATH"]
      ENV.delete("FERRUM_BROWSER_PATH")

      path = fake_crawler.send(:detect_browser_path)
      # nil is acceptable (a machine with no browser); a non-existent path is not.
      assert(path.nil? || File.exist?(path), "detected #{path.inspect} but it doesn't exist")
    ensure
      ENV["FERRUM_BROWSER_PATH"] = original
    end

    # Net::HTTP.start has NO open timeout by default, so a connection that never
    # establishes hangs forever. Benavides sat "running" with zero listings for half
    # an hour at a time because of this, holding the worker and preventing every
    # pharmacy queued behind it from starting at all.
    test "outbound HTTP requests have both an open and a read timeout" do
      assert Crawlers::BaseCrawler::HTTP_OPEN_TIMEOUT.positive?
      assert Crawlers::BaseCrawler::HTTP_READ_TIMEOUT.positive?
    end

    test "no crawler calls Net::HTTP.start directly, bypassing the timeouts" do
      offenders = Dir[Rails.root.join("app/services/crawlers/*.rb")].reject do |path|
        File.basename(path) == "base_crawler.rb"
      end.select { |path| File.read(path).match?(/Net::HTTP\.start/) }

      assert_empty offenders.map { |p| File.basename(p) },
        "these crawlers bypass http_get and so have no connection timeout"
    end

    # Bot mitigation reads an outdated browser version as a bot signal in itself.
    # Farmalisto's Cloudflare started returning 403 to the pinned Chrome/124 while
    # letting Chrome/130+ through, and the crawler quietly returned nothing for over
    # a week. A stale version here is a real outage, not a cosmetic detail.
    test "the user agent claims a recent Chrome version" do
      version = Crawlers::BaseCrawler::USER_AGENT[%r{Chrome/(\d+)}, 1].to_i

      assert_operator version, :>=, 130,
        "sites have been observed blocking Chrome/124 and older - bump CHROME_VERSION"
    end

    test "the user agent is a single well-formed line" do
      ua = Crawlers::BaseCrawler::USER_AGENT

      assert_match(%r{\AMozilla/5\.0 .+ Chrome/\d+\.\d+\.\d+\.\d+ Safari/[\d.]+\z}, ua)
      assert_not_includes ua, "\n"
    end

    private

    def fake_crawler
      pharmacy = create_pharmacy
      FakeCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), listings: [])
    end
  end
end

require "test_helper"

module Crawlers
  class MagentoCategoryCrawlerTest < ActiveSupport::TestCase
    # Serves canned HTML per (category, page) so the shared Magento scraping logic
    # can be tested without any network access.
    class FakeMagentoCrawler < MagentoCategoryCrawler
      def initialize(pharmacy:, crawl_run:, pages:)
        super(pharmacy: pharmacy, crawl_run: crawl_run)
        @pages = pages # { "/category?p=1" => html, ... }
      end

      private

      def base_url = "https://example.invalid"

      def category_paths = @pages.keys.map { |k| k.split("?").first }.uniq

      def fetch_html(url)
        @pages[strip_page_size(url.delete_prefix(base_url))]
      end

      # The crawler asks for a larger grid via &product_list_limit; these fixtures
      # are keyed by path and page number only.
      def strip_page_size(path) = path.sub(/&product_list_limit=\d+/, "")
    end

    def product_html(name, price, href)
      <<~HTML
        <li class="product-item">
          <a class="product-item-link" href="#{href}">#{name}</a>
          <span data-price-type="finalPrice"><span class="price">$#{price}</span></span>
        </li>
      HTML
    end

    test "extracts products from a category page" do
      pharmacy = create_pharmacy
      pages = {
        "/dolor?p=1" => "<ul>#{product_html('Ibuprofeno 400mg', '50.00', 'https://example.invalid/ibu')}</ul>",
        "/dolor?p=2" => "<ul></ul>"
      }

      count = FakeMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), pages: pages).call

      assert_equal 1, count
      listing = RawListing.last
      assert_equal "Ibuprofeno 400mg", listing.raw_name
      assert_equal 5000, listing.price_cents
    end

    test "de-duplicates a product that appears in more than one category" do
      pharmacy = create_pharmacy
      shared = product_html("Naproxeno 500mg", "80.00", "https://example.invalid/naproxeno")
      pages = {
        "/dolor?p=1" => "<ul>#{shared}</ul>",
        "/dolor?p=2" => "<ul></ul>",
        "/reumatologia?p=1" => "<ul>#{shared}</ul>",
        "/reumatologia?p=2" => "<ul></ul>"
      }

      count = FakeMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), pages: pages).call

      assert_equal 1, count, "the same product listed under two categories must be stored once, not twice"
    end

    test "keeps genuinely distinct products from different categories" do
      pharmacy = create_pharmacy
      pages = {
        "/dolor?p=1" => "<ul>#{product_html('Ibuprofeno 400mg', '50.00', 'https://example.invalid/ibu')}</ul>",
        "/dolor?p=2" => "<ul></ul>",
        "/estomacales?p=1" => "<ul>#{product_html('Omeprazol 20mg', '60.00', 'https://example.invalid/omeprazol')}</ul>",
        "/estomacales?p=2" => "<ul></ul>"
      }

      count = FakeMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), pages: pages).call

      assert_equal 2, count
    end

    test "stops paginating a category once a page returns no products" do
      pharmacy = create_pharmacy
      pages = {
        "/dolor?p=1" => "<ul>#{product_html('A 1mg', '10.00', 'https://example.invalid/a')}</ul>",
        "/dolor?p=2" => "<ul></ul>",
        # Would be reached only if the crawler ignored the empty page 2 above.
        "/dolor?p=3" => "<ul>#{product_html('B 2mg', '20.00', 'https://example.invalid/b')}</ul>"
      }

      count = FakeMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), pages: pages).call

      assert_equal 1, count
    end

    test "skips a product with no parseable price" do
      pharmacy = create_pharmacy
      no_price = <<~HTML
        <li class="product-item">
          <a class="product-item-link" href="https://example.invalid/x">Sin Precio 1mg</a>
        </li>
      HTML
      pages = { "/dolor?p=1" => "<ul>#{no_price}</ul>", "/dolor?p=2" => "<ul></ul>" }

      count = FakeMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), pages: pages).call

      assert_equal 0, count
    end

    # Serves real pages but raises on one of them, the way a timeout or a dropped
    # connection does mid-crawl.
    class FlakyMagentoCrawler < FakeMagentoCrawler
      def initialize(pharmacy:, crawl_run:, pages:, fail_on:)
        super(pharmacy: pharmacy, crawl_run: crawl_run, pages: pages)
        @fail_on = fail_on
        @attempts = Hash.new(0)
      end

      attr_reader :attempts

      private

      def fetch_html(url)
        path = url.delete_prefix(base_url).sub(/&product_list_limit=\d+/, "")
        @attempts[path] += 1
        raise Net::ReadTimeout, "simulated" if path == @fail_on

        super
      end
    end

    # The bug this guards: a failed fetch returned blank, the loop read that as "no
    # more products", and every product on the later pages was reported as gone.
    # Observed on fesa and farmacias_abc - 2,219 real products looked discontinued.
    test "a page that keeps failing raises instead of silently truncating the catalogue" do
      pharmacy = create_pharmacy
      pages = {
        "/dolor?p=1" => "<ul>#{product_html('Paracetamol 500mg', '20.00', 'https://example.invalid/a')}</ul>",
        "/dolor?p=2" => "<ul>#{product_html('Ibuprofeno 400mg', '30.00', 'https://example.invalid/b')}</ul>",
        "/dolor?p=3" => "<ul></ul>"
      }
      crawler = FlakyMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy),
                                        pages: pages, fail_on: "/dolor?p=2")

      error = assert_raises(BaseCrawler::CrawlError) { crawler.call }

      assert_match(/page 2 failed after 3 attempts/, error.message)
      assert_equal 3, crawler.attempts["/dolor?p=2"], "should retry before giving up"
    end

    test "a genuinely empty page still ends the category normally" do
      pharmacy = create_pharmacy
      pages = {
        "/dolor?p=1" => "<ul>#{product_html('Paracetamol 500mg', '20.00', 'https://example.invalid/a')}</ul>",
        "/dolor?p=2" => "<ul></ul>"
      }

      count = FakeMagentoCrawler.new(pharmacy: pharmacy, crawl_run: create_crawl_run(pharmacy: pharmacy), pages: pages).call

      assert_equal 1, count
    end
  end
end

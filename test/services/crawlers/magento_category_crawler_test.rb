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
        @pages[url.delete_prefix(base_url)]
      end
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
  end
end

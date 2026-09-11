require "net/http"
require "nokogiri"

module Crawlers
  # Shared logic for Mexican pharmacy sites built on stock Magento (Luma theme),
  # confirmed to render category/product-grid pages server-side with no bot
  # mitigation - unlike Farmacia del Ahorro, which needs a sitemap-based workaround
  # because its category pages are JS-widget-driven and WAF-blocked. These sites can
  # be crawled directly with plain HTTP against their category listing pages.
  #
  # Subclasses implement #base_url and #category_paths (one or more medication
  # category/subcategory paths - Magento's top-level "Medicamentos" nav entry is
  # often just a CMS landing page, not a real paginated grid, so the real
  # subcategory paths must be discovered per site).
  class MagentoCategoryCrawler < BaseCrawler
    # 40 was binding rather than protective: fesa stopped at exactly 40 pages x 20
    # items = 800 and reported the remaining 306 known products as disappeared. The
    # loop exits on its own when a page is empty, so this is only a runaway guard.
    MAX_PAGES_PER_CATEGORY = ENV.fetch("MAGENTO_MAX_PAGES", 150).to_i

    private

    def fetch_listings
      # De-duplicate by product_url across categories: these sites legitimately list
      # the same product under several categories (e.g. a painkiller under both
      # "dolor" and "especialidades-reumatologia"), and without this each appearance
      # is stored as its own RawListing - measured at ~5.4x inflation on Benavides'
      # 23 categories before this was added.
      category_paths.flat_map { |path| scrape_category(path) }
                    .uniq { |item| item[:product_url] || item[:raw_name] }
    end

    PAGE_RETRIES = 3

    def scrape_category(path)
      (1..MAX_PAGES_PER_CATEGORY).each_with_object([]) do |page_number, results|
        html = fetch_category_page(path, page_number)
        # A genuinely empty page means the category is exhausted; a failed fetch
        # raises instead, so a network blip is never mistaken for the end.
        break results if html.blank?

        doc = Nokogiri::HTML(html)
        # li.product-item wraps div.product-item-info on all three confirmed sites -
        # selecting both would double-count every product (the inner div also
        # matches), so use only the outer wrapper.
        items = doc.css("li.product-item")
        break results if items.empty?

        results.concat(items.filter_map { |item| extract_listing(item) })
      end
    end

    # Retries before accepting a failure. Previously any error here returned [] for
    # the whole category, which silently reported every product in it as gone.
    def fetch_category_page(path, page_number)
      last_error = nil

      PAGE_RETRIES.times do |attempt|
        sleep(2**attempt) if attempt.positive?
        begin
          return fetch_html("#{base_url}#{path}?p=#{page_number}")
        rescue StandardError => e
          last_error = "#{e.class}: #{e.message}"
        end
      end

      raise CrawlError,
            "#{self.class.name}: #{path} page #{page_number} failed after #{PAGE_RETRIES} attempts (#{last_error})."
    end

    def fetch_html(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return nil unless response.is_a?(Net::HTTPSuccess)
      response.body
    end

    def extract_listing(item)
      link_el = item.at_css("a.product-item-link")
      name = link_el&.text&.strip
      return nil if name.blank?

      # data-price-type='finalPrice' is Magento's own resolved payable price
      # (already accounts for any active discount) - same convention confirmed
      # reliable on Del Ahorro's product pages.
      price_text = item.at_css("span[data-price-type='finalPrice'] span.price")&.text
      price_cents = parse_price_cents(price_text)
      return nil if price_cents.nil?

      {
        raw_name: name,
        price_cents: price_cents,
        presentation_text: nil,
        product_url: link_el["href"]
      }
    end
  end
end

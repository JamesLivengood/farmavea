require "net/http"
require "json"

module Crawlers
  # Chedraui (chedraui.com.mx) runs on VTEX IO. Unlike the other two pharmacies, no
  # headless browser is needed at all: category pages are server-rendered with the
  # full product catalog embedded as an Apollo normalized-cache JSON blob in a
  # <template data-varname="__STATE__"> tag - plain HTTP + JSON parsing is enough,
  # and no bot mitigation was observed blocking it.
  #
  # Deliberate policy note: chedraui.com.mx/robots.txt explicitly disallows
  # crawling /Farmacia/. This crawler proceeds anyway per an explicit, informed
  # decision - this is not an oversight, see project history for context.
  class ChedrauiCrawler < BaseCrawler
    BASE_URL = "https://www.chedraui.com.mx"
    CATEGORY_PATH = "/Farmacia/Medicamentos/"
    MAX_PAGES = ENV.fetch("CHEDRAUI_MAX_PAGES", 60).to_i

    private

    def fetch_listings
      (1..MAX_PAGES).each_with_object([]) do |page_number, results|
        products = fetch_page(page_number)
        break results if products.empty?

        results.concat(products)
      end
    end

    def fetch_page(page_number)
      url = "#{BASE_URL}#{CATEGORY_PATH}?page=#{page_number}"
      html = fetch_html(url)
      return [] if html.blank?

      state = extract_state_json(html)
      return [] if state.nil?

      product_keys(state).filter_map { |key| resolve_product(state, key) }
    rescue StandardError => e
      Rails.logger.warn("[ChedrauiCrawler] page #{page_number} failed: #{e.message}")
      []
    end

    def fetch_html(url)
      response = http_get(url)
      return nil unless response.is_a?(Net::HTTPSuccess)
      response.body
    end

    # The catalog is embedded as <template data-varname="__STATE__"><script>{...}</script></template> -
    # an Apollo normalized cache (flat object of "Type:id" keys referencing each other).
    def extract_state_json(html)
      match = html.match(%r{data-varname="__STATE__">\s*<script>(.*?)</script>}m)
      return nil unless match
      JSON.parse(match[1])
    rescue JSON::ParserError => e
      Rails.logger.warn("[ChedrauiCrawler] could not parse __STATE__ JSON: #{e.message}")
      nil
    end

    # Only top-level "Product:sp-..." keys, not the nested "Product:sp-....specificationGroups.0"
    # sub-object keys that also start with the same prefix.
    def product_keys(state)
      state.keys.select { |key| key.start_with?("Product:sp-") && !key.include?(".") }
    end

    def resolve_product(state, key)
      product = state[key]
      return nil unless product

      name = product["productName"]
      return nil if name.blank?

      price_cents = resolve_price_cents(state, key)
      return nil if price_cents.nil?

      link = product["link"]

      {
        raw_name: name,
        price_cents: price_cents,
        presentation_text: nil,
        product_url: link ? "#{BASE_URL}#{link}" : nil
      }
    end

    # priceRange is stored as a reference ({"id" => "$Product:...priceRange"}) rather
    # than inline, per Apollo's normalized-cache format - has to be dereferenced twice
    # (priceRange -> sellingPrice -> {lowPrice, highPrice}) to reach the actual number.
    def resolve_price_cents(state, product_key)
      price_range_ref = state.dig(product_key, "priceRange")
      return nil unless price_range_ref.is_a?(Hash)

      price_range = state[price_range_ref["id"]]
      return nil unless price_range

      selling_price_ref = price_range["sellingPrice"]
      return nil unless selling_price_ref.is_a?(Hash)

      selling_price = state[selling_price_ref["id"]]
      low_price = selling_price&.dig("lowPrice")
      return nil if low_price.blank?

      (low_price.to_f * 100).round
    end
  end
end

require "net/http"
require "json"

module Crawlers
  # Costco México (costco.com.mx) runs SAP Commerce Cloud (Hybris) with a fully
  # client-side Spartacus/Angular storefront - no server-rendered HTML at all. The
  # storefront itself calls a public, unauthenticated JSON API
  # (SAP's older "WebServices" REST API, confirmed at /rest/v2/mexico/..., not the
  # newer OCC API path) - no headless browser needed for the actual crawl, and no
  # bot mitigation observed (plain HTTP with no cookies/session gets the identical
  # response Ferrum does).
  #
  # Costco is a warehouse club, not a dedicated pharmacy - "Farmacia" (cos_20.1.16)
  # is a small category (~103 products) covering OTC medications, not a full catalog.
  class CostcoCrawler < BaseCrawler
    BASE_URL = "https://www.costco.com.mx"
    CATEGORY_CODE = "cos_20.1.16"
    PAGE_SIZE = 100
    MAX_PAGES = ENV.fetch("COSTCO_MAX_PAGES", 20).to_i

    private

    def fetch_listings
      (0...MAX_PAGES).each_with_object([]) do |page_number, results|
        products = fetch_page(page_number)
        break results if products.empty?

        results.concat(products.filter_map { |product| extract_listing(product) })
      end
    end

    def fetch_page(page_number)
      url = "#{BASE_URL}/rest/v2/mexico/products/search?fields=DEFAULT&query=&pageSize=#{PAGE_SIZE}" \
            "&category=#{CATEGORY_CODE}&currentPage=#{page_number}&lang=es_MX&curr=MXN"
      body = fetch_json(url)
      return [] if body.nil?

      body["products"] || []
    rescue StandardError => e
      Rails.logger.warn("[CostcoCrawler] page #{page_number} failed: #{e.message}")
      []
    end

    def fetch_json(url)
      response = http_get(url)
      return nil unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      Rails.logger.warn("[CostcoCrawler] could not parse JSON from #{url}: #{e.message}")
      nil
    end

    def extract_listing(product)
      return nil unless product["purchasable"]
      # stockLevelStatus is a genuine in-stock signal from the retailer's own system -
      # something Del Ahorro/Guadalajara couldn't reliably provide. Skip out-of-stock
      # items rather than store a stale/unbuyable price.
      return nil unless product.dig("stock", "stockLevelStatus") == "inStock"

      name = product["name"]
      return nil if name.blank?

      price_cents = product.dig("price", "intValue")
      return nil if price_cents.blank? || price_cents.to_i <= 0

      url = product["url"]

      # fields=DEFAULT (used above, lighter than FULL) does not include a
      # "description" field at all, so no presentation_text is available here -
      # not worth the heavier FULL payload just for a field that mostly repeats
      # the product name anyway (confirmed by inspecting real FULL responses).
      {
        raw_name: name,
        price_cents: price_cents.to_i,
        presentation_text: nil,
        product_url: url ? "#{BASE_URL}#{url}" : nil
      }
    end
  end
end

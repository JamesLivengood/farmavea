require "net/http"
require "json"

module Crawlers
  # Farmacia Similares / Dr. Simi (farmaciasdesimilares.com), also VTEX IO like
  # Chedraui - same Apollo normalized-cache __STATE__ JSON approach, no headless
  # browser needed. One structural difference from Chedraui: product keys are
  # slug-based ("Product:amoxicilina_ac_cla_875mg_10tab") rather than numeric-ID-
  # based ("Product:sp-{id}"), so top-level products are identified by the presence
  # of a "productName" field rather than a fixed key prefix.
  class FarmaciaSimilaresCrawler < BaseCrawler
    BASE_URL = "https://www.farmaciasdesimilares.com"
    CATEGORY_PATH = "/medicamentos"
    MAX_PAGES = ENV.fetch("SIMILARES_MAX_PAGES", 40).to_i

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
      Rails.logger.warn("[FarmaciaSimilaresCrawler] page #{page_number} failed: #{e.message}")
      []
    end

    def fetch_html(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return nil unless response.is_a?(Net::HTTPSuccess)
      response.body
    end

    def extract_state_json(html)
      match = html.match(%r{data-varname="__STATE__">\s*<script>(.*?)</script>}m)
      return nil unless match
      JSON.parse(match[1])
    rescue JSON::ParserError => e
      Rails.logger.warn("[FarmaciaSimilaresCrawler] could not parse __STATE__ JSON: #{e.message}")
      nil
    end

    # Top-level product objects are identified by having a "productName" field -
    # unlike Chedraui's fixed "Product:sp-" numeric-ID prefix, this store's product
    # keys are slugs (e.g. "Product:amoxicilina_ac_cla_875mg_10tab"), and nested
    # sub-object keys (specificationGroups, items(...), etc.) don't carry that field.
    def product_keys(state)
      state.keys.select { |key| key.start_with?("Product:") && state[key].is_a?(Hash) && state[key]["productName"] }
    end

    def resolve_product(state, key)
      product = state[key]
      name = product["productName"]
      return nil if name.blank?

      price_cents = resolve_price_cents(state, key)
      return nil if price_cents.nil?

      {
        raw_name: name,
        price_cents: price_cents,
        presentation_text: nil,
        product_url: product["link"]
      }
    end

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

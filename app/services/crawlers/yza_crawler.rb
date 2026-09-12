require "net/http"
require "nokogiri"

module Crawlers
  # YZA Farmacias (yza.mx) is Salesforce Commerce Cloud/SFRA, same platform family
  # as Farmacias Guadalajara - same product-tile markup, but pagination differs:
  # ?page=N on the category page doesn't work (always returns the same first page).
  # Real pagination is via the SFRA grid's own AJAX endpoint (Search-UpdateGrid),
  # confirmed callable directly with plain HTTP (no cookies/session, no Ferrum
  # needed at all) - a public, unauthenticated grid-fragment endpoint.
  #
  # Confirmed NOT a hard location gate: the category page renders a real national
  # catalog with real prices before any postal code is entered - the optional
  # postal-code widget only refines delivery availability afterward.
  class YzaCrawler < BaseCrawler
    BASE_URL = "https://www.yza.mx"
    GRID_PATH = "/on/demandware.store/Sites-YzaMexico-Site/es_MX/Search-UpdateGrid"
    CATEGORY_ID = "medicamentos"
    PAGE_SIZE = 18
    MAX_PAGES = ENV.fetch("YZA_MAX_PAGES", 300).to_i

    private

    def fetch_listings
      (0...MAX_PAGES).each_with_object([]) do |page_index, results|
        start = page_index * PAGE_SIZE
        html = fetch_grid_page(start)
        break results if html.blank?

        doc = Nokogiri::HTML(html)
        tiles = doc.css(".product-tile")
        break results if tiles.empty?

        results.concat(tiles.filter_map { |tile| extract_listing(tile) })
      end
    end

    def fetch_grid_page(start)
      url = "#{BASE_URL}#{GRID_PATH}?cgid=#{CATEGORY_ID}&start=#{start}&sz=#{PAGE_SIZE}"
      response = http_get(url)
      return nil unless response.is_a?(Net::HTTPSuccess)
      response.body
    rescue StandardError => e
      Rails.logger.warn("[YzaCrawler] grid start=#{start} failed: #{e.message}")
      nil
    end

    def extract_listing(tile)
      link_el = tile.at_css(".pdp-link a.link, a.pdp-link")
      name = link_el&.text&.strip
      return nil if name.blank?

      # .price .sales .value carries the final/payable price in a `content`
      # attribute - some tiles have content="null" (price unavailable/out of
      # stock), which parse_price_cents naturally rejects since "null" has no
      # digits to extract.
      price_value = tile.at_css(".price .sales .value")&.attribute("content")&.value
      price_cents = parse_price_cents(price_value)
      return nil if price_cents.nil?

      href = link_el["href"]

      {
        raw_name: name,
        price_cents: price_cents,
        presentation_text: nil,
        product_url: href ? URI.join(BASE_URL, href).to_s : nil
      }
    end
  end
end

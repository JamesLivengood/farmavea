require "net/http"
require "nokogiri"

module Crawlers
  # Farmalisto (farmalisto.com.mx) is a server-rendered PrestaShop store - no
  # browser/JS execution needed at all. Cloudflare fronts the site with
  # header-based bot detection only (blocks bare/minimal-header requests with a
  # 403 page, no JS challenge) - a realistic User-Agent plus standard Accept/
  # Accept-Language headers is enough to pass consistently.
  class FarmalistoCrawler < BaseCrawler
    BASE_URL = "https://farmalisto.com.mx"
    SEARCH_PATH = "/buscar"
    RESULTS_PER_PAGE = 20
    MAX_PAGES = ENV.fetch("FARMALISTO_MAX_PAGES", 50).to_i

    # No single "all medications" category/search term is exposed cleanly, so we
    # search across common medication categories/terms and de-duplicate by URL.
    # Not exhaustive, but covers the bulk of the OTC/prescription catalog without
    # needing PrestaShop's numeric category-ID slugs (unresolved during
    # investigation - bare category slugs like /analgesicos 404 without one).
    SEARCH_TERMS = %w[
      analgesico antibiotico antialergico antigripal gastritis
      hipertension diabetes colesterol antidepresivo ansiolitico
      anticonceptivo dermatologico vitamina antiinflamatorio
    ].freeze

    private

    def fetch_listings
      SEARCH_TERMS.flat_map { |term| scrape_search(term) }.uniq { |item| item[:product_url] }
    end

    def scrape_search(term)
      (1..MAX_PAGES).each_with_object([]) do |page_number, results|
        html = fetch_html(term, page_number)
        break results if html.blank?

        doc = Nokogiri::HTML(html)
        cards = doc.css("article.product-miniature")
        break results if cards.empty?

        results.concat(cards.filter_map { |card| extract_listing(card) })
      end
    rescue StandardError => e
      Rails.logger.warn("[FarmalistoCrawler] search #{term} failed: #{e.message}")
      []
    end

    def fetch_html(term, page_number)
      url = "#{BASE_URL}#{SEARCH_PATH}?controller=search&order=product.position.desc" \
            "&s=#{CGI.escape(term)}&page=#{page_number}"
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
      request["Accept-Language"] = "es-MX,es;q=0.9,en;q=0.8"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return nil unless response.is_a?(Net::HTTPSuccess)
      response.body
    end

    def extract_listing(card)
      # Out-of-stock products carry an "out-of-stock disabled" add-to-cart button
      # instead of a real one - skip rather than store a price that can't be
      # purchased.
      return nil if card.at_css("a.add-to-cart.out-of-stock")

      link_el = card.at_css(".product-title a")
      name = link_el&.text&.strip
      return nil if name.blank?

      price_text = card.at_css(".product-price-and-shipping span.price")&.text
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

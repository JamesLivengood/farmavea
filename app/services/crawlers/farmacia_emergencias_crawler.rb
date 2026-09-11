require "net/http"
require "openssl"
require "nokogiri"

module Crawlers
  # Farmacia Emergencias (farmaciaemergencias.com.mx), WordPress/WooCommerce with
  # the Martfury theme. Server-rendered category pages, no bot mitigation, but the
  # site's SSL certificate chain is incomplete (self-signed intermediate) - requires
  # relaxed certificate verification to connect at all.
  class FarmaciaEmergenciasCrawler < BaseCrawler
    BASE_URL = "https://farmaciaemergencias.com.mx"
    CATEGORY_PATHS = %w[/patente/ /generico/].freeze
    MAX_PAGES_PER_CATEGORY = ENV.fetch("EMERGENCIAS_MAX_PAGES", 40).to_i

    private

    def fetch_listings
      # Same product can appear in more than one category - keep one listing per
      # product rather than one per (product, category) pair.
      CATEGORY_PATHS.flat_map { |path| scrape_category(path) }
                    .uniq { |item| item[:product_url] || item[:raw_name] }
    end

    def scrape_category(path)
      (1..MAX_PAGES_PER_CATEGORY).each_with_object([]) do |page_number, results|
        url = page_number == 1 ? "#{BASE_URL}#{path}" : "#{BASE_URL}#{path}page/#{page_number}/"
        html = fetch_html(url)
        break results if html.blank?

        doc = Nokogiri::HTML(html)
        items = doc.css("li.product .product-inner")
        break results if items.empty?

        results.concat(items.filter_map { |item| extract_listing(item) })
      end
    rescue StandardError => e
      Rails.logger.warn("[FarmaciaEmergenciasCrawler] category #{path} failed: #{e.message}")
      []
    end

    def fetch_html(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
        http.request(request)
      end
      return nil unless response.is_a?(Net::HTTPSuccess)
      response.body
    end

    def extract_listing(item)
      link_el = item.at_css("h2.woo-loop-product__title a")
      name = link_el&.text&.strip
      return nil if name.blank?

      # Sale-priced items wrap the payable price in <ins>, regular-priced items
      # don't have an <ins>/<del> split at all - prefer <ins> when present.
      price_text = item.at_css(".mf-product-price-box .price ins .woocommerce-Price-amount, .mf-product-price-box .price .woocommerce-Price-amount")&.text
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

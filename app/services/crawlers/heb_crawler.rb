require "net/http"
require "json"

module Crawlers
  # HEB México (heb.com.mx) is a Next.js app with no server-rendered product data
  # (App Router, fully client-rendered) - but the app itself calls a public,
  # unauthenticated REST API at /api/categories/{slug} for category browsing.
  #
  # Bot mitigation gotcha (Imperva Incapsula): a generic "Mozilla/5.0" or any
  # scripted-looking User-Agent gets a 403 challenge page, and - unusually -
  # headless Chrome via Ferrum is blocked too. A REALISTIC FULL desktop Chrome UA
  # string via plain HTTP is what actually passes (confirmed repeatedly), which is
  # why this crawler intentionally overrides BaseCrawler::USER_AGENT with a more
  # complete/current one rather than reusing the shared constant.
  class HebCrawler < BaseCrawler
    BASE_URL = "https://www.heb.com.mx"
    CATEGORY_SLUG = "farmacia"
    HITS_PER_PAGE = 48
    MAX_PAGES = ENV.fetch("HEB_MAX_PAGES", 200).to_i

    REALISTIC_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                            "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private

    def fetch_listings
      (1..MAX_PAGES).each_with_object([]) do |page_number, results|
        products = fetch_page(page_number)
        break results if products.empty?

        results.concat(products.filter_map { |product| extract_listing(product) })
      end
    end

    def fetch_page(page_number)
      url = "#{BASE_URL}/api/categories/#{CATEGORY_SLUG}?page=#{page_number}&hitsPerPage=#{HITS_PER_PAGE}"
      body = fetch_json(url)
      return [] if body.nil?

      body["products"] || []
    rescue StandardError => e
      Rails.logger.warn("[HebCrawler] page #{page_number} failed: #{e.message}")
      []
    end

    def fetch_json(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = REALISTIC_USER_AGENT
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return nil unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      Rails.logger.warn("[HebCrawler] could not parse JSON from #{url}: #{e.message}")
      nil
    end

    def extract_listing(product)
      return nil unless product["isActive"]

      name = product["name"]
      return nil if name.blank?

      price_value = product.dig("price", "basePrice")
      return nil if price_value.blank? || price_value.to_f <= 0

      slug = product["slug"]

      {
        raw_name: name,
        price_cents: (price_value.to_f * 100).round,
        presentation_text: nil,
        product_url: slug ? "#{BASE_URL}#{slug}" : nil
      }
    end
  end
end

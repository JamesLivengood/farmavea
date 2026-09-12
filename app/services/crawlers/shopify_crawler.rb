require "net/http"
require "json"

module Crawlers
  # Shared logic for Mexican pharmacy sites built on Shopify. Shopify exposes a
  # public, unauthenticated JSON catalog feed at /products.json (site-wide) or
  # /collections/{handle}/products.json (scoped to one collection) - no headless
  # browser needed at all, and no bot mitigation observed on the sites using it.
  #
  # Subclasses set PRODUCTS_JSON_PATH to either the site-wide feed or a specific
  # collection's feed, depending on whether the pharmacy has a working scoped
  # collection endpoint (some Shopify "Search & Discovery" filtered collections
  # return empty via the classic JSON endpoint even though their HTML page shows
  # products - in that case fall back to the site-wide feed and filter in Ruby).
  class ShopifyCrawler < BaseCrawler
    PRODUCTS_PER_PAGE = 30
    MAX_PAGES = ENV.fetch("SHOPIFY_MAX_PAGES", 200).to_i

    private

    # A transient failure must not look like the end of the catalogue. Retry a failed
    # page before believing it, and raise rather than silently returning a partial
    # catalogue: a short crawl reports every missing product as "disappeared", which
    # is worse than a visible failure. Observed on farmacias_abc, where one bad page
    # at ~60 truncated the run and made 2,219 real products look discontinued.
    PAGE_RETRIES = 4
    # farmacias_abc starts refusing requests around page 60 when pages are fetched
    # back to back, then serves the same page fine on its own. That is rate limiting,
    # so pace the requests rather than only retrying after being refused.
    DELAY_BETWEEN_PAGES = 0.4

    def fetch_listings
      (1..MAX_PAGES).each_with_object([]) do |page_number, results|
        sleep(DELAY_BETWEEN_PAGES) if page_number > 1
        products = fetch_page(page_number)
        break results if products.empty?

        results.concat(products.filter_map { |product| extract_listing(product) })
      end
    end

    # Returns [] ONLY when the site genuinely reports no more products.
    def fetch_page(page_number)
      url = "#{base_url}#{products_json_path}?page=#{page_number}&limit=#{PRODUCTS_PER_PAGE}"

      last_error = nil
      PAGE_RETRIES.times do |attempt|
        # 3s, 9s, 27s - a throttle needs far longer to clear than a dropped
        # connection, and the earlier 1s/2s backoff was too short to outlast one.
        sleep(3**attempt) if attempt.positive?
        begin
          body = fetch_json(url)
          return body["products"] || [] unless body.nil?

          last_error = "no parseable body"
        rescue StandardError => e
          last_error = "#{e.class}: #{e.message}"
        end
      end

      raise CrawlError,
            "#{self.class.name}: page #{page_number} failed after #{PAGE_RETRIES} attempts (#{last_error}). " \
            "Stopping rather than reporting the rest of the catalogue as missing."
    end

    def fetch_json(url)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      unless response.is_a?(Net::HTTPSuccess)
        # Named in the error so a throttle (429) is distinguishable from a real
        # missing page - "no parseable body" said nothing about which had happened.
        raise CrawlError, "HTTP #{response.code} from #{url}"
      end
      JSON.parse(response.body)
    rescue JSON::ParserError => e
      Rails.logger.warn("[#{self.class.name}] could not parse JSON from #{url}: #{e.message}")
      nil
    end

    def extract_listing(product)
      return nil unless medication_product?(product)

      name = product["title"]
      return nil if name.blank?

      variant = product["variants"]&.first
      return nil unless variant

      price_cents = (variant["price"].to_f * 100).round
      return nil if price_cents <= 0

      {
        raw_name: name,
        price_cents: price_cents,
        presentation_text: nil,
        product_url: "#{base_url}/products/#{product['handle']}",
        requires_prescription: requires_prescription?(product)
      }
    end

    # Subclasses override to scope results when using the site-wide feed instead of
    # a medications-specific collection (e.g. filtering by product_type or title
    # keywords) - default is "everything in the feed is in scope."
    def medication_product?(_product)
      true
    end

    # Confirmed on Farmacias ABC: the "receta" tag marks prescription-required
    # products. Not confirmed present on every Shopify pharmacy site (e.g. Proasse's
    # sampled products had empty tags) - returns nil (unknown) rather than false
    # when no tags are present at all, so we don't assert "not prescription" without
    # evidence either way.
    def requires_prescription?(product)
      tags = product["tags"]
      return nil if tags.blank?
      tags.any? { |tag| tag.to_s.casecmp("receta").zero? }
    end
  end
end

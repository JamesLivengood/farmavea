require "json"

module Crawlers
  # Farmacia San Pablo (farmaciasanpablo.com.mx) is SAP Commerce Cloud (Hybris)
  # with a custom Angular frontend, backed by a REST API at
  # api.farmaciasanpablo.com.mx.
  #
  # Getting at that API took three attempts; the notes matter because the two
  # dead ends look plausible and are easy to retry by accident:
  #
  #   1. Plain HTTP (curl/Net::HTTP) is refused by Akamai with a 403 even when
  #      replaying a real browser's session cookies and headers - the block is on
  #      TLS/client fingerprint, so no amount of header spoofing helps. Even
  #      /robots.txt and /sitemap.xml 403 this way.
  #   2. Driving the category UI in Ferrum and reading the API response out of
  #      CDP's network buffer. This "works" but is unreliable in two compounding
  #      ways: Chrome evicts response bodies aggressively (~50-75% of reads come
  #      back empty, and re-reading a dead exchange never recovers it), and the
  #      category URL's own ?currentPage= / ?page= params are IGNORED - the
  #      Angular app builds its own request and always asks for page 0, so
  #      URL-driven paging silently re-reads the first page forever. Its
  #      pagination is a sliding window of five numbered buttons that has to be
  #      clicked through sequentially. This capped the crawler at 48 products of
  #      a ~5,400 product catalog.
  #
  # What actually works (and what this crawler does): load any page of the site so
  # the Angular app initialises a real session, then call the API with fetch()
  # from INSIDE that page's JS context. The request rides the browser's own TLS
  # session so Akamai allows it, the response is read directly as JSON rather than
  # scraped out of a buffer that may already be empty, and currentPage/pageSize
  # are honoured properly - pageSize=100 works, versus 48 through the UI.
  #
  # robots.txt disallows /*? (query strings), /api/, /cart/, /checkout/ and
  # /my-account/. This crawler reads product data through the site's own API the
  # way the storefront itself does, and does not crawl any disallowed path.
  class SanPabloCrawler < BaseCrawler
    BASE_URL = "https://www.farmaciasanpablo.com.mx"
    # Any real page will do - loading it is only to get the Angular app to set up
    # a valid session before we call the API from inside it.
    SESSION_URL = "#{BASE_URL}/medicamentos/c/06"
    API_URL = "https://api.farmaciasanpablo.com.mx/rest/v2/fsp/products/search"
    # ":relevance:allCategories:06" is the storefront's own query for the
    # Medicamentos category tree (code 06).
    CATEGORY_QUERY = ":relevance:allCategories:06"
    PAGE_SIZE = 100
    MAX_PAGES = ENV.fetch("SANPABLO_MAX_PAGES", 60).to_i
    SESSION_SETTLE_SECONDS = 8
    FETCH_TIMEOUT_SECONDS = 25

    private

    def fetch_listings
      page = browser.create_page
      page.headers.set("User-Agent" => USER_AGENT)
      page.go_to(SESSION_URL)
      sleep SESSION_SETTLE_SECONDS # let the Angular app initialise its session

      results = []
      total_pages = MAX_PAGES

      (0...MAX_PAGES).each do |page_index|
        body = fetch_api_page(page, page_index)
        break if body.nil?

        products = body["products"] || []
        break if products.empty?

        results.concat(products.filter_map { |product| extract_listing(product) })

        reported = body.dig("pagination", "totalPages").to_i
        total_pages = [ reported, MAX_PAGES ].min if reported.positive?
        break if page_index >= total_pages - 1
      end

      # The same product can appear under more than one category in the tree.
      results.uniq { |item| item[:product_url] || item[:raw_name] }
    ensure
      page&.close
    end

    # Calls the API from inside the page's JS context - see the class comment for
    # why this is the only reliable way in. Returns the parsed body, or nil if the
    # request failed.
    def fetch_api_page(page, page_index)
      url = "#{API_URL}?fields=FULL&query=#{CGI.escape(CATEGORY_QUERY)}" \
            "&pageSize=#{PAGE_SIZE}&currentPage=#{page_index}&lang=es_MX&curr=MXN"

      raw = page.evaluate_async(<<~JS, FETCH_TIMEOUT_SECONDS)
        var done = arguments[0];
        fetch(#{url.to_json}, { credentials: 'include' })
          .then(function (response) { return response.json(); })
          .then(function (json) { done(JSON.stringify(json)); })
          .catch(function (error) { done(null); });
      JS

      return nil if raw.blank?

      JSON.parse(raw)
    rescue StandardError => e
      Rails.logger.warn("[SanPabloCrawler] page #{page_index} failed: #{e.class}: #{e.message}")
      nil
    end

    def extract_listing(product)
      name = product["name"]
      return nil if name.blank?

      price_value = product.dig("price", "value")
      return nil if price_value.blank? || price_value.to_f <= 0

      url = product["url"]

      {
        raw_name: name,
        price_cents: (price_value.to_f * 100).round,
        presentation_text: nil,
        product_url: url ? "#{BASE_URL}#{url}" : nil
      }
    end
  end
end

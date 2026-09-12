module Crawlers
  # Farmacias Guadalajara (farmaciasguadalajara.com) runs Salesforce Commerce Cloud
  # (SFRA reference architecture). Plain HTTP clients (curl, Net::HTTP) get connection
  # resets from Akamai-style bot mitigation, but real headless Chrome via Ferrum gets
  # through cleanly with a realistic user-agent and generous timeouts - confirmed
  # against /farmacia/medicina category pages. We still treat failures as best-effort:
  # a blocked run should not fail the whole daily crawl.
  class GuadalajaraCrawler < BaseCrawler
    BASE_URL = "https://www.farmaciasguadalajara.com"
    MEDICAMENTOS_CATEGORY_PATHS = [
      "/farmacia/medicina"
    ].freeze

    # KNOWN LIMITATION (2026-09-12): this crawler reaches all ~3,580 products from a
    # residential IP but stops early from Fly's datacentre IP - two production runs
    # ended at 320 and 440 products with no error raised, while the same code and the
    # same page size got 3,580 locally. The pagination endpoint itself answers
    # correctly when probed from production, so the likely cause is bot mitigation
    # re-serving an already-seen page once requests come from a datacentre, which
    # trips the "no new products" exit below. Production therefore keeps using the
    # older 2,120-product run rather than a truncated one; a short run must NOT be
    # aggregated, because it reports every unreached product as disappeared.
    #
    # The category reports ~3,580 products. At 20 pages x 20 per page the crawler
    # stopped at exactly 400 and reported the other 3,180 as "disappeared" - the cap
    # was the limit, not the catalogue. The loop already stops on its own when a page
    # yields nothing new, so this only needs to be high enough not to bind first.
    MAX_PAGES_PER_CATEGORY = ENV.fetch("GUADALAJARA_MAX_PAGES", 120).to_i
    # The grid serves 40 tiles per request even when sz=20 is asked for, so paging by
    # 20 re-read the first half of each page and skipped the second half entirely.
    PAGE_SIZE = 40

    private

    def fetch_listings
      page = browser.create_page
      page.headers.set("User-Agent" => USER_AGENT)

      # Same product can appear in more than one category - keep one listing per
      # product rather than one per (product, category) pair. (scrape_category
      # already de-dupes within a single category; this covers across them.)
      MEDICAMENTOS_CATEGORY_PATHS.flat_map do |path|
        scrape_category(page, path)
      end.uniq { |item| item[:product_url] || item[:raw_name] }
    ensure
      page&.close
    end

    # Retries a page whose grid comes back empty. The tiles are rendered client-side,
    # so "no tiles yet" and "no tiles at all" look identical at the moment of reading -
    # only a retry distinguishes a slow render from the real end of the category.
    TILE_LOAD_ATTEMPTS = 3

    def load_tiles(page, url)
      TILE_LOAD_ATTEMPTS.times do |attempt|
        page.go_to(url)
        sleep(rand(1.5..3.0)) # human-like pacing to reduce bot-mitigation triggers
        page.network.wait_for_idle(timeout: 20) rescue nil

        tiles = page.css(".product-tile")
        return tiles if tiles.any?

        sleep(2 + attempt * 3) if attempt < TILE_LOAD_ATTEMPTS - 1
      end
      []
    end

    def scrape_category(page, path)
      results = []
      seen_urls = Set.new

      (0...MAX_PAGES_PER_CATEGORY).each do |page_index|
        # This site silently ignores a `?page=N` param and always serves the same
        # first page - confirmed the real SFRA pagination is offset/limit-based
        # (`start`/`sz`), same mechanism as YzaCrawler's Search-UpdateGrid endpoint.
        url = "#{BASE_URL}#{path}?start=#{page_index * PAGE_SIZE}&sz=#{PAGE_SIZE}"
        tiles = load_tiles(page, url)
        # Only stop when a retried page is still genuinely empty. A page that merely
        # rendered slowly used to read as the end of the category: in production
        # (slower container, slower Chromium) this cut the crawl at 320 of ~3,580
        # products and reported the other 1,800 as disappeared.
        break if tiles.empty?

        new_count = 0
        tiles.each do |tile|
          link_el = tile.css(".pdp-link a.link, a.pdp-link").first
          name = link_el&.text&.strip
          next if name.blank?

          # The .value node carries the exact numeric price in its `content` attribute -
          # more reliable than parsing the displayed "$48.51" text.
          price_value = tile.css(".price .sales .value").first&.attribute("content")
          price_cents = price_value ? (price_value.to_f * 100).round : nil
          next if price_cents.nil?

          href = link_el&.attribute("href")
          product_url = href ? URI.join(BASE_URL, href).to_s : nil

          # Defense in depth against the site repeating a page's results (e.g. once
          # we've paged past its real result count) - without this, a stale/short
          # category would duplicate its last page of products for every remaining
          # page_index instead of naturally stopping.
          next if product_url && !seen_urls.add?(product_url)

          new_count += 1
          results << {
            raw_name: name,
            price_cents: price_cents,
            presentation_text: nil,
            product_url: product_url
          }
        end
        break if new_count.zero?
      end
      results
    rescue Ferrum::Error => e
      # Broad on purpose: this crawler is explicitly best-effort (see class comment),
      # and narrowly-typed rescues here have previously let an unanticipated Ferrum
      # exception (e.g. ProcessTimeoutError, or a network-level HTTP/2 protocol error)
      # propagate uncaught, which is worse than returning a partial/empty result -
      # it can silently abort a run without a clear signal of what actually failed.
      Rails.logger.warn("[GuadalajaraCrawler] blocked or failed on #{path}: #{e.class}: #{e.message}")
      results
    end
  end
end

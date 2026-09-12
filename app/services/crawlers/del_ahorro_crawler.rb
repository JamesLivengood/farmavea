require "net/http"
require "nokogiri"
require "timeout"

module Crawlers
  # Farmacia del Ahorro (fahorro.com) is a Magento storefront. Category/search pages
  # render prices client-side via the Empathy.co widget, but the site publishes a
  # sitemap of ~10k individual product URLs with descriptive slugs - we use that for
  # discovery instead of paginating JS-rendered category pages, then render each
  # product page with Ferrum to read the final price.
  class DelAhorroCrawler < BaseCrawler
    SITEMAP_INDEX_URL = "https://www.fahorro.com/sitemap.xml"
    CATEGORY_ROOT = "https://www.fahorro.com/farmacia.html"

    # Root-level sitemap .html URLs mix top-level category pages (few hyphens, e.g.
    # "farmacia.html", "vitaminas.html") with real product detail pages (many hyphens,
    # e.g. "ibuprofeno-200-mg-10-capsulas-marca-del-ahorro.html"). Category slugs top
    # out around 2 hyphens; real products consistently have 3+.
    MIN_SLUG_HYPHENS_FOR_PRODUCT = 3

    # Del Ahorro's category listing pages are WAF-blocked for headless browsers (their
    # Empathy.co widget's JS assets get 403'd by Incapsula), so we can't discover
    # medications by crawling /farmacia/* categories the way GuadalajaraCrawler does.
    # Instead we filter sitemap product slugs by dosage pattern / dosage-form keyword.
    # This is a heuristic, not exact - it lets through some cosmetics/food that happen
    # to mention "gr"/"ml" and may miss oddly-named drugs. Claude's aggregation step
    # acts as a second filter: non-medications won't extract into a sensible active
    # ingredient, and the daily batch is bounded by MAX_PRODUCTS regardless.
    DOSE_PATTERN = /\d+(\.\d+)?\s*-?\s*(mg|mcg|ui)\b/i
    FORM_KEYWORDS = %w[
      tableta tabletas capsula capsulas comprimido comprimidos jarabe suspension
      ampolleta ampolletas gotas supositorio supositorios inyectable grageas
    ].freeze

    # Cap per run to avoid triggering Incapsula's WAF under sustained high-volume
    # automated traffic (confirmed: full ~4,400-product runs failed near-100% twice,
    # while runs up to 300-500 products succeeded reliably in testing). Products are
    # prioritized (see #prioritized_product_urls) so this smaller daily budget covers
    # the medications most likely to matter first, with the remainder covered over
    # subsequent days rather than attempted all at once.
    MAX_PRODUCTS = ENV.fetch("DEL_AHORRO_MAX_PRODUCTS", 300).to_i
    # A hard ceiling on how long one run may take. 300 products take ~15 minutes
    # locally but over 45 in production, where slow renders trigger retries - and a
    # run that never returns holds a browser and degrades the site it shares a
    # machine with.
    MAX_RUN_DURATION = ENV.fetch("DEL_AHORRO_MAX_MINUTES", 25).to_i.minutes
    # Generous next to a normal page load (a few seconds) but far below the run
    # budget, so one pathological page cannot consume it.
    PRODUCT_TIMEOUT = 45

    # Rendering is intermittently flaky on a long-lived shared browser (observed:
    # .product-info-main sometimes fails to appear at all on a page that renders fine
    # on a fresh browser) - retry before concluding a product has no price, so a bad
    # render isn't silently mistaken for "out of stock."
    MAX_RENDER_ATTEMPTS = 3

    # A fresh Ferrum::Browser per product was the most reliable option for rendering,
    # but launching Chrome thousands of times over a multi-hour crawl exhausted some
    # OS-level resource and crashed a real overnight run (Ferrum::ProcessTimeoutError
    # after ~5.5 hours). Recycling the browser every N products is a middle ground:
    # far fewer process launches, while still resetting periodically in case a
    # long-lived browser accumulates the same rendering flakiness a fully shared one
    # showed originally.
    PRODUCTS_PER_BROWSER = 25

    private

    # Seam for tests, which advance this instead of sleeping.
    def current_time = Time.current

    # Category pages now carry the name, price and URL of every tile, so one page load
    # yields ~24 products instead of one render each. They were WAF-blocked when this
    # crawler was written (hence the sitemap approach below), but as of 2026-09-12 they
    # render fine - while the sitemap has gone stale and its URLs 404, which is why a
    # full run returned zero products. Category scraping is now the primary source;
    # the per-product path stays as a fallback and for pages categories don't list.
    def fetch_listings
      @deadline = current_time + MAX_RUN_DURATION

      from_categories = scrape_categories
      return from_categories if from_categories.size >= MIN_CATEGORY_YIELD

      Rails.logger.warn(
        "[DelAhorroCrawler] categories yielded only #{from_categories.size} products; " \
        "falling back to per-product scraping."
      )
      from_categories + scrape_products_individually
    end

    # Below this, assume the category layout changed again and fall back rather than
    # reporting a near-empty catalogue (which would deactivate real listings).
    MIN_CATEGORY_YIELD = 100

    def scrape_categories
      page = browser.create_page
      page.headers.set("User-Agent" => USER_AGENT)
      products = {}

      category_urls(page).each do |url|
        break if current_time > @deadline

        begin
          page.go_to(url)
          wait_for_tiles(page).each do |tile|
            listing = extract_tile(tile)
            # Keyed by URL so a product appearing in several categories counts once.
            products[listing[:product_url]] ||= listing if listing
          end
        rescue StandardError => e
          Rails.logger.warn("[DelAhorroCrawler] category #{url} failed: #{e.class}: #{e.message[0, 120]}")
        end
      end

      products.values
    ensure
      page&.close
    end

    def category_urls(page)
      page.go_to(CATEGORY_ROOT)
      # Measured at 32s to fully load, so poll for the nav links rather than guessing
      # a sleep - too short here and the run finds no categories at all.
      deadline = current_time + TILE_WAIT_SECONDS
      urls = []
      loop do
        urls = page.css("a").map { |a| a.attribute("href").to_s }
                   .select { |h| h.match?(%r{fahorro\.com/farmacia/[^/]+\.html\z}) }
                   .uniq
        break if urls.any? || current_time > deadline

        sleep TILE_POLL_INTERVAL
      end
      # The root itself lists products too, so keep it in the rotation.
      ([ CATEGORY_ROOT ] + urls).uniq
    end

    # The tiles are injected client-side and genuinely slow - a 3s wait returned zero
    # tiles on a page that has 24. Polling instead of sleeping a fixed interval means
    # a fast page costs a second and a slow one still gets read, rather than being
    # silently reported as an empty category (which would deactivate real listings).
    TILE_WAIT_SECONDS = 20
    TILE_POLL_INTERVAL = 1

    def wait_for_tiles(page)
      deadline = current_time + TILE_WAIT_SECONDS
      loop do
        tiles = page.css(".product-item")
        return tiles if tiles.any?
        return [] if current_time > deadline

        sleep TILE_POLL_INTERVAL
      end
    end

    def extract_tile(tile)
      name = tile.css(".product-item-link").first&.text.to_s.strip
      return nil if name.blank?

      price_cents = parse_price_cents(tile.css(".price").first&.text)
      return nil if price_cents.nil? || price_cents <= 0

      url = tile.css("a").first&.attribute("href").to_s
      { raw_name: name, price_cents: price_cents, presentation_text: nil, product_url: url.presence }
    end

    def scrape_products_individually
      product_urls = prioritized_product_urls.first(MAX_PRODUCTS)
      results = []

      product_urls.each_slice(PRODUCTS_PER_BROWSER) do |url_batch|
        # Stop cleanly and keep what we have. A page load can hang with no timeout
        # firing - one production run sat at 0.4% CPU for 45 minutes and was killed,
        # losing all of it, because everything is persisted in one batch at the end.
        # Partial results from a bounded run are worth far more than none.
        if current_time > @deadline
          Rails.logger.warn(
            "[#{self.class.name}] stopping at #{results.size} products: hit the " \
            "#{MAX_RUN_DURATION.inspect} limit with #{product_urls.size} planned."
          )
          break
        end

        results.concat(scrape_batch(url_batch))
      end

      results
    end

    # Orders discovered URLs so a capped daily run covers the medications most
    # likely to matter first, and skips URLs already scraped TODAY (not "ever") -
    # so once the backlog is caught up, every product refreshes daily like the other
    # pharmacies, but within one day's run we don't re-scrape something this same
    # run (or an earlier run today) already covered. The uncovered remainder of the
    # catalog naturally gets covered over subsequent days at MAX_PRODUCTS/day.
    #
    # "Most likely to matter" is approximated by cross-pharmacy demand: a medication
    # name that already appears as a canonical Medication (i.e. some other pharmacy
    # sells it too) is a stronger signal of real demand than sitemap order alone,
    # since Del Ahorro's sitemap carries no popularity/sales-rank data of its own.
    def prioritized_product_urls
      all_urls = discover_product_urls

      scraped_today = RawListing.where(pharmacy: pharmacy, product_url: all_urls)
                                 .where(scraped_at: Time.current.all_day)
                                 .distinct.pluck(:product_url).to_set
      remaining = all_urls.reject { |url| scraped_today.include?(url) }

      # When each product was last seen, so never-scraped ones can go first.
      last_seen = RawListing.where(pharmacy: pharmacy, product_url: remaining)
                             .group(:product_url).maximum(:scraped_at)

      known_terms = known_medication_terms

      # Never-scraped products come first, oldest-refresh next, and within each
      # group the medications other pharmacies also sell (a proxy for real demand)
      # lead.
      #
      # Sorting by demand alone re-scraped the SAME top ~300 products every night:
      # the run only skipped what it had already done *today*, so each new day
      # restarted at the top of an unchanged priority list and the other ~3,900
      # products were never reached. Measured: one night's run of 274 products
      # contained zero the previous run hadn't already captured.
      remaining.sort_by do |url|
        [
          last_seen[url] ? 1 : 0,                                        # unseen first
          last_seen[url] || Time.at(0),                                  # then stalest
          known_terms.any? { |term| url.include?(term) } ? 0 : 1         # then by demand
        ]
      end
    end

    # Slug-normalized (lowercase, accent-stripped, non-alphanumeric-to-hyphen)
    # canonical medication names from ALL pharmacies, used as substrings to spot
    # cross-pharmacy demand in a Del Ahorro URL slug. Single-word generic names
    # only (e.g. "ibuprofeno") - multi-word/combination names rarely appear as an
    # exact contiguous substring in another site's slug, so they're excluded rather
    # than risk false negatives skewing the sort silently.
    def known_medication_terms
      Medication.distinct.pluck(:canonical_name).filter_map do |name|
        first_word = name.to_s.split(%r{[\s/]}).first
        next if first_word.blank?
        normalized = first_word.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "").downcase
        normalized.length > 3 ? normalized : nil
      end.uniq
    end

    def scrape_batch(url_batch)
      batch_browser = new_browser
      # Checked per product, not just per batch: a single page can hang the browser
      # for longer than the whole run's budget (fahorro's dimenhidrinato page did
      # exactly this, twice), and a batch-level check never gets reached.
      url_batch.filter_map do |url|
        next if @deadline && current_time > @deadline

        scrape_product_with_retries(url, batch_browser)
      end
    rescue Ferrum::ProcessTimeoutError => e
      # Chrome failed to launch for this whole batch - seen after thousands of
      # sequential launches over a multi-hour run, likely transient OS-level resource
      # pressure (file descriptors / process table). A brief pause gives the system a
      # chance to recover; this batch's products are skipped rather than retried
      # indefinitely against an already-strained launch path.
      Rails.logger.warn("[DelAhorroCrawler] Chrome failed to launch for a batch of #{url_batch.size} products: #{e.message}")
      sleep 5
      []
    ensure
      batch_browser&.quit
    end

    # Retries only a FAILED RENDER, not a successfully-rendered page that simply has
    # no purchasable price. Retrying the latter burns 3x the page loads on every
    # out-of-stock product against a WAF-sensitive site whose daily budget is already
    # capped at MAX_PRODUCTS - scrape_product signals the difference by returning
    # :no_price (definitive, don't retry) vs nil (bad render, worth retrying).
    def scrape_product_with_retries(url, batch_browser)
      MAX_RENDER_ATTEMPTS.times do |attempt|
        # Ferrum's own timeouts do not always fire - a page can leave the CDP call
        # waiting indefinitely (observed twice on the same fahorro product, each time
        # stalling the run until it was killed). This is the outer guard that makes a
        # hung page cost one product rather than the entire crawl.
        result = Timeout.timeout(PRODUCT_TIMEOUT) { scrape_product(url, batch_browser) }
        return nil if result == :no_price
        return result if result
        Rails.logger.info("[DelAhorroCrawler] retrying #{url} (attempt #{attempt + 2}/#{MAX_RENDER_ATTEMPTS})") if attempt < MAX_RENDER_ATTEMPTS - 1
      rescue Timeout::Error
        Rails.logger.warn("[DelAhorroCrawler] #{url} hung for over #{PRODUCT_TIMEOUT}s - skipping it")
        return nil
      end
      Rails.logger.warn("[DelAhorroCrawler] gave up on #{url} after #{MAX_RENDER_ATTEMPTS} attempts")
      nil
    end

    def discover_product_urls
      shard_urls = fetch_xml(SITEMAP_INDEX_URL).css("sitemap > loc").map(&:text)
      shard_urls.flat_map { |shard| fetch_xml(shard).css("url > loc").map(&:text) }
                .select { |url| likely_product_url?(url) && likely_medication_slug?(url) }
                .uniq
    rescue StandardError => e
      raise CrawlError, "Failed to read Del Ahorro sitemap: #{e.message}"
    end

    def likely_product_url?(url)
      path = URI.parse(url).path
      segments = path.split("/").reject(&:empty?)
      return false unless segments.size == 1 && segments.first.end_with?(".html")

      slug = segments.first.delete_suffix(".html")
      slug.count("-") >= MIN_SLUG_HYPHENS_FOR_PRODUCT
    rescue URI::InvalidURIError
      false
    end

    def likely_medication_slug?(url)
      slug = URI.parse(url).path.split("/").last.to_s
      slug.match?(DOSE_PATTERN) || FORM_KEYWORDS.any? { |kw| slug.include?(kw) }
    rescue URI::InvalidURIError
      false
    end

    def fetch_xml(url)
      response = Net::HTTP.get_response(URI.parse(url))
      raise CrawlError, "Sitemap fetch #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      Nokogiri::XML(response.body)
    end

    def scrape_product(url, batch_browser)
      page = batch_browser.create_page
      page.headers.set("User-Agent" => USER_AGENT)
      page.go_to(url)

      # Two .product-info-main blocks exist per page (one real, one ".additional"
      # related-products template) - always scope through the non-additional one.
      main = page.at_css(".product-info-main:not(.additional)")
      if main.nil?
        Rails.logger.info("[DelAhorroCrawler] #{url}: .product-info-main not found (likely a bad render, not out-of-stock)")
        return nil
      end

      name = main.at_css("h1")&.text&.strip
      # .product-info-main rendered but has no <h1> - treat as a definitive "nothing
      # useful here" rather than a render failure worth retrying.
      return :no_price if name.blank?

      # data-price-amount on [data-price-type='finalPrice'] is Magento's own resolved
      # payable price (already accounts for any discount) - avoids parsing "$1,234.00"
      # display text or picking between .old-price/.special-price ourselves. Absence
      # here, once .product-info-main itself rendered, means genuinely no purchasable
      # price (out of stock / discontinued) rather than a render failure.
      price_amount = main.at_css(".price-box [data-price-type='finalPrice']")&.attribute("data-price-amount")
      if price_amount.blank?
        Rails.logger.info("[DelAhorroCrawler] #{url}: rendered but no purchasable price (likely out of stock)")
        return :no_price
      end

      # Lives outside .product-info-main (sibling section), unlike name/price.
      presentation = page.at_css(".product.attribute.description, .product.attribute.overview .value")
                         &.text&.strip&.truncate(300)

      {
        raw_name: name,
        price_cents: (price_amount.to_f * 100).round,
        presentation_text: presentation,
        product_url: url,
        requires_prescription: requires_prescription?(page)
      }
    rescue Ferrum::Error => e
      # Broad on purpose: this crawler makes thousands of independent page loads per
      # run, and any unanticipated Ferrum exception (network-level protocol errors,
      # a dead shared browser, etc.) should skip this one product via the retry loop
      # rather than crash the run. If the shared browser itself died, the next
      # retry's #create_page will raise too and the batch will move to a fresh
      # browser via scrape_batch's normal per-batch recycling on the next slice.
      Rails.logger.warn("[DelAhorroCrawler] skip #{url}: #{e.class}: #{e.message}")
      nil
    ensure
      page&.close
    end

    # Confirmed reliable via live investigation: the "Requiere receta" row in
    # Magento's attribute-specs table reads "Si"/"No" and matches the visible
    # "Agregar Receta Médica" badge on real prescription-only products.
    def requires_prescription?(page)
      value = page.at_css("table#product-attribute-specs-table td[data-th='Requiere receta']")&.text&.strip
      return nil if value.blank?
      value.casecmp("si").zero?
    end
  end
end

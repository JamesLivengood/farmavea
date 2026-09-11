module Crawlers
  # Vitau (vitau.mx), a "100% digital pharmacy," is Next.js and fully server-
  # rendered per page load (no client-side product API - confirmed via network
  # traffic capture). Fronted by Vercel's bot-protection JS challenge - plain curl
  # is blocked even with a full realistic header set (this is an active
  # fingerprint/proof-of-work challenge, not simple header detection), but real
  # headless Chrome via Ferrum passes on the first attempt with a brief wait.
  class VitauCrawler < BaseCrawler
    BASE_URL = "https://vitau.mx"
    CATEGORY_PATHS = %w[
      /medicamentos/antibioticos
      /medicamentos/diabetes
      /medicamentos/analgesicos
      /medicamentos/hipertension
    ].freeze
    MAX_PAGES_PER_CATEGORY = ENV.fetch("VITAU_MAX_PAGES", 20).to_i

    private

    def fetch_listings
      page = browser.create_page
      page.headers.set("User-Agent" => USER_AGENT, "Accept-Language" => "es-MX,es;q=0.9,en;q=0.8")

      # Same product can appear in more than one category - keep one listing per
      # product rather than one per (product, category) pair.
      CATEGORY_PATHS.flat_map { |path| scrape_category(page, path) }
                    .uniq { |item| item[:product_url] || item[:raw_name] }
    ensure
      page&.close
    end

    def scrape_category(page, path)
      results = []
      (1..MAX_PAGES_PER_CATEGORY).each do |page_number|
        url = "#{BASE_URL}#{path}?page=#{page_number}"
        page.go_to(url)
        sleep 4 # Vercel's bot-protection challenge resolves client-side before real content loads

        # Each product card is an <a> wrapping the image, name (h3), presentation
        # text, and price - no separate container class was found, so scope on
        # the name heading and walk up to its link ancestor.
        names = page.css("h3.line-clamp-2")
        break if names.empty?

        names.each do |name_el|
          listing = extract_listing(name_el)
          results << listing if listing
        end
      end
      results
    rescue Ferrum::Error => e
      Rails.logger.warn("[VitauCrawler] blocked or failed on #{path}: #{e.class}: #{e.message}")
      results
    end

    def extract_listing(name_el)
      # Ferrum::Node has no #parent accessor - use the ancestor:: XPath axis to
      # find the enclosing card link instead of walking up the DOM tree directly.
      link_el = name_el.xpath("ancestor::a[1]").first
      href = link_el&.attribute("href")
      return nil if href.blank?

      brand_name = name_el.text.strip
      presentation = link_el.css("p.line-clamp-1").first&.text&.strip
      full_name = [ brand_name, presentation ].compact_blank.join(" ")
      return nil if full_name.blank?

      price_text = link_el.css("p.font-primaryFont").first&.text
      price_cents = parse_price_cents(price_text)
      return nil if price_cents.nil?

      {
        raw_name: full_name,
        price_cents: price_cents,
        presentation_text: presentation,
        product_url: URI.join(BASE_URL, href).to_s
      }
    end
  end
end

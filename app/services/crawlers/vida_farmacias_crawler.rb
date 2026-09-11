module Crawlers
  # Vida Farmacias (vidafarmacias.com) specializes in high-specialty/high-cost
  # medications. PrestaShop storefront, fully server-rendered, but fronted by
  # Cloudflare with a real TLS/JS-based challenge - plain curl is blocked
  # universally (even with a complete realistic header set), but real headless
  # Chrome via Ferrum gets through on the first attempt with a brief wait after
  # navigation for the challenge to clear.
  class VidaFarmaciasCrawler < BaseCrawler
    BASE_URL = "https://vidafarmacias.com"
    CATEGORY_PATHS = %w[/mx/110-alta-especialidad /mx/66-oncologia].freeze
    MAX_PAGES_PER_CATEGORY = ENV.fetch("VIDA_MAX_PAGES", 20).to_i

    private

    def fetch_listings
      page = browser.create_page
      page.headers.set("User-Agent" => USER_AGENT)

      # Same product can appear in more than one category (measured ~1.14x overlap
      # here) - keep one listing per product, not one per (product, category) pair.
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
        # Cloudflare's challenge resolves client-side before the real page loads -
        # a short pause after navigation lets it clear (confirmed working reliably
        # in investigation; no CAPTCHA encountered).
        sleep 5

        cards = page.css("article.product-miniature")
        break if cards.empty?

        cards.each do |card|
          listing = extract_listing(card)
          results << listing if listing
        end
      end
      results
    rescue Ferrum::Error => e
      Rails.logger.warn("[VidaFarmaciasCrawler] blocked or failed on #{path}: #{e.class}: #{e.message}")
      results
    end

    def extract_listing(card)
      link_el = card.css(".product-title a").first
      name = link_el&.text&.strip
      return nil if name.blank?

      price_text = card.css(".product-price-and-shipping span.price").first&.text
      price_cents = parse_price_cents(price_text)
      return nil if price_cents.nil?

      # Every sampled product in this category carried the badge (20/20), so we
      # have no confirmed example of its absence meaning "not prescription" -
      # trust the positive signal only, leave it nil (unknown) rather than assert
      # false without evidence, same principle as Guadalajara's prescription field.
      requires_prescription = card.css(".rxupload-badge-text").any? ? true : nil

      {
        raw_name: name,
        price_cents: price_cents,
        presentation_text: nil,
        product_url: link_el.attribute("href"),
        requires_prescription: requires_prescription
      }
    end
  end
end

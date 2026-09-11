require "ferrum"

module Crawlers
  # Common headless-browser plumbing for pharmacy crawlers. Subclasses implement
  # #fetch_listings and return an array of { raw_name:, price_cents:, presentation_text:, product_url: }.
  class BaseCrawler
    USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " \
                 "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    class CrawlError < StandardError; end

    def initialize(pharmacy:, crawl_run:)
      @pharmacy = pharmacy
      @crawl_run = crawl_run
    end

    # Returns the number of raw listings persisted.
    def call
      listings = fetch_listings
      persist(listings)
      listings.size
    ensure
      @lazy_browser&.quit
    end

    protected

    # Only spins up headless Chrome the first time a crawler actually calls this -
    # crawlers like ChedrauiCrawler that scrape plain HTTP JSON never call it, so no
    # browser process gets started for them at all.
    def browser
      @lazy_browser ||= new_browser
    end

    def new_browser
      options = { "user-agent" => USER_AGENT, "disable-blink-features" => "AutomationControlled" }
      # Chromium can't set up its sandbox inside the container without extra kernel
      # privileges, so it exits immediately unless sandboxing is disabled. Only
      # applied in a container - locally the sandbox works and should stay on.
      options["no-sandbox"] = nil if running_in_container?

      Ferrum::Browser.new(
        headless: true,
        timeout: 30,
        process_timeout: 30,
        browser_path: detect_browser_path,
        browser_options: options,
        pending_connection_errors: false
      )
    end

    def running_in_container?
      File.exist?("/.dockerenv") || ENV["FLY_APP_NAME"].present?
    end

    # Ferrum only auto-detects a `chrome`/`google-chrome` binary on PATH, which
    # finds neither macOS's app bundle nor Debian's `chromium` - the production
    # container had chromium installed and still raised BinaryNotFoundError until
    # this looked for it by name.
    BROWSER_PATHS = [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", # macOS
      "/usr/bin/chromium",                                            # Debian/Ubuntu
      "/usr/bin/chromium-browser",
      "/usr/bin/google-chrome"
    ].freeze

    def detect_browser_path
      return ENV["FERRUM_BROWSER_PATH"] if ENV["FERRUM_BROWSER_PATH"].present?

      BROWSER_PATHS.find { |path| File.exist?(path) }
    end

    private

    attr_reader :pharmacy, :crawl_run

    def persist(listings)
      now = Time.current
      rows = listings.filter_map do |item|
        next if item[:raw_name].blank? || item[:price_cents].to_i <= 0

        {
          crawl_run_id: crawl_run.id,
          pharmacy_id: pharmacy.id,
          raw_name: item[:raw_name].strip,
          presentation_text: item[:presentation_text].presence,
          price_cents: item[:price_cents].to_i,
          product_url: item[:product_url],
          requires_prescription: item[:requires_prescription],
          scraped_at: now,
          created_at: now,
          updated_at: now
        }
      end
      RawListing.insert_all(rows) if rows.any?
    end

    # Parses a Mexican peso price string like "$123.45" or "MX$1,234" into integer cents.
    def parse_price_cents(text)
      return nil if text.blank?
      digits = text.to_s.gsub(/[^\d.]/, "")
      return nil if digits.blank?
      (digits.to_f * 100).round
    end
  end
end

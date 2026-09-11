ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# Blocks every real network request by default (pharmacy sites, the Anthropic API,
# anything) - a test that needs to simulate an HTTP response must explicitly stub it
# with WebMock. This is the single most important safety net in this suite: it's
# what guarantees running `bin/rails test` can never scrape a live pharmacy site or
# spend real Claude API money, no matter what a test does or forgets to mock.
WebMock.disable_net_connect!(allow_localhost: true)

require_relative "support/fake_claude_response"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # No YAML fixtures - tests build the (small amount of) data they need directly
    # via the helpers below, which keeps each test's setup visible in the test
    # itself rather than in a separate fixture file, and avoids fixture/foreign-key
    # ordering footguns across this schema's several linked tables.

    private

    # name defaults to a fresh unique value per call (not a fixed constant) -
    # Pharmacy requires it unique, and a test that calls this helper more than
    # once (directly, or indirectly via another helper) would otherwise hit a
    # uniqueness violation even though each test's writes get rolled back, since
    # Postgres checks unique constraints immediately, not at transaction end.
    #
    # slug defaults to one from Pharmacy::SERVES_MORELIA_SLUGS so the created
    # pharmacy's offers are visible to the site by default (Offer.purchasable
    # filters on that list) - a test specifically about the hidden-pharmacy
    # behavior passes an excluded slug like "heb" explicitly.
    def create_pharmacy(slug: nil, name: nil, **attrs)
      unique = SecureRandom.hex(4)
      # Take the next unused serving slug so repeated calls in one test don't
      # collide on Pharmacy's uniqueness constraint.
      slug ||= (Pharmacy::SERVES_MORELIA_SLUGS - Pharmacy.pluck(:slug)).first
      raise "ran out of SERVES_MORELIA_SLUGS for test pharmacies" if slug.nil?

      Pharmacy.create!(
        slug: slug,
        name: name || "Test Pharmacy #{unique}",
        base_url: "https://example.invalid", active: true, **attrs
      )
    end

    def create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg", **attrs)
      Medication.create!(canonical_name: canonical_name, strength_value: strength_value, strength_unit: strength_unit, **attrs)
    end

    def create_crawl_run(pharmacy:, status: "succeeded", city: "Morelia, Michoacán")
      pharmacy.crawl_runs.create!(city: city, status: status)
    end

    def create_raw_listing(pharmacy:, crawl_run: nil, raw_name: "Ibuprofeno 400 mg", price_cents: 5000, **attrs)
      crawl_run ||= create_crawl_run(pharmacy: pharmacy)
      RawListing.create!(
        pharmacy: pharmacy, crawl_run: crawl_run, raw_name: raw_name,
        price_cents: price_cents, scraped_at: Time.current, **attrs
      )
    end

    def create_offer(medication:, pharmacy:, raw_listing: nil, city: "Morelia, Michoacán", price_cents: 5000, price_per_mg: nil, active: true)
      raw_listing ||= create_raw_listing(pharmacy: pharmacy, price_cents: price_cents)
      Offer.create!(
        medication: medication, pharmacy: pharmacy, raw_listing: raw_listing,
        city: city, price_cents: price_cents, price_per_mg: price_per_mg,
        scraped_at: Time.current, active: active
      )
    end
  end
end

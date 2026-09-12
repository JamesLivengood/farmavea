require "test_helper"

class NormalizeAndBuildOffersJobTest < ActiveSupport::TestCase
  # Aggregation deactivates any offer the newest crawl did not see, so that
  # out-of-stock products stop showing as "cheapest". That is correct only when the
  # crawl actually covered the catalogue - a truncated run (a WAF blocking partway,
  # a page that stopped rendering, a site layout change) would otherwise remove
  # hundreds of products that are still on sale. Guadalajara produced exactly this:
  # 320 listings where the previous run had 2,120.
  test "a truncated crawl does not deactivate the offers it failed to reach" do
    pharmacy = create_pharmacy(slug: "benavides")
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")

    full_run = create_crawl_run(pharmacy: pharmacy)
    offers = 10.times.map do |i|
      listing = create_raw_listing(pharmacy: pharmacy, crawl_run: full_run, raw_name: "Producto #{i} 500 mg")
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing)
    end

    # A later run that found only one product - far under half of the previous ten.
    short_run = create_crawl_run(pharmacy: pharmacy)
    create_raw_listing(pharmacy: pharmacy, crawl_run: short_run, raw_name: "Producto 0 500 mg")

    NormalizeAndBuildOffersJob.new.send(:deactivate_stale_offers, short_run)

    assert offers.all? { |o| o.reload.active? },
      "a truncated crawl must not deactivate products that are probably still for sale"
  end

  test "a crawl with comparable coverage does deactivate what it no longer sees" do
    pharmacy = create_pharmacy(slug: "benavides")
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")

    full_run = create_crawl_run(pharmacy: pharmacy)
    gone = 4.times.map do |i|
      listing = create_raw_listing(pharmacy: pharmacy, crawl_run: full_run, raw_name: "Descontinuado #{i} 500 mg")
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing)
    end

    # Found 3 of 4 - a real, plausible change rather than a truncation.
    current_run = create_crawl_run(pharmacy: pharmacy)
    3.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: current_run, raw_name: "Vigente #{i} 500 mg") }

    NormalizeAndBuildOffersJob.new.send(:deactivate_stale_offers, current_run)

    assert gone.none? { |o| o.reload.active? },
      "offers absent from a broad crawl should stop showing as available"
  end

  test "a crawl that found nothing never deactivates anything" do
    pharmacy = create_pharmacy(slug: "benavides")
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Producto 500 mg")
    offer = create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing)

    empty_run = create_crawl_run(pharmacy: pharmacy)

    NormalizeAndBuildOffersJob.new.send(:deactivate_stale_offers, empty_run)

    assert offer.reload.active?
  end

  # With no earlier run to compare against there is no evidence of truncation, so
  # the guard must not block deactivation - otherwise a pharmacy's very first crawl
  # could never retire anything.
  test "a pharmacy's only crawl counts as broad enough to deactivate" do
    pharmacy = create_pharmacy(slug: "benavides")
    only_run = create_crawl_run(pharmacy: pharmacy)
    create_raw_listing(pharmacy: pharmacy, crawl_run: only_run, raw_name: "Nuevo 500 mg")

    assert NormalizeAndBuildOffersJob.new.send(:broad_enough_to_deactivate?, only_run)
  end

  test "a run with no previous listings to compare against is still allowed" do
    pharmacy = create_pharmacy(slug: "benavides")
    # An earlier run that persisted nothing must not be treated as a baseline of 0,
    # nor block the current run.
    CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "failed")
    current_run = create_crawl_run(pharmacy: pharmacy)
    create_raw_listing(pharmacy: pharmacy, crawl_run: current_run, raw_name: "Nuevo 500 mg")

    assert NormalizeAndBuildOffersJob.new.send(:broad_enough_to_deactivate?, current_run)
  end
end

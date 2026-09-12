require "test_helper"

class CrawlRunTest < ActiveSupport::TestCase
  test "mark_running! sets status and started_at" do
    crawl_run = create_crawl_run(pharmacy: create_pharmacy, status: "pending")
    crawl_run.mark_running!

    assert_equal "running", crawl_run.status
    assert_not_nil crawl_run.started_at
  end

  test "mark_succeeded! sets status, finished_at, and items_found from actual raw_listings" do
    pharmacy = create_pharmacy
    crawl_run = create_crawl_run(pharmacy: pharmacy, status: "running")
    create_raw_listing(pharmacy: pharmacy, crawl_run: crawl_run, raw_name: "A")
    create_raw_listing(pharmacy: pharmacy, crawl_run: crawl_run, raw_name: "B")

    crawl_run.mark_succeeded!

    assert_equal "succeeded", crawl_run.status
    assert_not_nil crawl_run.finished_at
    assert_equal 2, crawl_run.items_found
  end

  test "mark_failed! records a truncated error message" do
    crawl_run = create_crawl_run(pharmacy: create_pharmacy, status: "running")
    crawl_run.mark_failed!(StandardError.new("boom"))

    assert_equal "failed", crawl_run.status
    assert_equal "boom", crawl_run.error_message
  end

  test "rejects a status outside the allowed list" do
    crawl_run = CrawlRun.new(pharmacy: create_pharmacy, city: "Test", status: "not_a_real_status")
    assert_not crawl_run.valid?
    assert_includes crawl_run.errors[:status], "is not included in the list"
  end

  # Del Ahorro's nightly job ran for days against a sitemap whose URLs had all
  # started 404ing, persisted nothing each time, and reported "succeeded" - so the
  # breakage never surfaced anywhere.
  test "a crawl that persisted nothing is marked failed, not succeeded" do
    pharmacy = create_pharmacy
    crawl_run = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")

    crawl_run.mark_succeeded!

    assert_equal "failed", crawl_run.reload.status
    assert_equal 0, crawl_run.items_found
    assert_match(/persisted no listings/, crawl_run.error_message)
  end

  # A truncated run marked "succeeded" becomes the newest run, and therefore the
  # baseline every later comparison measures against - so the real catalogue is
  # forgotten. Guadalajara found 280 listings where the previous run had 2,120.
  test "a crawl that collapses against the previous run is marked failed" do
    pharmacy = create_pharmacy
    full = create_crawl_run(pharmacy: pharmacy)
    300.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: full, raw_name: "Producto #{i} 500 mg") }

    truncated = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")
    50.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: truncated, raw_name: "Parcial #{i} 500 mg") }

    truncated.mark_succeeded!

    assert_equal "failed", truncated.reload.status
    assert_match(/looks truncated/, truncated.error_message)
  end

  test "a modest drop is accepted as a real inventory change" do
    pharmacy = create_pharmacy
    full = create_crawl_run(pharmacy: pharmacy)
    300.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: full, raw_name: "Producto #{i} 500 mg") }

    current = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")
    280.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: current, raw_name: "Vigente #{i} 500 mg") }

    current.mark_succeeded!

    assert_equal "succeeded", current.reload.status
  end

  # Small pharmacies move by a few listings routinely - costco sits between 92 and
  # 95 - so the ratio is meaningless below a baseline worth comparing against.
  test "a small pharmacy is not held to the shrink rule" do
    pharmacy = create_pharmacy
    previous = create_crawl_run(pharmacy: pharmacy)
    90.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: previous, raw_name: "Producto #{i} 500 mg") }

    current = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")
    30.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: current, raw_name: "Vigente #{i} 500 mg") }

    current.mark_succeeded!

    assert_equal "succeeded", current.reload.status
  end

  test "a pharmacy's first real crawl has no baseline and succeeds" do
    pharmacy = create_pharmacy
    first = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")
    10.times { |i| create_raw_listing(pharmacy: pharmacy, crawl_run: first, raw_name: "Producto #{i} 500 mg") }

    first.mark_succeeded!

    assert_equal "succeeded", first.reload.status
  end

  test "a crawl that persisted listings succeeds normally" do
    pharmacy = create_pharmacy
    crawl_run = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")
    create_raw_listing(pharmacy: pharmacy, crawl_run: crawl_run)

    crawl_run.mark_succeeded!

    assert_equal "succeeded", crawl_run.reload.status
    assert_equal 1, crawl_run.items_found
  end
end

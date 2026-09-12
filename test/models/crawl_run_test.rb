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

  test "a crawl that persisted listings succeeds normally" do
    pharmacy = create_pharmacy
    crawl_run = CrawlRun.create!(pharmacy: pharmacy, city: "Morelia, Michoacán", status: "running")
    create_raw_listing(pharmacy: pharmacy, crawl_run: crawl_run)

    crawl_run.mark_succeeded!

    assert_equal "succeeded", crawl_run.reload.status
    assert_equal 1, crawl_run.items_found
  end
end

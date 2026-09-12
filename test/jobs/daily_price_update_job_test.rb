require "test_helper"

# The nightly crawl runs unattended on the server. These cover the two properties
# that matter: it refreshes every pharmacy the site displays (scoping it to one
# left the homepage showing ten-day-old prices under "Actualizado hoy"), and it
# still cannot spend money without an explicit opt-in.
class DailyPriceUpdateJobTest < ActiveJob::TestCase
  test "crawls every pharmacy the site displays" do
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
    create_pharmacy(slug: "benavides", name: "Benavides")
    create_pharmacy(slug: "guadalajara", name: "Guadalajara")

    assert_enqueued_jobs 3, only: CrawlPharmacyJob do
      DailyPriceUpdateJob.perform_now
    end

    slugs = enqueued_jobs.select { |j| j["job_class"] == "CrawlPharmacyJob" }
                         .map { |j| j["arguments"].first }
    assert_equal %w[benavides del_ahorro guadalajara], slugs.sort
  end

  # A pharmacy the site hides (unconfirmed Morelia presence) is still crawled by
  # hand when wanted, but spending the nightly budget on it would slow the refresh
  # of the ones people actually see.
  test "does not crawl pharmacies that are not displayed" do
    create_pharmacy(slug: "benavides", name: "Benavides")
    create_pharmacy(slug: "farmacias_abc", name: "Farmacias ABC")

    DailyPriceUpdateJob.perform_now

    slugs = enqueued_jobs.select { |j| j["job_class"] == "CrawlPharmacyJob" }
                         .map { |j| j["arguments"].first }
    assert_includes slugs, "benavides"
    assert_not_includes slugs, "farmacias_abc"
  end

  test "skips a pharmacy that has been deactivated" do
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro", active: false)

    assert_no_enqueued_jobs only: CrawlPharmacyJob do
      DailyPriceUpdateJob.perform_now
    end
  end

  # Crawling without aggregating refreshes the raw data and changes nothing on the
  # site - which is how prices went stale while crawls kept "succeeding".
  test "enqueues crawls that aggregate, so fresh prices reach the site" do
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")

    DailyPriceUpdateJob.perform_now

    job = enqueued_jobs.find { |j| j["job_class"] == "CrawlPharmacyJob" }
    assert job, "expected a CrawlPharmacyJob to be enqueued"
    assert_equal true, job["arguments"].last["aggregate"]
  end

  # Aggregating nightly is only safe because the paid tier needs an explicit
  # opt-in. If that guard ever disappears, this is what should fail.
  test "aggregation cannot reach the paid API without ALLOW_CLAUDE_API" do
    original = ENV.delete("ALLOW_CLAUDE_API")
    pharmacy = create_pharmacy(slug: "benavides")
    listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Kuryent Xyz 99")

    result = Aggregation::MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing ]).call

    assert_nil result[listing.id],
      "an unresolvable name must stay unresolved rather than being billed to the API"
  ensure
    ENV["ALLOW_CLAUDE_API"] = original if original
  end

  test "pharmacies are staggered rather than all fired at once" do
    create_pharmacy(slug: "benavides", name: "Benavides")
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")

    DailyPriceUpdateJob.perform_now

    waits = enqueued_jobs.select { |j| j["job_class"] == "CrawlPharmacyJob" }
                         .map { |j| j["scheduled_at"] }
    assert_equal waits.uniq.size, waits.size,
      "concurrent headless-browser crawls make the site unresponsive on a small machine"
  end

  # A stand-in crawler that does nothing, so these tests exercise the job's
  # aggregate/don't-aggregate branch without any network access.
  class NoopCrawler
    def initialize(pharmacy:, crawl_run:) = nil
    def call = 0
  end

  # CRAWLER_CLASSES is frozen, so swap the whole constant for the duration.
  def with_noop_crawler(slug)
    original = CrawlPharmacyJob::CRAWLER_CLASSES
    CrawlPharmacyJob.send(:remove_const, :CRAWLER_CLASSES)
    CrawlPharmacyJob.const_set(:CRAWLER_CLASSES, { slug => NoopCrawler }.freeze)
    yield
  ensure
    CrawlPharmacyJob.send(:remove_const, :CRAWLER_CLASSES)
    CrawlPharmacyJob.const_set(:CRAWLER_CLASSES, original)
  end

  test "CrawlPharmacyJob does not aggregate by default" do
    create_pharmacy(slug: "benavides", name: "Benavides")

    with_noop_crawler("benavides") do
      assert_no_enqueued_jobs only: NormalizeAndBuildOffersJob do
        CrawlPharmacyJob.perform_now("benavides", city: "Morelia, Michoacán")
      end
    end
  end

  # A crawler that never returns left its run stuck at "running" with nothing
  # persisted AND occupied the worker, so every pharmacy queued behind it that night
  # never started. Three were stuck this way at once.
  class HangingCrawler
    def initialize(pharmacy:, crawl_run:) = nil
    def call = sleep(30)
  end

  test "a crawl that overruns is abandoned instead of blocking the queue" do
    pharmacy = create_pharmacy(slug: "benavides", name: "Benavides")

    original_classes = CrawlPharmacyJob::CRAWLER_CLASSES
    original_timeout = CrawlPharmacyJob::MAX_CRAWL_DURATION
    CrawlPharmacyJob.send(:remove_const, :CRAWLER_CLASSES)
    CrawlPharmacyJob.const_set(:CRAWLER_CLASSES, { "benavides" => HangingCrawler }.freeze)
    CrawlPharmacyJob.send(:remove_const, :MAX_CRAWL_DURATION)
    CrawlPharmacyJob.const_set(:MAX_CRAWL_DURATION, 0.5.seconds)

    begin
      # Must not raise: raising would retry and consume the budget of the pharmacies
      # still waiting behind it.
      CrawlPharmacyJob.perform_now("benavides", city: "Morelia, Michoacán")

      run = CrawlRun.where(pharmacy: pharmacy).order(:created_at).last
      assert_equal "failed", run.status, "an overrunning crawl must not be left as running"
    ensure
      CrawlPharmacyJob.send(:remove_const, :CRAWLER_CLASSES)
      CrawlPharmacyJob.const_set(:CRAWLER_CLASSES, original_classes)
      CrawlPharmacyJob.send(:remove_const, :MAX_CRAWL_DURATION)
      CrawlPharmacyJob.const_set(:MAX_CRAWL_DURATION, original_timeout)
    end
  end

  test "CrawlPharmacyJob aggregates only when explicitly asked" do
    create_pharmacy(slug: "benavides", name: "Benavides")

    with_noop_crawler("benavides") do
      assert_enqueued_jobs 1, only: NormalizeAndBuildOffersJob do
        CrawlPharmacyJob.perform_now("benavides", city: "Morelia, Michoacán", aggregate: true)
      end
    end
  end
end

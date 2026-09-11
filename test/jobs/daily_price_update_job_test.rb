require "test_helper"

# The nightly crawl runs unattended on the server. These guard the property that
# makes that safe: it must never trigger Claude aggregation, which is the only step
# that spends money and has no per-run cap.
class DailyPriceUpdateJobTest < ActiveJob::TestCase
  test "crawls only Del Ahorro, not every pharmacy" do
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
    create_pharmacy(slug: "benavides", name: "Benavides")
    create_pharmacy(slug: "guadalajara", name: "Guadalajara")

    assert_enqueued_jobs 1, only: CrawlPharmacyJob do
      DailyPriceUpdateJob.perform_now
    end

    job = enqueued_jobs.find { |j| j["job_class"] == "CrawlPharmacyJob" }
    assert_equal "del_ahorro", job["arguments"].first,
      "only Del Ahorro has a crawl backlog - the others are already fully crawled each pass"
  end

  test "skips Del Ahorro when it has been deactivated" do
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro", active: false)

    assert_no_enqueued_jobs only: CrawlPharmacyJob do
      DailyPriceUpdateJob.perform_now
    end
  end

  test "enqueues crawls with aggregation turned off" do
    create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")

    DailyPriceUpdateJob.perform_now

    job = enqueued_jobs.find { |j| j["job_class"] == "CrawlPharmacyJob" }
    assert job, "expected a CrawlPharmacyJob to be enqueued"
    options = job["arguments"].last
    assert_equal false, options["aggregate"],
      "the scheduled crawl must not run Claude aggregation - that would spend money unattended"
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

  test "CrawlPharmacyJob aggregates only when explicitly asked" do
    create_pharmacy(slug: "benavides", name: "Benavides")

    with_noop_crawler("benavides") do
      assert_enqueued_jobs 1, only: NormalizeAndBuildOffersJob do
        CrawlPharmacyJob.perform_now("benavides", city: "Morelia, Michoacán", aggregate: true)
      end
    end
  end
end

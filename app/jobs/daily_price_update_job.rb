# Nightly crawl, scheduled in config/recurring.yml.
#
# Crawls every pharmacy the site actually displays. This was scoped to Del Ahorro
# alone for a while, on the reasoning that the others were "already fully crawled" -
# true of their catalogues, but not of their prices, which is the entire point of
# the site. The result was a homepage saying "Actualizado hoy" over figures ten days
# old, so the scope is now the displayed set.
#
# Crawling only. Aggregation - the step that turns listings into the offers people
# see - is queued separately and deliberately does NOT enable the paid Claude tier:
# see NormalizeAndBuildOffersJob and MedicationNormalizer#use_claude?. Unmatched
# names wait for a manual export instead of billing unattended.
#
# Pharmacies are staggered rather than fired at once: the headless browser shares a
# small machine with the web server, and several concurrent crawls made the site
# unresponsive.
class DailyPriceUpdateJob < ApplicationJob
  queue_as :crawling

  CITY = "Morelia, Michoacán".freeze

  # Minutes between each pharmacy's crawl. Del Ahorro alone can take 25-40 minutes,
  # so this spreads the night's work rather than stacking it.
  STAGGER = 12.minutes

  def perform
    Pharmacy.active.serving_morelia.order(:slug).each_with_index do |pharmacy, index|
      CrawlPharmacyJob.set(wait: STAGGER * index)
                      .perform_later(pharmacy.slug, city: CITY, aggregate: true)
    end
  end
end

class PagesController < ApplicationController
  # Bump this whenever the privacy notice's contents change.
  PRIVACY_LAST_UPDATED = Date.new(2026, 9, 12).freeze

  def privacy
  end

  # Only medications that actually have a purchasable offer are listed: a page with
  # no prices is a poor search result and spends crawl budget that the ~2,000 useful
  # pages need. Capped because sitemaps are limited to 50k URLs.
  SITEMAP_LIMIT = 40_000

  def sitemap
    @medications = Medication.where(id: Offer.active.purchasable.select(:medication_id))
                             .order(:id)
                             .limit(SITEMAP_LIMIT)
    # Cached for a day - the set only changes when a crawl runs, and this query
    # touches every offer.
    expires_in 1.day, public: true
    render layout: false, formats: [ :xml ]
  end
end

class PageVisit < ApplicationRecord
  belongs_to :medication, optional: true

  PAGE_TYPES = %w[home search medication other].freeze

  validates :visitor_hash, :path, :visited_at, presence: true

  scope :humans, -> { where.not(device_type: "bot") }
  scope :today, -> { where(visited_at: Time.current.all_day) }
  scope :since, ->(time) { where(visited_at: time..) }

  # Crawler traffic is filtered here rather than blocked at the edge. That was a
  # deliberate choice (2026-09-10): the price data is public by design, search
  # engines are wanted, and a scraper pretending to be Safari can't be blocked by
  # user agent without blocking real iPhones. Rate limiting remains the option if
  # the load ever matters - the problem today is only that the numbers mislead.
  #
  # User-agent matching alone badly overcounts: measured on real traffic, 325 of
  # 466 "human" views in one day came from three crawlers identifying as Chrome,
  # and another 19 "visitors" were single hits on / from datacentres worldwide
  # (uptime checks, scanners, link previewers). That turned an audience of about
  # nine people into a reported 31.
  #
  # These two thresholds catch what the user agent cannot:
  SWEEP_MIN_VIEWS = 8      # below this, a one-view-per-path pattern is just a short visit
  SWEEP_PATH_RATIO = 0.6   # views spread across mostly-distinct paths = never revisits
  POLLER_MIN_VIEWS = 4     # repeated loads of / and nothing else = an uptime monitor
  MIN_SECONDS_PER_PAGE = 4 # faster than this across many pages is fetching, not reading

  # A scraper polling on a fixed timer defeats every check above: it revisits pages
  # (so it isn't a sweeper) and reads many different ones (so it isn't a poller).
  # What gives it away is regularity. One observed in production presented as
  # iPhone Safari, fetched a page every ~9 minutes for 23 hours, and visited each of
  # 28 medication pages EXACTLY twice - a pattern no person produces.
  METRONOME_MIN_VIEWS = 20      # need enough intervals for the spread to mean anything
  METRONOME_MAX_STDDEV = 6.0    # minutes; human gaps vary far more than this
  METRONOME_LONG_GAP = 20       # minutes; breaks between sessions, excluded from the test

  def self.metronomes(counts, scope)
    counts.select do |hash, views|
      next false if views < METRONOME_MIN_VIEWS

      times = scope.where(visitor_hash: hash).order(:created_at).pluck(:created_at)
      # Within-session gaps only - the pauses between sessions say nothing about
      # whether the requests themselves are on a timer.
      gaps = times.each_cons(2).map { |a, b| (b - a) / 60.0 }.select { |g| g < METRONOME_LONG_GAP }
      next false if gaps.size < METRONOME_MIN_VIEWS

      mean = gaps.sum / gaps.size
      # A burst of near-instant requests is a sweeper, not a timer; leave it to that
      # check rather than calling anything with low variance a metronome.
      next false if mean < 1.0

      stddev = Math.sqrt(gaps.map { |g| (g - mean)**2 }.sum / gaps.size)
      stddev < METRONOME_MAX_STDDEV
    end.keys
  end

  # Visitor hashes whose behaviour is machine-like regardless of what they claim to
  # be. A person reloads, goes back, and returns to the same page; a crawler walks
  # each URL once. Returns hashes to EXCLUDE.
  def self.machine_visitor_hashes(scope)
    counts = scope.group(:visitor_hash).count
    sweepers = counts.select do |hash, views|
      next false if views < SWEEP_MIN_VIEWS

      visits = scope.where(visitor_hash: hash)
      next false if visits.distinct.count(:path) < views * SWEEP_PATH_RATIO

      # A person reading pages needs time. Anything averaging under a few seconds
      # per page across many pages is fetching, not reading - this is what separates
      # "30 pages in 3 minutes" from someone genuinely browsing the catalogue.
      span = visits.maximum(:created_at) - visits.minimum(:created_at)
      # A zero span means the timestamps carry no information (fixtures, or a burst
      # recorded within the same second). Fall back to the path pattern alone.
      next true if span.zero?

      span / views < MIN_SECONDS_PER_PAGE
    end.keys

    # A single view of the homepage and nothing else, never returning. Real first-time
    # visitors overwhelmingly click at least one medication.
    probes = counts.select { |_, views| views == 1 }.keys
    probes = scope.where(visitor_hash: probes, path: "/").distinct.pluck(:visitor_hash)

    # Hits ONLY the homepage, over and over. Uptime monitors and the platform's own
    # health check produce exactly this: dozens of loads of / spread across a day,
    # never once clicking through to a medication. A person who genuinely only ever
    # loads the homepage is indistinguishable from a monitor and is not an audience.
    # NB: the homepage-only test must be a HAVING over all of the visitor's rows.
    # Filtering with .where(path: "/") before grouping computes COUNT(DISTINCT path)
    # across homepage rows only, which is trivially 1 - that matched every visitor
    # who loaded / four times, including people who also read medication pages.
    pollers = scope.group(:visitor_hash)
                   .having("COUNT(DISTINCT path) = 1 AND MIN(path) = '/' AND COUNT(*) >= ?", POLLER_MIN_VIEWS)
                   .pluck(:visitor_hash)

    sweepers | probes | pollers | metronomes(counts, scope)
  end

  # Human traffic with machine-like behaviour removed as well as declared bots.
  # This is the number to quote: `humans` alone is an overcount.
  def self.real_people(scope = humans)
    excluded = machine_visitor_hashes(scope)
    excluded.any? ? scope.where.not(visitor_hash: excluded) : scope
  end

  # The visitor id is a one-way hash - see the migration for why. Rotating the
  # salt daily means the same person gets a different id tomorrow, which caps how
  # long any behavioural trail can be followed while still allowing same-day
  # repeat-visit counts. Without this, a stable hash is effectively a permanent
  # pseudonymous identifier tied to someone's medication searches.
  def self.visitor_hash_for(ip:, user_agent:, on: Date.current)
    secret = Rails.application.secret_key_base
    Digest::SHA256.hexdigest("#{ip}|#{user_agent}|#{on.iso8601}|#{secret}")
  end

  # --- Reporting helpers -----------------------------------------------------

  # Most-visited paths, with how many distinct people visited each.
  def self.popular_pages(since: 30.days.ago, limit: 20)
    real_people(humans.since(since))
          .group(:path)
          .select("path, COUNT(*) AS views, COUNT(DISTINCT visitor_hash) AS visitors")
          .order("views DESC")
          .limit(limit)
  end

  # What people actually search for - the most directly useful signal here, since
  # it says which medications to prioritise crawling.
  def self.popular_searches(since: 30.days.ago, limit: 20)
    real_people(humans.since(since))
          .where.not(search_query: [ nil, "" ])
          .group(:search_query)
          .order(Arel.sql("COUNT(*) DESC"))
          .limit(limit)
          .count
  end

  def self.popular_medications(since: 30.days.ago, limit: 20)
    real_people(humans.since(since))
          .where.not(medication_id: nil)
          .group(:medication_id)
          .order(Arel.sql("COUNT(*) DESC"))
          .limit(limit)
          .count
  end

  # How many visits each visitor made, bucketed - shows whether people come back.
  def self.visit_frequency(since: 30.days.ago)
    counts = real_people(humans.since(since)).group(:visitor_hash).count.values
    {
      "1 visit" => counts.count { |c| c == 1 },
      "2-5 visits" => counts.count { |c| c.between?(2, 5) },
      "6-20 visits" => counts.count { |c| c.between?(6, 20) },
      "20+ visits" => counts.count { |c| c > 20 }
    }
  end

  def self.summary(since: 30.days.ago)
    declared_human = humans.since(since)
    scope = real_people(declared_human)
    {
      views: scope.count,
      visitors: scope.distinct.count(:visitor_hash),
      bots_excluded: since(since).where(device_type: "bot").count,
      # Shown so the filtering is auditable rather than a number to trust blindly.
      undeclared_bot_views: declared_human.count - scope.count,
      undeclared_bot_sources: declared_human.distinct.count(:visitor_hash) - scope.distinct.count(:visitor_hash),
      by_device: scope.group(:device_type).count,
      by_page_type: scope.group(:page_type).count,
      top_referrers: scope.where.not(referrer_host: nil).group(:referrer_host).order(Arel.sql("COUNT(*) DESC")).limit(5).count,
      direct_views: scope.where(referrer_host: nil).count,
      by_edge_region: scope.where.not(edge_region: nil).group(:edge_region).order(Arel.sql("COUNT(*) DESC")).limit(8).count
    }
  end
end

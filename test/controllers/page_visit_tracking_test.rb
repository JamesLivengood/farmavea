require "test_helper"

class PageVisitTrackingTest < ActionDispatch::IntegrationTest
  test "records a visit to the homepage" do
    assert_difference "PageVisit.count", 1 do
      get root_path
    end

    visit = PageVisit.last
    assert_equal "/", visit.path
    assert_equal "home", visit.page_type
    assert_not_nil visit.visited_at
  end

  test "records the medication being viewed" do
    pharmacy = create_pharmacy
    medication = create_medication
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    get medication_path(medication)

    visit = PageVisit.last
    assert_equal "medication", visit.page_type
    assert_equal medication.id, visit.medication_id
  end

  test "records what was searched for" do
    get search_path, params: { q: "paracetamol" }

    visit = PageVisit.last
    assert_equal "search", visit.page_type
    assert_equal "paracetamol", visit.search_query
  end

  test "never stores a raw IP address" do
    get root_path

    visit = PageVisit.last
    # The whole point of the hash: nothing here should be reversible to a person.
    assert_no_match(/\d+\.\d+\.\d+\.\d+/, visit.attributes.values.join(" "),
      "a raw IP must never be persisted")
    assert_equal 64, visit.visitor_hash.length, "expected a SHA256 hex digest"
  end

  test "the same visitor gets a stable id within a day" do
    headers = { "REMOTE_ADDR" => "203.0.113.9", "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Safari" }

    get root_path, headers: headers
    first = PageVisit.last.visitor_hash
    get search_path(q: "test"), headers: headers
    second = PageVisit.last.visitor_hash

    assert_equal first, second, "repeat visits must be countable"
  end

  test "different visitors get different ids" do
    get root_path, headers: { "REMOTE_ADDR" => "203.0.113.9", "HTTP_USER_AGENT" => "Mozilla/5.0 A" }
    first = PageVisit.last.visitor_hash
    get root_path, headers: { "REMOTE_ADDR" => "198.51.100.4", "HTTP_USER_AGENT" => "Mozilla/5.0 B" }
    second = PageVisit.last.visitor_hash

    assert_not_equal first, second
  end

  test "the visitor id rotates daily so no long-term trail exists" do
    today = PageVisit.visitor_hash_for(ip: "203.0.113.9", user_agent: "UA", on: Date.current)
    tomorrow = PageVisit.visitor_hash_for(ip: "203.0.113.9", user_agent: "UA", on: Date.current + 1)

    assert_not_equal today, tomorrow,
      "a stable hash would be a permanent pseudonymous id tied to medication searches"
  end

  test "classifies device types" do
    get root_path, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7) Mobile Safari" }
    assert_equal "phone", PageVisit.last.device_type

    get root_path, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPad) Safari" }
    assert_equal "tablet", PageVisit.last.device_type

    get root_path, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Chrome/124" }
    assert_equal "desktop", PageVisit.last.device_type

    get root_path, headers: { "HTTP_USER_AGENT" => "facebookexternalhit/1.1" }
    assert_equal "bot", PageVisit.last.device_type
  end

  test "stores only the referrer host, not the full URL" do
    get root_path, headers: { "HTTP_REFERER" => "https://www.google.com/search?q=something+private" }

    visit = PageVisit.last
    assert_equal "www.google.com", visit.referrer_host
    assert_no_match(/private/, visit.referrer_host.to_s)
  end

  test "ignores internal referrers" do
    get root_path, headers: { "HTTP_REFERER" => "https://farmavea.com/medications/3" }
    assert_nil PageVisit.last.referrer_host
  end

  test "does not track the autocomplete endpoint" do
    assert_no_difference "PageVisit.count" do
      get autocomplete_path, params: { q: "para" }, as: :json
    end
  end

  test "a tracking failure never breaks the page" do
    # Force the insert to fail the way a real outage would (missing table),
    # and assert the visitor still gets their page.
    #
    # Wrapped in a savepoint: the failing insert aborts the surrounding test
    # transaction, which would otherwise make the rename-back fail too and leave
    # the table missing for every test that runs after this one.
    conn = ActiveRecord::Base.connection
    conn.execute("SAVEPOINT tracking_failure")
    conn.execute("ALTER TABLE page_visits RENAME TO page_visits_tmp")

    begin
      get root_path
      assert_response :success, "analytics must never take a page down"
    ensure
      conn.execute("ROLLBACK TO SAVEPOINT tracking_failure")
    end

    assert_predicate PageVisit, :table_exists?, "the table must be restored for later tests"
  end

  test "bots are excluded from the humans scope" do
    get root_path, headers: { "HTTP_USER_AGENT" => "facebookexternalhit/1.1" }
    get root_path, headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Chrome/124" }

    assert_equal 1, PageVisit.humans.count
  end

  # `country` originally stored Fly-Region, the datacentre that served the request.
  # A Morelia visitor routed through Amsterdam was recorded as "ams", so the column
  # read as international traffic the site does not actually have. Fly sends no
  # country header at all (verified in production), so country must stay nil rather
  # than silently falling back to the region again.
  # A crawler sending a Chrome user agent passes the `humans` scope. Behaviour is
  # what gives it away: it walks many distinct URLs and never revisits one.
  test "a browser-spoofing crawler is excluded from real_people" do
    hash = "spoofer"
    12.times do |i|
      PageVisit.create!(visitor_hash: hash, path: "/medications/#{i}", page_type: "medication",
                        device_type: "desktop", browser: "Chrome", visited_at: Time.current)
    end

    assert_equal 12, PageVisit.humans.count, "it passes the user-agent filter"
    assert_equal 0, PageVisit.real_people(PageVisit.humans).count, "but not the behavioural one"
  end

  test "a real person revisiting pages is kept" do
    now = Time.current
    # Same few pages, revisited - the pattern a person actually produces.
    %w[/ /medications/1 / /medications/2 / /medications/1 / /medications/3 / /].each_with_index do |path, i|
      PageVisit.create!(visitor_hash: "person", path: path, page_type: "other",
                        device_type: "phone", browser: "Safari",
                        visited_at: now, created_at: now - (i * 45).seconds)
    end

    assert_equal 10, PageVisit.real_people(PageVisit.humans).count
  end

  test "a single homepage hit that never returns is treated as a probe" do
    PageVisit.create!(visitor_hash: "probe", path: "/", page_type: "home",
                      device_type: "desktop", browser: "Chrome", visited_at: Time.current)

    assert_equal 0, PageVisit.real_people(PageVisit.humans).count
  end

  test "an uptime monitor loading only the homepage is excluded" do
    now = Time.current
    10.times do |i|
      PageVisit.create!(visitor_hash: "monitor", path: "/", page_type: "home",
                        device_type: "desktop", browser: "Chrome",
                        visited_at: now, created_at: now - (i * 2).hours)
    end

    assert_equal 0, PageVisit.real_people(PageVisit.humans).count
  end

  # The heaviest genuine visitor observed in production: many pages over a full day,
  # returning to the homepage between each one. Tightening the crawler thresholds
  # must not sweep this person up.
  test "someone browsing many pages slowly over a day is kept" do
    now = Time.current
    32.times do |i|
      path = i.even? ? "/" : "/medications/#{i}"
      PageVisit.create!(visitor_hash: "real", path: path, page_type: "other",
                        device_type: "phone", browser: "Safari",
                        visited_at: now, created_at: now - (i * 20).minutes)
    end

    assert_equal 32, PageVisit.real_people(PageVisit.humans).count
  end

  # Modelled on a real one: iPhone Safari, a page every ~9 minutes for 23 hours,
  # each medication page hit exactly twice. It revisits pages and reads many of
  # them, so only the regularity of the interval identifies it.
  test "a scraper polling on a fixed timer is excluded" do
    now = Time.current
    30.times do |i|
      # ~9 min apart with a little jitter, the way a real scheduler drifts.
      offset = (i * 9).minutes + (i % 3).minutes
      PageVisit.create!(visitor_hash: "metronome", path: "/medications/#{i % 15}",
                        page_type: "medication", device_type: "phone", browser: "Safari",
                        visited_at: now, created_at: now - offset)
    end

    assert_equal 0, PageVisit.real_people(PageVisit.humans).count
  end

  test "a person browsing at irregular intervals is kept" do
    now = Time.current
    # Human gaps vary wildly: seconds, then minutes, then a long pause.
    gaps = [ 0, 1, 5, 6, 25, 26, 27, 31, 90, 92, 95, 140, 141, 200, 260,
             262, 300, 380, 390, 500, 505, 600, 700, 705, 900 ]
    gaps.each_with_index do |mins, i|
      PageVisit.create!(visitor_hash: "irregular", path: "/medications/#{i % 8}",
                        page_type: "medication", device_type: "phone", browser: "Safari",
                        visited_at: now, created_at: now - mins.minutes)
    end

    assert_equal gaps.size, PageVisit.real_people(PageVisit.humans).count
  end

  test "a short genuine visit is not mistaken for a crawler" do
    hash = "brief"
    # Under SWEEP_MIN_VIEWS: too little evidence to call it machine-like.
    %w[/ /medications/1 /medications/2].each do |path|
      PageVisit.create!(visitor_hash: hash, path: path, page_type: "other",
                        device_type: "phone", browser: "Safari", visited_at: Time.current)
    end

    assert_equal 3, PageVisit.real_people(PageVisit.humans).count
  end

  test "the datacentre region is never recorded as the visitor's country" do
    get root_path, headers: { "HTTP_FLY_REGION" => "ams" }

    visit = PageVisit.last
    assert_nil visit.country, "country must not fall back to the Fly region"
    assert_equal "ams", visit.edge_region
  end
end

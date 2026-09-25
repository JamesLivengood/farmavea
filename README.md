# Farmavea

[farmavea.com](https://farmavea.com) — compares medication prices across Mexican
pharmacies and shows which is genuinely cheapest.

Currently scoped to Morelia, Michoacán.

## Why price-per-mg

A 500mg box of 20 tablets and a 250mg box of 10 are not comparable on box price,
and that is how most price comparisons mislead. Farmavea ranks by **price per
milligram of active ingredient**, so the cheapest result is actually the cheapest.

This depends on knowing the pack quantity. When a listing does not state how many
tablets are in the box, the price-per-mg is recorded as `nil` rather than assuming
one — a missing number is honest, a confidently wrong one on a page people use to
decide where to spend money is not.

## How it works

**Crawling.** Each pharmacy has its own crawler. Most are plain HTTP + Nokogiri;
sites behind a WAF need a headless browser via Ferrum. Crawlers return raw listings
and never interpret them.

**Matching.** Scraped product names are messy ("Zemiduo Sr 50/1000Mg Tab 28") and
must be resolved to a medication. Three tiers, cheapest first:

1. `NameMapping` — a cache of names already identified. Free.
2. `LocalMedicationMatcher` — regex extraction of known names, strengths and pack
   sizes. Free.
3. `ClaudeMedicationMatcher` — the Claude API, for what the first two miss. Paid,
   so it is a last resort, with prompt caching and a retry window on rejections.

There is also a manual path (`script/export_for_manual_matching.rb`) that exports
pending names as a ready-to-paste prompt, for review in a browser at no API cost.

**Aggregation.** Resolved listings become offers with a computed price-per-mg.
Only the latest crawl run per pharmacy is aggregated, so stale prices never show.

## Analytics and privacy

Visitors are counted with a SHA256 hash of IP + user agent + date + secret, and the
date component means the hash rotates daily — same-day repeat visits can be counted,
but no visitor can be followed across days. Raw IPs and user agents are never stored.
On a site where the searches are medication names, that matters.

Crawler traffic is filtered at report time rather than blocked: search engines are
wanted, and a scraper claiming to be iPhone Safari cannot be blocked by user agent
without blocking real iPhones. See `PageVisit.machine_visitor_hashes` — user-agent
matching alone overcounted real traffic by roughly 3x.

## Stack

Rails 8.1 · Ruby 3.4 · PostgreSQL · Hotwire · Tailwind v4 · Solid Queue/Cache/Cable ·
Ferrum · deployed on Fly.io

## Development

```bash
bin/setup          # install dependencies, prepare the database
bin/dev            # start the app
bin/rails test     # run the test suite
```

Crawling a single pharmacy locally:

```bash
bin/rails runner 'Crawlers::DelAhorroCrawler.new(pharmacy: Pharmacy.find_by(slug: "del_ahorro"), crawl_run: CrawlRun.create!(pharmacy: Pharmacy.find_by(slug: "del_ahorro"), started_at: Time.current)).call'
```

A headless Chrome or Chromium binary is required for the browser-driven crawlers;
`Crawlers::BaseCrawler::BROWSER_PATHS` lists where it is looked for, and
`FERRUM_BROWSER_PATH` overrides it.
# farmavea

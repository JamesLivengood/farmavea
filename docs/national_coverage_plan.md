# Scope: national coverage (deferred)

Not started. Written 2026-09-05 so the reasoning isn't lost.

## Key finding that shapes this

Prices do **not** vary by location. Verified 2026-09-05 across **588 products**:

| Pharmacy | Products compared | Price differences |
|---|---|---|
| Benavides | 182 | 0 |
| Chedraui | 120 | 0 |
| Similares | 96 | 0 |
| Costco | 94 | 0 |
| Probemedic | 64 | 0 |
| Farmalisto | 20 | 0 |
| Del Ahorro | 12 | 0 |

Method: each page fetched twice — once plainly, once with Morelia postal-code
cookies (CP 58000) and a Mexican `X-Forwarded-For`. Del Ahorro tested through a
real rendered product page since its WAF blocks plain HTTP.

**Methodology note:** a first pass keyed on product *name* appeared to find 11
differences at Benavides. That was an artifact — Benavides lists several distinct
products under identical names (three different "10 mg Zolpidem"). Keyed on
product URL instead: zero. Any future re-test must key on URL or product ID,
never on name.

So we do NOT need to re-crawl per city, and the crawler does not need to appear
to be in Morelia. What varies by city is only **which pharmacies a user can
actually buy from** - a filtering/UX problem, not a data-collection one.

## What has to change

### 1. Pharmacy → city coverage data (the bulk of the work)

Today this is one hardcoded array, `Pharmacy::SERVES_MORELIA_SLUGS`. Needed: which
chains operate where.

- New `pharmacy_locations` table (pharmacy, city, state), or a coarser
  state-level `coverage` column if city granularity isn't needed.
- Populating it for 17 chains is the largest piece. Several sites publish store
  locators that could be scraped (Benavides ships Amasty_Storelocator; YZA and
  San Pablo have `/sucursales` pages) so it's partly automatable.
- **Scrape the locators rather than trusting web search.** The current Morelia
  exclusions were derived from search results and are only as good as that.
- Online-only pharmacies (Farmalisto, Vitau) are "ships nationwide" and always
  included regardless of city.

### 2. City selection UX

- City picker in the header, persisted in a cookie/session.
- Default via IP geolocation, or default to the largest market (CDMX) with an
  obvious way to change it.
- Only 4 call sites read `MedicationsController::DEFAULT_CITY` today, so wiring
  the selected city through is trivial.

### 3. The `city` column decision (decide deliberately)

`city` is already a `null: false` column on both `offers` and `crawl_runs`, and
every existing row says "Morelia, Michoacán". `offers` also has a unique index on
`raw_listing_id` (one offer per scraped listing).

- **Option A — keep `city` on offers, one row per city.** Faithful to the current
  schema but multiplies 32k offers by the number of cities (~50 cities ≈ 1.6M
  rows) all storing *identical* prices. The unique index on `raw_listing_id`
  would have to go.
- **Option B (recommended) — drop `city` from offers.** Offers become national,
  which is what the evidence says they factually are. City becomes purely a
  display filter applied through pharmacy coverage. No data multiplication, and
  it stops modelling a fiction. Needs a migration plus care with
  `NormalizeAndBuildOffersJob#deactivate_stale_offers`, which currently scopes on
  city.

## Effort

| Piece | Effort |
|---|---|
| Coverage table + migration | Small |
| Researching/populating 17 chains' footprints | **Largest** — ~a day, partly scriptable |
| City picker UI + session persistence | Small-medium |
| Option B migration (drop city from offers) | Medium; care needed around stale-offer logic |
| Tests + deploy | Small |

## Risks

- **Coverage data is the weak link.** If it's wrong, users see prices they can't
  act on — exactly the problem the Morelia filter was added to fix.
- **Availability ≠ price.** We verified prices are national. We did NOT verify
  that products are stocked/deliverable everywhere. A national claim implicitly
  asserts this, and it's untested.
- **Positioning.** "Precios en Morelia" is a sharper hook than a generic national
  site; going national trades focus for reach.

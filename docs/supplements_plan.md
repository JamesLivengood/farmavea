# Scope: adding supplements (deferred)

Not started. Written 2026-09-07 from real numbers measured against the live data,
so the reasoning survives.

## The core problem

The site's value is "cheapest per mg of the same active ingredient". That holds for
medications because two boxes of Ibuprofeno 400mg are genuinely interchangeable.
Supplements mostly break that assumption:

- **Multi-ingredient by nature.** "Complejo B" is eight vitamins at different doses -
  there is no single mg to divide by. Confirmed in the data: these resolve to
  `strength_value: 0, strength_unit: "unit"`, so `price_per_mg` is nil and they
  cannot be ranked at all by the site's only ranking mechanism.
- **Not interchangeable the way generics are.** Two 1000mg Omega-3 products differ
  in EPA/DHA content, form and absorption. Ranking them purely on price implies an
  equivalence that may not hold, and this is health-adjacent.
- **The cosmetics trap.** Roughly 40% of keyword matches are face serum and leg
  cream that merely mention colágeno or vitamina C.

## What the data actually shows (measured 2026-09-07)

Supplement-ish raw listings already being crawled: **~1,494** of 51,252.

| Keyword | Listings |
|---|---|
| vitamina | 321 |
| melatonina | 289 |
| suplemento | 272 |
| hierro | 171 |
| zinc | 165 |
| magnesio | 79 |
| proteína/proteina | 60 |
| colágeno/colageno | 36 |
| omega | 25 |
| others (creatina, biotina, calcio, probióticos, multivitamínico) | ~76 |

Sampling 137 distinct supplement names through the existing pipeline:

- **28 resolved** into a Medication (~20%)
- **103 rejected** as unresolved (~75%)
- 6 never processed

Crucially, most that *did* resolve are drug/vitamin combos ("Dolo-Neurobión Forte
con Diclofenaco y Vitaminas") - they resolved because they contain a real
medication, not because the supplement itself was understood.

Rejections are all confidence-threshold misses (0.45-0.75, threshold 0.80), on a
mix of two very different things:

- Legitimate supplements Claude wouldn't commit to: "Redoxon AOX Vitamina C 10
  Tabletas Efervescentes", "Cápsulas Natures Life Omega 3 Frasco con 65 Cápsulas"
- Cosmetics that merely mention a supplement word, and must NEVER become
  comparable products: "Crema para Piernas Goicoechea Reafirmante Colágeno",
  "Sérum Facial Babaria de Vitamina C 30ml", "Sérum Corporal Derman Colágeno"

## What already works in our favour

- The ~1,494 listings are already being crawled - **no crawler work needed**
- The pipeline already processes them; it just rejects most at the threshold
- `pack_quantity` and `price_per_pill` already work for supplements, since they're
  usually tablets or capsules

## What would need building

### 1. A product-type distinction (foundational)

Everything is a `Medication` today. Add `product_type` - `medication` /
`supplement` / `excluded` - because supplements need different ranking, different
disclaimers and different search treatment. `excluded` gives cosmetics an explicit
home rather than leaving them to fail silently at the confidence threshold.

### 2. Change the comparison metric

Price-per-mg does not work for multi-ingredient supplements. The honest metric is
**price per serving/tablet**, which `Offer#price_per_pill` already computes - so
supplement pages rank by that instead. Less work than it sounds.

### 3. A supplement-specific Claude prompt

The current prompt asks for "the ACTIVE INGREDIENT", which is exactly why Redoxon
lands at 0.55 confidence. Supplements need their own extraction: identify the
supplement type, the headline nutrient and dose where one exists, and explicitly
classify cosmetics as excluded. Likely a second tool schema rather than overloading
MATCH_TOOL.

### 4. Re-aggregation pass

~1,500 listings, most currently unresolved. At measured rates (~67 output tokens
per name, Opus pricing) roughly **$5-8**.

### 5. UI and honesty work

A separate section or filter (people search for supplements differently), and a
different disclaimer - comparing supplements on price alone is more misleading than
comparing generic drugs, because formulations genuinely differ.

## Effort

| Piece | Size |
|---|---|
| `product_type` column + migration | Small |
| Supplement-specific Claude prompt/schema | Medium |
| Rank by price-per-serving | Small - the field already exists |
| Cosmetics exclusion rules | Medium - this is where accuracy is won or lost |
| Re-aggregation (~1,500 names) | ~$5-8, a few hours unattended |
| UI: section, filters, disclaimer | Medium |

Roughly **1-2 days plus ~$8**.

## The main risk

The cosmetics filter is where this succeeds or fails. If "Sérum Facial Babaria de
Vitamina C" appears ranked beside actual vitamin C tablets, the site looks
unreliable in a way that undermines confidence in the medication data too. The
filter should be deliberately conservative: better to exclude a real supplement
than to admit a face cream.

## Suggested order

1. `product_type` column, defaulting everything existing to `medication` (no
   behaviour change, nothing to re-run)
2. Cosmetics exclusion rules + tests, verified against the real rejected names
   above before spending anything on Claude
3. Supplement prompt, tested on a small sample first (script/test_claude_matching.rb
   is the pattern - cheap, verifies correctness before scaling)
4. Full re-aggregation once the sample looks right
5. UI last, once the data is trustworthy

class Offer < ApplicationRecord
  belongs_to :medication
  belongs_to :pharmacy
  belongs_to :raw_listing

  validates :city, presence: true
  validates :price_cents, presence: true, numericality: { greater_than: 0 }
  validates :scraped_at, presence: true

  scope :active, -> { where(active: true) }
  scope :cheapest_first, -> { order(:price_per_mg) }

  # Only offers from pharmacies a Morelia shopper can actually buy from - see
  # Pharmacy::SERVES_MORELIA_SLUGS. Every user-facing query should chain this;
  # offers from other pharmacies stay in the database but are never displayed.
  scope :purchasable, -> { where(pharmacy: Pharmacy.serving_morelia) }

  # Collapses offers that are really the same product listed more than once, so a
  # medication page doesn't show the same thing repeated. Two sources of this:
  #
  #   1. The identical product_url stored several times - stale data from crawl
  #      runs that predate the cross-category de-duplication fix in
  #      MagentoCategoryCrawler (Benavides listed each product under every
  #      category it belongs to).
  #   2. Genuinely different URLs/product IDs on the pharmacy's own site for what
  #      is plainly the same product at the same price - Farmacias Guadalajara
  #      does this (e.g. clonazepam-...-1357972 and -1408771, same name, same
  #      price, different photos).
  #
  # Deliberately keyed on price as well as name: the same name at a DIFFERENT
  # price is a real, distinct offer a shopper might want (a genuine second listing
  # at a better price), so those are kept. Nothing is deleted - this only affects
  # what's displayed.
  #
  # Two listings count as the same product when they share a pharmacy and name AND
  # their prices are within this much of each other. Measured on real data: of 710
  # same-pharmacy-same-name groups, 129 are near-identical prices (the duplicate
  # listings above) while 581 differ meaningfully - those are real alternatives a
  # shopper should still see, so price stays part of the identity.
  DUPLICATE_PRICE_TOLERANCE = 0.02

  # Takes an already-ordered collection and keeps the first of each group, so
  # chaining after .cheapest_first keeps the cheapest of any duplicate set.
  def self.deduplicated(offers)
    kept = []
    offers.each do |offer|
      duplicate = kept.any? { |seen| seen.duplicate_of?(offer) }
      kept << offer unless duplicate
    end
    kept
  end

  # Same pharmacy, same product name, and a price within DUPLICATE_PRICE_TOLERANCE -
  # i.e. the same physical product listed twice, not a genuinely cheaper alternative.
  def duplicate_of?(other)
    return false unless pharmacy_id == other.pharmacy_id
    return false unless raw_listing&.raw_name == other.raw_listing&.raw_name

    cheaper = [ price_cents, other.price_cents ].min
    return true if cheaper.zero?

    ((price_cents - other.price_cents).abs.to_f / cheaper) <= DUPLICATE_PRICE_TOLERANCE
  end

  def price
    price_cents / 100.0
  end

  # Price for a single tablet/capsule, or nil when the pack size isn't known (only
  # a minority of listings state one in a form we can parse - see
  # LocalMedicationMatcher::PACK_QUANTITY_PATTERNS). Returns nil rather than
  # falling back to the whole-box price, which would read as a wildly overpriced
  # single pill.
  def price_per_pill
    quantity = raw_listing&.pack_quantity.to_i
    return nil unless quantity > 1

    (price / quantity).round(2)
  end

  # The dosage-form word this product's own listing uses, matched to how Mexican
  # pharmacies write it, so a capsule is never labelled a "tableta". Ordered
  # longest-first so "comprimido" isn't shadowed by a shorter partial match.
  # Falls back to "pieza" (the neutral retail term) when the name doesn't say -
  # e.g. an ampoule, sachet, or a name that only states a count.
  #
  # Each entry is [regexp, singular, plural].
  UNIT_WORDS = [
    [ /c[aá]psulas?/i,   "cápsula",    "cápsulas" ],
    [ /comprimidos?/i,   "comprimido", "comprimidos" ],
    [ /tabletas?/i,      "tableta",    "tabletas" ],
    [ /grageas?/i,       "gragea",     "grageas" ],
    [ /pastillas?/i,     "pastilla",   "pastillas" ],
    [ /sobres?/i,        "sobre",      "sobres" ],
    [ /ampolletas?/i,    "ampolleta",  "ampolletas" ],
    [ /[oó]vulos?/i,     "óvulo",      "óvulos" ],
    [ /parches?/i,       "parche",     "parches" ]
  ].freeze

  DEFAULT_UNIT = [ "pieza", "piezas" ].freeze

  # ["cápsula", "cápsulas"] etc - singular for "cada X", plural for "N X".
  def unit_words
    name = raw_listing&.raw_name.to_s
    match = UNIT_WORDS.find { |pattern, _singular, _plural| name.match?(pattern) }
    match ? [ match[1], match[2] ] : DEFAULT_UNIT
  end

  def unit_singular = unit_words.first
  def unit_plural = unit_words.last
end

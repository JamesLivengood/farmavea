class Pharmacy < ApplicationRecord
  has_many :crawl_runs, dependent: :destroy
  has_many :raw_listings, dependent: :destroy
  has_many :name_mappings, dependent: :destroy
  has_many :offers, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :base_url, presence: true

  # Pharmacies whose prices a Morelia shopper can actually act on - either they have
  # a physical branch in Morelia, or they're an online pharmacy that ships nationwide.
  # Researched 2026-09-05; everything not listed here is still CRAWLED and STORED
  # (the data stays useful for price history and for other cities later) but is
  # hidden from the site, because showing a price a local shopper can't buy at -
  # and possibly ranking it as "cheapest" - is worse than showing nothing.
  #
  # On the "Morelia" price label: verified 2026-09-05 that none of these sites
  # personalize prices by location. Each was fetched twice - once plainly, once with
  # Morelia postal-code cookies (CP 58000) and a Mexican X-Forwarded-For - and every
  # one returned byte-identical prices: Benavides, Chedraui, Costco, Del Ahorro
  # (via a real rendered product page, since its WAF blocks plain HTTP), Farmacia
  # Similares, Farmalisto, Probemedic. Benavides does load an Amasty_Storelocator
  # asset, but that is a "find your branch" map with no effect on catalog pricing.
  # So the crawler does NOT need to appear to be in Morelia, and the city label is
  # accurate rather than aspirational. Worth re-checking if a site redesigns.
  #
  # Deliberately excluded, with reasons:
  #   heb            - operates in only 7 states; Michoacán is not one of them
  #   yza            - 17 states listed, Michoacán absent (concentrated in the south/peninsula)
  #   farmacias_abc  - CDMX/Monterrey/Guadalajara/León; no Michoacán presence found
  #   fesa           - nearest branch found is Zamora, Michoacán (~2hrs away), not Morelia
  #   probemedic, proasse, vida_farmacias, farmacia_emergencias
  #                  - footprint could not be confirmed either way; excluded until it is
  SERVES_MORELIA_SLUGS = %w[
    benavides
    san_pablo
    guadalajara
    del_ahorro
    farmacia_similares
    chedraui
    costco
    farmalisto
    vitau
  ].freeze

  scope :active, -> { where(active: true) }

  # The pharmacies whose offers are safe to show on the site - see
  # SERVES_MORELIA_SLUGS for why the rest are hidden rather than deleted.
  scope :serving_morelia, -> { where(slug: SERVES_MORELIA_SLUGS) }
end

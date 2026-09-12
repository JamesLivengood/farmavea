class MedicationsController < ApplicationController
  DEFAULT_CITY = "Morelia, Michoacán".freeze

  # The generic names people actually search for - common prescriptions and OTC
  # staples in Mexico. These are the ONLY medications the homepage lists: showing
  # all ~2,900 would bury them under obscure bulk/specialty products (the full list
  # sorts by peso-per-mg, which favors large-pack niche items), and makes for a
  # slow, unusable page. Everything else is reachable through search.
  COMMON_GENERIC_NAMES = [
    "Paracetamol", "Ibuprofeno", "Naproxeno", "Amoxicilina", "Azitromicina",
    "Omeprazol", "Losartán", "Metformina", "Atorvastatina", "Enalapril",
    "Metoprolol", "Amlodipino", "Sertralina", "Fluoxetina", "Escitalopram",
    "Alprazolam", "Clonazepam", "Levotiroxina", "Diclofenaco", "Ketorolaco",
    "Loratadina", "Cetirizina", "Salbutamol", "Prednisona", "Ciprofloxacino",
    "Insulina glargina", "Glibenclamida", "Furosemida", "Espironolactona", "Warfarina"
  ].freeze

  PER_PAGE = 60

  def index
    @city = DEFAULT_CITY
    @common_offers = common_medication_offers(city: @city)
    # Drives the freshness badge. The most recent scrape behind a visible offer is
    # the honest answer to "how current is this page?".
    @last_updated_at = Offer.active.purchasable.where(city: @city).maximum(:scraped_at)

    # Everything except the featured medications, paginated in the DATABASE.
    # Loading the whole list and slicing it in Ruby meant fetching ~1,580 offers
    # (plus their medication/pharmacy/raw_listing associations) to render 60 of
    # them - about 260ms of the homepage's response time spent on rows that were
    # then thrown away.
    featured_medication_ids = @common_offers.map(&:medication_id)
    scope = cheapest_offer_per_medication_scope(city: @city, excluding_medication_ids: featured_medication_ids)

    @page = [ params[:page].to_i, 1 ].max
    @total_pages = (count_distinct_medications(scope) / PER_PAGE.to_f).ceil
    @other_offers = paginated_cheapest_offers(scope, page: @page)
  end

  def search
    @query = params[:q].to_s.strip
    @city = DEFAULT_CITY

    if @query.blank?
      @medications = Medication.none
      return
    end

    @medications = Medication.search(@query).distinct.limit(50)
    @cheapest_by_medication_id = Offer.active.purchasable.where(city: @city, medication_id: @medications.map(&:id))
                                       .group(:medication_id)
                                       .minimum(:price_per_mg)
    @matched_brands = Medication.brand_matches_for(@query, @medications.map(&:id))
  end

  def show
    @medication = Medication.find(params[:id])
    @city = DEFAULT_CITY
    offers = @medication.offers.active.purchasable.where(city: @city)
                        .includes(:pharmacy, :raw_listing).cheapest_first
    @offers = Offer.deduplicated(offers)
  end

  # JSON suggestions for the search box's live autocomplete dropdown as the visitor
  # types - a lightweight subset of #search's matching, capped small since this
  # fires on every keystroke.
  def autocomplete
    query = params[:q].to_s.strip
    medications = query.present? ? Medication.search(query).distinct.limit(8) : Medication.none

    render json: medications.map { |m| { id: m.id, label: m.display_strength, url: medication_path(m) } }
  end

  private

  # The cheapest active offer for each of COMMON_GENERIC_NAMES, returned in that
  # list's order (a deliberate, stable order rather than by price). Queries only
  # those generics rather than loading the whole catalog and filtering in Ruby.
  # Combination products (e.g. "Paracetamol/Naproxeno") are excluded by the exact
  # name match - this row is for the plain single-ingredient medication people
  # search for by name.
  def common_medication_offers(city:)
    offers = Offer
      .select("DISTINCT ON (offers.medication_id) offers.*")
      .active
      .purchasable
      .where(city: city)
      .where(medication_id: Medication.where(canonical_name: COMMON_GENERIC_NAMES).select(:id))
      .includes(:medication, :pharmacy, :raw_listing)
      # NULLS LAST so an offer whose pack size we don't know (and therefore has no
      # comparable per-mg price) still gets picked when it's the only listing for a
      # medication, rather than that medication vanishing from the page entirely.
      .order(Arel.sql("offers.medication_id, offers.price_per_mg ASC NULLS LAST"))

    by_name = offers.group_by { |offer| offer.medication.canonical_name }

    COMMON_GENERIC_NAMES.filter_map do |name|
      matches = by_name[name]
      next if matches.blank?

      # A generic can have several strengths (e.g. Levotiroxina 25/50/100mcg) - show
      # the one with the best peso-per-mg. Offers with no per-mg price sort last, so
      # a comparable one always wins when there is one.
      matches.min_by { |offer| offer.price_per_mg || Float::INFINITY }
    end
  end

  # One row per medication: its single cheapest active offer today. DISTINCT ON
  # requires ordering by the distinct column first, so this can't also be ordered by
  # price - callers wrap it (see #paginated_cheapest_offers) to sort and paginate.
  # excluding_medication_ids keeps the featured medications from appearing twice.
  def cheapest_offer_per_medication_scope(city:, excluding_medication_ids: [])
    scope = Offer
      .select("DISTINCT ON (offers.medication_id) offers.*")
      .active
      .purchasable
      .where(city: city)
      # Offers with an unknown pack size have no comparable per-mg price, but are
      # still real listings worth showing - NULLS LAST keeps them in, ranked after
      # everything we can actually compare.
      .order(Arel.sql("offers.medication_id, offers.price_per_mg ASC NULLS LAST"))

    scope = scope.where.not(medication_id: excluding_medication_ids) if excluding_medication_ids.any?
    scope
  end

  # Sorts the one-per-medication set by price and returns just the requested page,
  # doing both in Postgres. The DISTINCT ON result becomes a subquery so the outer
  # query is free to order by price_per_mg and apply LIMIT/OFFSET - which means only
  # PER_PAGE rows (and only their associations) come back, instead of every offer.
  def paginated_cheapest_offers(scope, page:)
    Offer
      .from(scope, :offers)
      .includes(:medication, :pharmacy, :raw_listing)
      # NULLS LAST keeps unknown-pack-size offers on the page, after the comparable
      # ones. id is a tiebreaker, not decoration: without it Postgres is free to
      # order equal-priced rows differently between queries, which across
      # LIMIT/OFFSET pages could show a medication twice or skip it entirely.
      .order(Arel.sql("offers.price_per_mg ASC NULLS LAST, offers.id ASC"))
      .limit(PER_PAGE)
      .offset((page - 1) * PER_PAGE)
      .to_a
  end

  # Counts the distinct medications in the scope without loading any of them.
  def count_distinct_medications(scope)
    Offer.from(scope, :offers).count
  end
end

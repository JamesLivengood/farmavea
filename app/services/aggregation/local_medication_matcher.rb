module Aggregation
  # Deterministic, zero-cost fast path for raw names that already spell out a known
  # generic/active-ingredient name plainly (e.g. "Ibuprofeno 200 mg 10 cápsulas") -
  # skips Claude entirely for these, since no pharmaceutical/brand-name knowledge is
  # needed, just accent/case normalization and a strength regex.
  #
  # Deliberately conservative: only matches when the extracted (canonical_name,
  # strength_value, strength_unit) triple already exists as a Medication record - i.e.
  # Claude has confirmed this exact drug+strength combination before. This never
  # creates a NEW Medication on its own, so a coincidental word match can't spawn a
  # wrong record; it can only reuse something already validated. Anything that doesn't
  # match falls through to ClaudeMedicationMatcher unchanged.
  class LocalMedicationMatcher
    STRENGTH_PATTERN = /(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml)\b/i
    # "UI" (unidades internacionales - common for insulin/vaccines) is a distinct
    # raw-text unit, but ClaudeMedicationMatcher's schema normalizes it to the
    # stored strength_unit value "unit" (see MATCH_TOOL's enum) - matched
    # separately so the raw-text spelling can map to that stored value.
    UI_STRENGTH_PATTERN = /(\d+(?:\.\d+)?)\s*ui\b/i

    # Common, unambiguous ways Mexican pharmacy listings state a pack/box size.
    # Deliberately conservative (only these specific phrasings) to avoid misreading
    # an unrelated number (e.g. "100 UI Insulina...", where 100 is a strength, not a
    # pack count) as a pack size - a false pack_quantity would corrupt price-per-mg
    # silently, which is worse than just missing it and falling back to 1.
    PACK_QUANTITY_PATTERNS = [
      /\bcaja\s+con\s+(\d+)\b/i,
      /\bc\/(\d+)\b/i,
      # "unidades", "perlas", "parches", "óvulos" appear alongside the more common
      # dosage-form words. Note these must be COUNT words only - a volume or weight
      # ("120 ml", "50 g", "2.32%") is not a pack size, and treating one as such
      # would silently corrupt price-per-mg.
      /\b(\d+)\s*(?:tabletas?|c[aá]psulas?|tabs?|comp(?:rimidos?)?|amp(?:olletas?|ollas?)?|piezas?|pzas?|sobres?|grageas?|unidades?|perlas?|parches?|[oó]vulos?)\b/i
    ].freeze

    # Some pharmacies put the pack size in the product URL but strip it from the
    # display name - Benavides is the big one: the name is just "200 mg Tramadol"
    # while the slug reads ".../200-mg-tramadol-60-tabletas". Reading names alone
    # left ~95% of their listings with no pack size, which silently made their
    # price-per-mg wrong (see OfferBuilder#price_per_mg_for).
    #
    # Hyphen-delimited on both sides so this matches a real slug segment and can't
    # pick up part of a strength like "-500-mg-".
    # "cpsulas"/"tabletas" without accents appear because Benavides' slugs strip
    # accents inconsistently.
    PACK_QUANTITY_URL_PATTERN =
      %r{-(\d+)-(?:tabletas?|capsulas?|cpsulas?|c[aá]psulas?|comprimidos?|ud|unidades?|piezas?|pzas?|sobres?|grageas?|perlas?|ampolletas?|parches?|ovulos?|[oó]vulos?)\b}i

    def initialize(raw_names:)
      @raw_names = raw_names
    end

    # Returns { raw_name => { medication:, pack_quantity: } } for names resolved
    # locally - same shape ClaudeMedicationMatcher returns, so MedicationNormalizer
    # can treat both tiers uniformly. Names not present in the result need to go to
    # Claude.
    def call
      return {} if raw_names.empty?

      known_generics = Medication.pluck(:canonical_name, :strength_value, :strength_unit, :id)
      # strength_value comes back as BigDecimal from the DB; Hash lookups use #eql?/#hash,
      # under which BigDecimal(200) and Float 200.0 are NOT equal keys even though
      # == says they are - cast both sides to Float so the lookup below actually hits.
      by_name_and_strength = known_generics.group_by { |name, value, unit, _id| [ normalize(name), value&.to_f, unit ] }
      # Names grouped by their normalized generic name alone (ignoring strength) -
      # lets match_one scan a raw_name for which known generic name it contains,
      # without needing to already know where the name sits relative to the number.
      known_names = by_name_and_strength.keys.map(&:first).uniq

      raw_names.each_with_object({}) do |raw_name, result|
        medication = match_one(raw_name, by_name_and_strength, known_names)
        next unless medication

        result[raw_name] = { medication: medication, pack_quantity: extract_pack_quantity(raw_name) }
      end
    end

    private

    attr_reader :raw_names

    def match_one(raw_name, by_name_and_strength, known_names)
      strength_value, strength_unit = extract_strength(raw_name)
      return nil unless strength_value

      normalized_name = find_known_name_in(raw_name, known_names)
      return nil unless normalized_name

      candidates = by_name_and_strength[[ normalized_name, strength_value, strength_unit ]]
      return nil if candidates.blank?
      return nil if candidates.size > 1 # ambiguous (e.g. two different combo drugs starting the same way) - let Claude handle it

      Medication.find(candidates.first.last)
    end

    # Returns [strength_value, strength_unit] using the same unit vocabulary
    # Medication rows are stored with, or [nil, nil] if no recognizable strength is
    # present. Tries mg/mcg/g/ml first since it's the far more common case.
    def extract_strength(raw_name)
      if (m = raw_name.match(STRENGTH_PATTERN))
        return [ m[1].to_f, m[2].downcase ]
      end

      if (m = raw_name.match(UI_STRENGTH_PATTERN))
        return [ m[1].to_f, "unit" ]
      end

      [ nil, nil ]
    end

    def extract_pack_quantity(raw_name)
      PACK_QUANTITY_PATTERNS.each do |pattern|
        match = raw_name.match(pattern)
        return match[1].to_i if match
      end
      nil
    end

    # A raw name can put the generic name before or after its strength (e.g.
    # "Ibuprofeno 200 mg" vs "200 mg Ibuprofeno") - rather than assume a fixed
    # position, normalize the whole raw_name into words and check whether any
    # single word or adjacent word-pair exactly matches a known generic name.
    # Deliberately whole-word only (not substring) so e.g. "Ibuprofenol" (if that
    # were ever a distinct product name) can't accidentally match "Ibuprofeno".
    def find_known_name_in(raw_name, known_names)
      normalized_words = normalize(raw_name).split(/[^a-z]+/).reject { |w| w.length <= 3 }
      return nil if normalized_words.empty?

      candidates = normalized_words.dup
      normalized_words.each_cons(2) { |a, b| candidates << "#{a} #{b}" } # e.g. "acido acetilsalicilico"

      candidates.find { |c| known_names.include?(c) }
    end

    # Lowercases and strips accents so "Ibuprofeno" matches "ibuprofeno" and
    # "Núcleo" would match "nucleo" - pure string normalization, no drug knowledge.
    def normalize(text)
      text.to_s.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "").downcase
    end
  end
end

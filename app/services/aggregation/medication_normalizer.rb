module Aggregation
  # Maps raw scraped product names to canonical Medication records, in three tiers
  # from cheapest to most expensive:
  #
  #   1. NameMapping cache - this exact raw_name has been mapped before, for this
  #      pharmacy. Free, no computation.
  #   2. LocalMedicationMatcher - the raw_name plainly spells out a generic name
  #      Claude has already taught us about (e.g. "Ibuprofeno 200 mg"). Free, pure
  #      Ruby string matching + a strength regex, no LLM call.
  #   3. ClaudeMedicationMatcher - genuinely new or brand-only names (e.g. "Kuryent")
  #      that need pharmaceutical knowledge to decode. The only tier that costs money,
  #      and only ever sees what tiers 1-2 couldn't resolve.
  #
  # Prices change daily and are handled entirely in Ruby (OfferBuilder) regardless of
  # which tier resolved the medication - Claude is never asked to do price math.
  class MedicationNormalizer
    # A name Claude already rejected keeps being unresolvable for the same reason
    # until something changes (e.g. a new Medication gets added that it could now
    # match against) - retrying every single run re-bills Claude forever for an
    # identical rejection. Wait this long before giving a name another chance.
    RETRY_UNRESOLVED_AFTER = 14.days

    # existing_medications_block: forwarded to ClaudeMedicationMatcher so a
    # multi-pharmacy run can share one byte-identical cached prompt prefix across
    # every pharmacy instead of each one rebuilding (and cache-missing on) its own -
    # see ClaudeMedicationMatcher's initialize comment for why this matters.
    # claude_client: forwarded to ClaudeMedicationMatcher; injectable for tests so
    # they never make a real network call - production code never passes this.
    def initialize(pharmacy:, raw_listings:, existing_medications_block: nil, claude_client: nil)
      @pharmacy = pharmacy
      @raw_listings = raw_listings
      @existing_medications_block = existing_medications_block
      @claude_client = claude_client
    end

    # Returns { raw_listing_id => medication } for every listing passed in. As a
    # side effect, persists pack_quantity (box/pack size, e.g. "20 capsulas") onto
    # each RawListing when Claude was able to extract it - needed for a correct
    # price-per-mg calculation, since that's total-mg-in-the-box, not per-pill.
    def call
      unique_names = raw_listings.map(&:raw_name).uniq
      cached = NameMapping.where(pharmacy: pharmacy, raw_name: unique_names)
                           .includes(:medication)
                           .index_by(&:raw_name)

      # A name Claude already rejected (couldn't determine the ingredient, or too
      # low confidence) would be rejected again for the same reasons every time -
      # without this, it gets re-billed on every single future run forever. Retry
      # it periodically (RETRY_UNRESOLVED_AFTER) in case an unrelated medication
      # added since then makes it resolvable, rather than never or always.
      already_rejected = UnresolvedListing.where(pharmacy: pharmacy, raw_name: unique_names)
                                           .where("updated_at > ?", RETRY_UNRESOLVED_AFTER.ago)
                                           .pluck(:raw_name)

      names_after_cache = unique_names - cached.keys - already_rejected
      locally_matched = names_after_cache.any? ? LocalMedicationMatcher.new(raw_names: names_after_cache).call : {}
      persist_local_matches(locally_matched)

      names_for_claude = names_after_cache - locally_matched.keys
      claude_matched = if names_for_claude.any?
        matcher_args = { pharmacy: pharmacy, raw_names: names_for_claude, existing_medications_block: existing_medications_block }
        matcher_args[:client] = claude_client if claude_client
        ClaudeMedicationMatcher.new(**matcher_args).call
      else
        {}
      end

      # A cache hit (tier 1) predates pack_quantity ever being tracked and carries
      # none - but local-regex and Claude matches (tiers 2-3) both now return
      # { medication:, pack_quantity: } uniformly, so both can supply one.
      resolved = locally_matched.merge(claude_matched)
      name_to_medication = cached.transform_values(&:medication).merge(resolved.transform_values { |m| m[:medication] })
      name_to_pack_quantity = resolved.transform_values { |m| m[:pack_quantity] }

      persist_pack_quantities(name_to_pack_quantity)

      raw_listings.each_with_object({}) do |listing, result|
        medication = name_to_medication[listing.raw_name]
        result[listing.id] = medication if medication
      end
    end

    private

    attr_reader :pharmacy, :raw_listings, :existing_medications_block, :claude_client

    # A local match still needs to be cached in NameMapping, same as a Claude match,
    # so it's a cache hit (tier 1) on every subsequent crawl rather than re-running
    # the regex match indefinitely.
    def persist_local_matches(locally_matched)
      locally_matched.each do |raw_name, match|
        NameMapping.find_or_create_by!(pharmacy: pharmacy, raw_name: raw_name) do |mapping|
          mapping.medication = match[:medication]
          mapping.confidence = 1.0
          mapping.source = "local_regex"
        end
      end
    end

    def persist_pack_quantities(name_to_pack_quantity)
      name_to_pack_quantity.each do |raw_name, pack_quantity|
        next if pack_quantity.blank? || pack_quantity.to_i <= 0

        RawListing.where(pharmacy: pharmacy, raw_name: raw_name).update_all(pack_quantity: pack_quantity)
      end
    end
  end
end

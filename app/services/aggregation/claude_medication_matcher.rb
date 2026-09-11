require "anthropic"

module Aggregation
  # Sends previously-unseen product names to Claude once, in batches, and asks it to
  # identify the underlying medication (generic/active ingredient + strength) behind
  # each brand/product name.
  #
  # Claude never computes price-per-mg here - it only extracts structured facts.
  # All price math happens later in Ruby (OfferBuilder), where it's cheap, exact,
  # and auditable. Claude also never decides whether a match already exists in our
  # database - that's a deterministic (canonical_name, strength_value, strength_unit)
  # lookup done in Ruby, not something worth spending a token on.
  class ClaudeMedicationMatcher
    MODEL = :"claude-opus-5"
    BATCH_SIZE = 75
    EXISTING_MEDICATIONS_CONTEXT_LIMIT = 500

    # For a price-comparison database, a wrong medication match is worse than no
    # match: it silently merges two different drugs' prices together. Below this
    # confidence, we record the item as unresolved (for human review) instead of
    # trusting Claude's guess. Confidence at or above this bar is accepted outright;
    # there's no middle "secondary review" tier yet - that's a reasonable future step
    # once we have a queue/UI to act on it, not before.
    ACCEPT_CONFIDENCE_THRESHOLD = 0.80

    MATCH_TOOL = {
      name: "record_medication_matches",
      description: "Record the canonical medication behind each scraped pharmacy product name.",
      input_schema: {
        type: "object",
        properties: {
          matches: {
            type: "array",
            items: {
              type: "object",
              properties: {
                id: { type: "integer", description: "The numeric id from the input list this result is for." },
                canonical_name: {
                  type: [ "string", "null" ],
                  description: "The generic/active-ingredient name of the medication in Spanish, e.g. 'Paracetamol', 'Losartan'. Use the same canonical_name for every product that contains the same active ingredient, regardless of brand. Set to null if you cannot determine the active ingredient with reasonable confidence - do not guess."
                },
                strength_value: {
                  type: "number",
                  description: "The numeric strength of a single unit (tablet/capsule/mL), e.g. 500 for a 500mg tablet. Use 0 if no meaningful strength applies (e.g. a device) or if canonical_name is null."
                },
                strength_unit: {
                  type: "string",
                  enum: [ "mg", "mcg", "g", "ml", "unit" ],
                  description: "Unit for strength_value. Use 'unit' if the product has no meaningful mg/mcg/mL strength (e.g. a device) or if canonical_name is null."
                },
                pack_quantity: {
                  type: [ "integer", "null" ],
                  description: "Number of tablets/capsules in the package, or null if not a discrete-unit form (e.g. syrup)."
                },
                confidence: {
                  type: "number",
                  description: "0.0-1.0 confidence in this extraction. Use a LOW score (below 0.8) rather than omitting the item or inventing an answer when you are not sure."
                }
              },
              required: %w[id canonical_name strength_value strength_unit pack_quantity confidence],
              additionalProperties: false
            }
          }
        },
        required: [ "matches" ],
        additionalProperties: false
      },
      strict: true
    }.freeze

    # Raised when the API is failing in a way that will keep failing for every
    # subsequent batch too (e.g. exhausted credit balance) - continuing would just
    # silently produce zero matches for the rest of the run instead of surfacing
    # the real problem.
    class UnrecoverableAPIError < StandardError; end

    # existing_medications_block: optionally pass in a block built by
    # .build_shared_existing_medications_block so every pharmacy in a multi-pharmacy
    # run (e.g. script/aggregate_latest.rb) shares the exact same byte-identical
    # cached prompt prefix. Without this, each pharmacy's own ClaudeMedicationMatcher
    # would rebuild the block from Medication.order(updated_at: :desc) - a query
    # whose result shifts every time ANY medication is created/updated anywhere in
    # the run, which silently defeats prompt caching almost entirely (confirmed:
    # this cost real, unnecessary money in the 2026-09-04/05 aggregation run).
    # client: injectable for tests, so a test can supply a fake client that returns
    # a canned response and never makes a real network call - production code
    # never passes this, always getting a real Anthropic::Client.
    # model: injectable so a cost/quality comparison run (see
    # script/compare_models_sample.rb) can try a cheaper model against the same
    # names without changing the default production behavior.
    def initialize(pharmacy:, raw_names:, existing_medications_block: nil, client: Anthropic::Client.new, model: MODEL)
      @pharmacy = pharmacy
      @raw_names = raw_names
      @existing_medications_block = existing_medications_block
      @client = client
      @model = model
    end

    # Builds the "existing medications" reference block once, to be shared byte-for-
    # byte across every ClaudeMedicationMatcher instance in a run - see the
    # initialize comment above for why sharing this (instead of each instance
    # building its own) matters for prompt-cache hit rate.
    def self.build_shared_existing_medications_block
      new(pharmacy: nil, raw_names: []).send(:build_existing_medications_block)
    end

    def call
      # Fall back to building our own snapshot only when the caller didn't supply a
      # shared one (e.g. this matcher is used standalone/in a test) - see the
      # initialize comment for why a multi-pharmacy run should always pass one in.
      @existing_medications_block ||= build_existing_medications_block

      raw_names.each_slice(BATCH_SIZE).each_with_object({}) do |batch, result|
        match_batch(batch).each { |raw_name, medication| result[raw_name] = medication }
      end
    end

    private

    attr_reader :pharmacy, :raw_names, :client, :existing_medications_block, :model

    def match_batch(batch_names)
      # id -> raw_name, so Claude only has to echo back a small integer instead of
      # repeating the (often long) product name in every result row.
      id_to_name = batch_names.each_with_index.to_h { |name, i| [ i + 1, name ] }

      response = client.messages.create(
        model: model,
        max_tokens: 16_000,
        thinking: { type: "adaptive" },
        tools: [ MATCH_TOOL ],
        tool_choice: { type: "tool", name: "record_medication_matches" },
        system_: [ { type: "text", text: system_prompt, cache_control: { type: "ephemeral" } } ],
        messages: [
          {
            role: "user",
            content: [
              # Cached separately from the product-name block below: identical across
              # every batch in this run, so batches 2+ read this from cache instead of
              # paying full input-token price for the same list repeatedly.
              { type: "text", text: existing_medications_block, cache_control: { type: "ephemeral" } },
              { type: "text", text: product_names_block(id_to_name) }
            ]
          }
        ]
      )

      log_cache_usage(response.usage)

      tool_use = response.content.find { |block| block.type == :tool_use }
      return {} unless tool_use

      matches = tool_use.input["matches"] || tool_use.input[:matches] || []

      # A response cut off at max_tokens yields a partial matches array, and the
      # names it never got to would silently vanish (no match, no UnresolvedListing,
      # no error) - surface that instead, since it looks identical to "Claude had
      # nothing to say about them" in the resulting data.
      if response.stop_reason.to_s == "max_tokens"
        Rails.logger.error(
          "[ClaudeMedicationMatcher] response hit max_tokens: got #{matches.size} of " \
          "#{id_to_name.size} names in this batch - the rest were dropped. Consider a smaller BATCH_SIZE."
        )
      end

      persist_matches(matches, id_to_name)
    rescue Anthropic::Errors::BadRequestError => e
      # A 400 here is virtually always a request/account-level problem (e.g. "credit
      # balance too low") rather than something specific to this batch of names -
      # every remaining batch would fail identically, so stop instead of silently
      # returning zero matches for the rest of the run.
      raise UnrecoverableAPIError, "#{e.class}: #{e.message}"
    rescue Anthropic::Errors::APIError => e
      Rails.logger.error("[ClaudeMedicationMatcher] batch failed: #{e.class}: #{e.message}")
      {}
    end

    # Makes cache effectiveness verifiable from the logs instead of assumed - the
    # existing_medications_block cache-sharing bug that shipped in the 2026-09-04/05
    # run went undetected because nothing surfaced actual cache-hit token counts.
    def log_cache_usage(usage)
      return unless usage

      cache_read = usage.cache_read_input_tokens.to_i
      cache_write = usage.cache_creation_input_tokens.to_i
      uncached = usage.input_tokens.to_i
      Rails.logger.info(
        "[ClaudeMedicationMatcher] usage: input=#{uncached} cache_read=#{cache_read} " \
        "cache_write=#{cache_write} output=#{usage.output_tokens}"
      )
    end

    def system_prompt
      <<~PROMPT
        You are a pharmacology data-normalization assistant for a Mexican medication
        price-comparison service. You will be given raw product names scraped from a
        pharmacy e-commerce website in Mexico. For each name, identify the underlying
        medication: its generic/active-ingredient name and strength.

        Rules:
        - canonical_name must be the ACTIVE INGREDIENT (generic name), never the brand.
          E.g. "Tylenol 500mg" and "Panadol 500mg" both have canonical_name "Paracetamol".
        - Use the exact same canonical_name spelling/casing for the same active ingredient
          every time so records can be grouped reliably.
        - If a product combines multiple active ingredients, use the combination name
          commonly used in Mexican pharmacies (e.g. "Paracetamol/Cafeina/Ácido acetilsalicílico"),
          consistently.
        - Extract the per-unit strength (per tablet/capsule/mL), not the total package amount.
        - This is a price-comparison database: an INCORRECT medication match is worse
          than no match, because it would silently merge two different drugs' prices
          together. If you cannot determine the active ingredient with reasonable
          confidence, set canonical_name to null and give a low confidence score.
          Do NOT invent or guess an answer just to fill in the field.
        - The EXISTING_MEDICATIONS list is reference context only, to help you recognize
          brand names you might otherwise be unsure about (e.g. if "Weicop" appears
          there as Celecoxib, and a new product is also "Weicop", you can be confident
          it's Celecoxib too). You do not need to decide whether your answer already
          exists in that list - just answer with the correct canonical_name and
          strength; matching against existing records is handled separately.
      PROMPT
    end

    def build_existing_medications_block
      existing = Medication.order(updated_at: :desc).limit(EXISTING_MEDICATIONS_CONTEXT_LIMIT)
                            .pluck(:canonical_name, :strength_value, :strength_unit).uniq

      <<~TEXT
        EXISTING_MEDICATIONS (canonical_name, strength_value, strength_unit):
        #{existing.map { |name, val, unit| "- #{name}, #{val}, #{unit}" }.join("\n")}
      TEXT
    end

    def product_names_block(id_to_name)
      <<~TEXT
        PRODUCT_NAMES scraped from #{pharmacy.name} (id: name):
        #{id_to_name.map { |id, name| "#{id}: #{name}" }.join("\n")}

        Call record_medication_matches with one entry per id above.
      TEXT
    end

    def persist_matches(matches, id_to_name)
      matches.each_with_object({}) do |match, result|
        id = match["id"] || match[:id]
        raw_name = id_to_name[id]
        next if raw_name.blank?

        confidence = (match["confidence"] || match[:confidence]).to_f
        canonical_name = (match["canonical_name"] || match[:canonical_name]).presence

        if canonical_name.blank? || confidence < ACCEPT_CONFIDENCE_THRESHOLD
          record_unresolved(raw_name, match, confidence)
          next
        end

        medication = find_or_create_medication(match, canonical_name)
        next unless medication

        NameMapping.find_or_create_by!(pharmacy: pharmacy, raw_name: raw_name) do |mapping|
          mapping.medication = medication
          mapping.confidence = confidence
          mapping.source = "claude"
        end
        # A prior run may have recorded this name as unresolved (e.g. it was never
        # actually sent to Claude due to an API-level failure) - now that it has a
        # real match, that stale record would otherwise sit around forever.
        UnresolvedListing.where(pharmacy: pharmacy, raw_name: raw_name).delete_all

        pack_quantity = match["pack_quantity"] || match[:pack_quantity]
        result[raw_name] = { medication: medication, pack_quantity: pack_quantity }
      end.tap { |resolved| record_names_claude_skipped(resolved, id_to_name) }
    end

    # Claude is asked for "one entry per id" but can return fewer (an omitted id, or
    # a response truncated at max_tokens). Those names would otherwise get no
    # NameMapping, no UnresolvedListing and no error - meaning they're silently
    # re-sent and re-billed on every future run forever. Record them so the
    # normalizer's 14-day retry window applies to them like any other non-match.
    def record_names_claude_skipped(resolved, id_to_name)
      id_to_name.each_value do |raw_name|
        next if resolved.key?(raw_name)
        next if UnresolvedListing.exists?(pharmacy: pharmacy, raw_name: raw_name)

        Rails.logger.warn("[ClaudeMedicationMatcher] no result returned for #{raw_name.truncate(80)}")
        record_unresolved(raw_name, {}, 0.0, reason: "Claude returned no entry for this name (omitted or response truncated)")
      end
    end

    def record_unresolved(raw_name, match, confidence, reason: nil)
      reason ||= if (match["canonical_name"] || match[:canonical_name]).blank?
        "Claude could not determine the active ingredient"
      else
        "Confidence #{confidence.round(2)} below accept threshold (#{ACCEPT_CONFIDENCE_THRESHOLD})"
      end

      unresolved = UnresolvedListing.find_or_initialize_by(pharmacy: pharmacy, raw_name: raw_name)
      unresolved.reason = reason
      unresolved.confidence = confidence
      # Explicitly bump updated_at even if reason/confidence are unchanged from last
      # time - MedicationNormalizer uses this timestamp to decide when a rejected
      # name is next eligible for a retry, so a same-answer rejection still needs to
      # restart that wait, not leave it looking stale from the original rejection.
      unresolved.updated_at = Time.current
      unresolved.save!
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[ClaudeMedicationMatcher] could not record unresolved listing for #{raw_name}: #{e.message}")
    end

    def find_or_create_medication(match, canonical_name)
      strength_value = match["strength_value"] || match[:strength_value]
      strength_unit = match["strength_unit"] || match[:strength_unit]

      Medication.find_or_create_by!(
        canonical_name: canonical_name,
        strength_value: strength_value,
        strength_unit: strength_unit
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[ClaudeMedicationMatcher] could not persist medication for #{canonical_name}: #{e.message}")
      nil
    end
  end
end

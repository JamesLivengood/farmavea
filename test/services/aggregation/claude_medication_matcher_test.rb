require "test_helper"

module Aggregation
  class ClaudeMedicationMatcherTest < ActiveSupport::TestCase
    # Builds a fake Anthropic client whose #messages.create returns `response`, or
    # calls it as a proc for tests that need to inspect call arguments or raise an
    # error. Injected directly via ClaudeMedicationMatcher.new(client:), so these
    # tests never make a real network call or spend real Claude API money, on top
    # of WebMock's blanket net-connect block in test_helper.rb.
    def fake_claude_client(response)
      create_impl = response.respond_to?(:call) ? response : ->(**_kwargs) { response }
      fake_messages = Object.new
      fake_messages.define_singleton_method(:create) { |**kwargs| create_impl.call(**kwargs) }
      fake_client = Object.new
      fake_client.define_singleton_method(:messages) { fake_messages }
      fake_client
    end

    test "accepts a match at or above the confidence threshold and creates a Medication" do
      matches = [
        { "id" => 1, "canonical_name" => "Paracetamol", "strength_value" => 500, "strength_unit" => "mg",
          "pack_quantity" => 20, "confidence" => 0.95 }
      ]
      pharmacy = create_pharmacy

      result = ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Tylenol 500mg 20 tabs" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      medication = result["Tylenol 500mg 20 tabs"][:medication]
      assert_equal "Paracetamol", medication.canonical_name
      assert_equal 500.0, medication.strength_value.to_f
      assert_equal 20, result["Tylenol 500mg 20 tabs"][:pack_quantity]
    end

    test "records a low-confidence match as unresolved instead of accepting it" do
      matches = [
        { "id" => 1, "canonical_name" => "Algo", "strength_value" => 10, "strength_unit" => "mg",
          "pack_quantity" => nil, "confidence" => 0.4 }
      ]
      pharmacy = create_pharmacy

      result = ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Mystery Product" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_empty result
      unresolved = UnresolvedListing.find_by(pharmacy: pharmacy, raw_name: "Mystery Product")
      assert unresolved
      assert_match(/below accept threshold/, unresolved.reason)
    end

    test "records a null canonical_name as unresolved" do
      matches = [
        { "id" => 1, "canonical_name" => nil, "strength_value" => 0, "strength_unit" => "unit",
          "pack_quantity" => nil, "confidence" => 0.1 }
      ]
      pharmacy = create_pharmacy

      result = ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Totally Unknown Thing" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_empty result
      unresolved = UnresolvedListing.find_by(pharmacy: pharmacy, raw_name: "Totally Unknown Thing")
      assert_match(/could not determine the active ingredient/, unresolved.reason)
    end

    test "reuses an existing Medication instead of creating a duplicate for the same canonical_name+strength" do
      existing = create_medication(canonical_name: "Ibuprofeno", strength_value: 600, strength_unit: "mg")
      matches = [ { "id" => 1, "canonical_name" => "Ibuprofeno", "strength_value" => 600, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.99 } ]
      pharmacy = create_pharmacy

      result = nil
      assert_no_difference "Medication.count" do
        result = ClaudeMedicationMatcher.new(
          pharmacy: pharmacy, raw_names: [ "Advil 600mg" ],
          client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
        ).call
      end

      assert_equal existing, result["Advil 600mg"][:medication]
    end

    test "a previously-unresolved name that now resolves has its stale UnresolvedListing cleared" do
      pharmacy = create_pharmacy
      UnresolvedListing.create!(pharmacy: pharmacy, raw_name: "Now Known Drug", reason: "old reason", confidence: 0.2)
      matches = [ { "id" => 1, "canonical_name" => "Ahora Conocido", "strength_value" => 10, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]

      ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Now Known Drug" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_not UnresolvedListing.exists?(pharmacy: pharmacy, raw_name: "Now Known Drug")
    end

    test "persists a NameMapping so future runs hit the free cache tier instead of billing Claude again" do
      matches = [ { "id" => 1, "canonical_name" => "Amoxicilina", "strength_value" => 250, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]
      pharmacy = create_pharmacy

      ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Amoxil 250" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      mapping = NameMapping.find_by(pharmacy: pharmacy, raw_name: "Amoxil 250")
      assert mapping
      assert_equal "claude", mapping.source
    end

    test "raises UnrecoverableAPIError on a BadRequestError instead of silently returning empty results" do
      pharmacy = create_pharmacy
      raise_bad_request = lambda do |**_kwargs|
        raise Anthropic::Errors::BadRequestError.new(url: URI("https://api.anthropic.com/v1/messages"), status: 400, headers: {}, body: nil, request: nil, response: nil)
      end

      error = assert_raises(ClaudeMedicationMatcher::UnrecoverableAPIError) do
        ClaudeMedicationMatcher.new(
          pharmacy: pharmacy, raw_names: [ "Anything" ],
          client: fake_claude_client(raise_bad_request)
        ).call
      end
      assert_match(/BadRequestError/, error.message)
    end

    test "a generic APIError on one batch logs and continues rather than aborting the whole run" do
      pharmacy = create_pharmacy
      raise_server_error = lambda do |**_kwargs|
        raise Anthropic::Errors::InternalServerError.new(url: URI("https://api.anthropic.com/v1/messages"), status: 500, headers: {}, body: nil, request: nil, response: nil)
      end

      result = ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Anything" ],
        client: fake_claude_client(raise_server_error)
      ).call

      assert_equal({}, result)
    end

    test "a name Claude returns no entry for is recorded as unresolved, not silently dropped" do
      pharmacy = create_pharmacy
      # Claude answers for id 1 but omits id 2 entirely.
      matches = [ { "id" => 1, "canonical_name" => "Algo", "strength_value" => 10, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]

      result = ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Answered Name", "Ignored Name" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert result.key?("Answered Name")
      assert_not result.key?("Ignored Name")

      unresolved = UnresolvedListing.find_by(pharmacy: pharmacy, raw_name: "Ignored Name")
      assert unresolved, "an omitted name must be recorded so it isn't re-billed to Claude on every future run"
      assert_match(/no entry/, unresolved.reason)
    end

    test "a name omitted from a truncated (max_tokens) response is still recorded as unresolved" do
      pharmacy = create_pharmacy
      matches = [ { "id" => 1, "canonical_name" => "Algo", "strength_value" => 10, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]

      ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Answered Name", "Cut Off Name" ],
        client: fake_claude_client(FakeClaudeResponse.with_matches(matches, stop_reason: :max_tokens))
      ).call

      assert UnresolvedListing.exists?(pharmacy: pharmacy, raw_name: "Cut Off Name")
    end

    test "an already-unresolved name is not re-recorded when Claude omits it again" do
      pharmacy = create_pharmacy
      UnresolvedListing.create!(pharmacy: pharmacy, raw_name: "Persistently Ignored", reason: "original reason", confidence: 0.1)

      assert_no_difference "UnresolvedListing.count" do
        ClaudeMedicationMatcher.new(
          pharmacy: pharmacy, raw_names: [ "Persistently Ignored" ],
          client: fake_claude_client(FakeClaudeResponse.with_matches([]))
        ).call
      end
    end

    test "batches raw_names in groups no larger than BATCH_SIZE" do
      pharmacy = create_pharmacy
      names = (1..(ClaudeMedicationMatcher::BATCH_SIZE + 10)).map { |i| "Product #{i}" }
      batch_sizes = []

      capture_batch_size = lambda do |**kwargs|
        batch_sizes << kwargs[:messages].first[:content].last[:text].scan(/^\d+:/).size
        FakeClaudeResponse.with_matches([])
      end

      ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: names,
        client: fake_claude_client(capture_batch_size)
      ).call

      assert_equal 2, batch_sizes.size
      assert_equal ClaudeMedicationMatcher::BATCH_SIZE, batch_sizes.first
      assert_equal 10, batch_sizes.last
    end

    test "an injected existing_medications_block is reused byte-for-byte instead of rebuilt" do
      pharmacy = create_pharmacy
      shared_block = "SHARED BLOCK CONTENTS"
      seen_blocks = []

      capture_block = lambda do |**kwargs|
        seen_blocks << kwargs[:messages].first[:content].first[:text]
        FakeClaudeResponse.with_matches([])
      end

      ClaudeMedicationMatcher.new(
        pharmacy: pharmacy, raw_names: [ "Something" ],
        existing_medications_block: shared_block,
        client: fake_claude_client(capture_block)
      ).call

      assert_equal [ shared_block ], seen_blocks
    end
  end
end

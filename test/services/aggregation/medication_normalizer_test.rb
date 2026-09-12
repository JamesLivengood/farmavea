require "test_helper"

module Aggregation
  class MedicationNormalizerTest < ActiveSupport::TestCase
    def fake_claude_client(response)
      create_impl = response.respond_to?(:call) ? response : ->(**_kwargs) { response }
      fake_messages = Object.new
      fake_messages.define_singleton_method(:create) { |**kwargs| create_impl.call(**kwargs) }
      fake_client = Object.new
      fake_client.define_singleton_method(:messages) { fake_messages }
      fake_client
    end

    test "a NameMapping cache hit resolves without calling Claude at all" do
      pharmacy = create_pharmacy
      medication = create_medication
      NameMapping.create!(pharmacy: pharmacy, raw_name: "Cached Brand", medication: medication, confidence: 1.0, source: "claude")
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Cached Brand")

      client_that_must_not_be_called = fake_claude_client(->(**_kwargs) { raise "Claude should never be called for a cached name" })

      result = MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing ], claude_client: client_that_must_not_be_called).call

      assert_equal medication, result[listing.id]
    end

    test "a name matching a known generic resolves locally without calling Claude" do
      pharmacy = create_pharmacy
      medication = create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Ibuprofeno 400 mg")

      client_that_must_not_be_called = fake_claude_client(->(**_kwargs) { raise "Claude should never be called for a locally-resolvable name" })

      result = MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing ], claude_client: client_that_must_not_be_called).call

      assert_equal medication, result[listing.id]
      mapping = NameMapping.find_by(pharmacy: pharmacy, raw_name: "Ibuprofeno 400 mg")
      assert_equal "local_regex", mapping.source
    end

    test "a genuinely new brand name falls through to Claude" do
      pharmacy = create_pharmacy
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Kuryent 100 mg")
      matches = [ { "id" => 1, "canonical_name" => "Sildenafil", "strength_value" => 100, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]

      result = MedicationNormalizer.new(
        pharmacy: pharmacy, raw_listings: [ listing ],
        claude_client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_equal "Sildenafil", result[listing.id].canonical_name
    end

    test "a recently-rejected name is not retried and does not call Claude again" do
      pharmacy = create_pharmacy
      UnresolvedListing.create!(pharmacy: pharmacy, raw_name: "Rejected Recently", reason: "old", confidence: 0.1, updated_at: 1.day.ago)
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Rejected Recently")

      client_that_must_not_be_called = fake_claude_client(->(**_kwargs) { raise "should not retry a recently-rejected name" })

      result = MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing ], claude_client: client_that_must_not_be_called).call

      assert_nil result[listing.id]
    end

    test "a name rejected long ago (past the retry window) is retried" do
      pharmacy = create_pharmacy
      UnresolvedListing.create!(pharmacy: pharmacy, raw_name: "Rejected Long Ago", reason: "old", confidence: 0.1)
      UnresolvedListing.where(pharmacy: pharmacy, raw_name: "Rejected Long Ago").update_all(updated_at: 30.days.ago)
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Rejected Long Ago")
      matches = [ { "id" => 1, "canonical_name" => "Now Findable", "strength_value" => 5, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]

      result = MedicationNormalizer.new(
        pharmacy: pharmacy, raw_listings: [ listing ],
        claude_client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_equal "Now Findable", result[listing.id].canonical_name
    end

    test "persists pack_quantity from a Claude match onto the RawListing" do
      pharmacy = create_pharmacy
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Boxed Product")
      matches = [ { "id" => 1, "canonical_name" => "Algo", "strength_value" => 10, "strength_unit" => "mg", "pack_quantity" => 24, "confidence" => 0.9 } ]

      MedicationNormalizer.new(
        pharmacy: pharmacy, raw_listings: [ listing ],
        claude_client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_equal 24, listing.reload.pack_quantity
    end

    test "a listing whose name never resolves is simply absent from the result, not an error" do
      pharmacy = create_pharmacy
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Unresolvable Thing")
      matches = [ { "id" => 1, "canonical_name" => nil, "strength_value" => 0, "strength_unit" => "unit", "pack_quantity" => nil, "confidence" => 0.1 } ]

      result = MedicationNormalizer.new(
        pharmacy: pharmacy, raw_listings: [ listing ],
        claude_client: fake_claude_client(FakeClaudeResponse.with_matches(matches))
      ).call

      assert_not result.key?(listing.id)
    end

    test "duplicate raw_names across multiple listings only trigger one Claude lookup for that name" do
      pharmacy = create_pharmacy
      listing_a = create_raw_listing(pharmacy: pharmacy, raw_name: "Same Product")
      listing_b = create_raw_listing(pharmacy: pharmacy, raw_name: "Same Product")
      call_count = 0
      matches = [ { "id" => 1, "canonical_name" => "Algo", "strength_value" => 10, "strength_unit" => "mg", "pack_quantity" => nil, "confidence" => 0.9 } ]

      counting_client = fake_claude_client(lambda do |**_kwargs|
        call_count += 1
        FakeClaudeResponse.with_matches(matches)
      end)

      result = MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing_a, listing_b ], claude_client: counting_client).call

      assert_equal 1, call_count
      assert_equal result[listing_a.id], result[listing_b.id]
    end

    # The paid tier must never run just because a crawl found new products. An
    # aggregation over 9,001 newly-discovered listings billed ~$11 unprompted -
    # improving the crawler silently increased the bill.
    test "the paid tier is skipped unless ALLOW_CLAUDE_API is set" do
      pharmacy = create_pharmacy
      # A name no cache or regex can resolve, so tier 3 is the only thing left.
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Kuryent Xyz 99")

      original = ENV.delete("ALLOW_CLAUDE_API")
      begin
        result = MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing ]).call

        assert_nil result[listing.id], "an unresolvable name must stay unresolved, not reach the API"
      ensure
        ENV["ALLOW_CLAUDE_API"] = original if original
      end
    end

    test "ALLOW_CLAUDE_API opts back in to the paid tier" do
      pharmacy = create_pharmacy
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Kuryent Xyz 99")
      called = false
      client = fake_claude_client(lambda do |**_kwargs|
        called = true
        FakeClaudeResponse.with_matches([ { raw_name: "Kuryent Xyz 99", canonical_name: "Paracetamol",
                                            strength_value: 500, strength_unit: "mg", confidence: 0.9 } ])
      end)

      original = ENV["ALLOW_CLAUDE_API"]
      ENV["ALLOW_CLAUDE_API"] = "1"
      begin
        MedicationNormalizer.new(pharmacy: pharmacy, raw_listings: [ listing ], claude_client: client).call

        assert called, "the paid tier should run when explicitly enabled"
      ensure
        original ? ENV["ALLOW_CLAUDE_API"] = original : ENV.delete("ALLOW_CLAUDE_API")
      end
    end
  end
end

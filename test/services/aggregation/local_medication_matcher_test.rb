require "test_helper"

module Aggregation
  class LocalMedicationMatcherTest < ActiveSupport::TestCase
    test "matches when the generic name comes before the strength" do
      known = create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Ibuprofeno 400 mg" ]).call

      assert_equal known, result["Ibuprofeno 400 mg"][:medication]
    end

    test "matches when the strength comes before the generic name (regression: this used to silently miss and cost a Claude call)" do
      known = create_medication(canonical_name: "Amoxicilina", strength_value: 250, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "250 mg Amoxicilina" ]).call

      assert_equal known, result["250 mg Amoxicilina"][:medication]
    end

    test "does not match a brand name with no known generic word present" do
      create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Tylenol 500mg" ]).call

      assert_empty result
    end

    test "does not match when the strength combination is not a known Medication" do
      create_medication(canonical_name: "Amoxicilina", strength_value: 250, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Amoxicilina 999mg" ]).call

      assert_empty result
    end

    test "does not match on an ambiguous short prefix" do
      create_medication(canonical_name: "Sal", strength_value: 1, strength_unit: "g")
      result = LocalMedicationMatcher.new(raw_names: [ "Sal 1g Salvador Extra" ]).call

      assert_empty result, "a 3-letter-or-shorter word should never be treated as a confident generic-name match"
    end

    test "extracts pack_quantity from a 'Caja con N' phrase" do
      create_medication(canonical_name: "Amoxicilina", strength_value: 500, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Amoxicilina 500mg Caja con 12 Cápsulas" ]).call

      assert_equal 12, result["Amoxicilina 500mg Caja con 12 Cápsulas"][:pack_quantity]
    end

    test "extracts pack_quantity from a 'C/N' abbreviation" do
      create_medication(canonical_name: "Diclofenaco", strength_value: 50, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Diclofenaco 50mg C/20" ]).call

      assert_equal 20, result["Diclofenaco 50mg C/20"][:pack_quantity]
    end

    test "extracts pack_quantity from a trailing count + unit word" do
      create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Ibuprofeno 400 mg 30 Tabletas" ]).call

      assert_equal 30, result["Ibuprofeno 400 mg 30 Tabletas"][:pack_quantity]
    end

    test "does not mistake a strength number for a pack quantity" do
      create_medication(canonical_name: "Ambroxol", strength_value: 30, strength_unit: "mg")
      # "30" here is the strength, not a pack count, and there's no pack-quantity
      # phrase (no "Caja con", "C/", or trailing count+unit word) present at all.
      result = LocalMedicationMatcher.new(raw_names: [ "Ambroxol 30 mg Jarabe" ]).call

      assert_nil result["Ambroxol 30 mg Jarabe"][:pack_quantity],
        "the strength number must not leak into pack_quantity when no real pack phrase is present"
    end

    test "returns nil pack_quantity when no pack phrase is present" do
      create_medication(canonical_name: "Sertralina", strength_value: 50, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Sertralina 50 mg" ]).call

      assert_nil result["Sertralina 50 mg"][:pack_quantity]
    end

    test "does not match ambiguously when two different medications share a first word" do
      create_medication(canonical_name: "Ibuprofeno", strength_value: 1, strength_unit: "unit")
      create_medication(canonical_name: "Ibuprofeno", strength_value: 1, strength_unit: "g") # different unit, same name+value pairing is fine
      # Force a genuine ambiguity: two DIFFERENT medication rows at the exact same (name, value, unit)
      Medication.insert_all([
        { canonical_name: "Ibuprofeno", strength_value: 2, strength_unit: "mg", slug: "dup-a", created_at: Time.current, updated_at: Time.current },
        { canonical_name: "Ibuprofeno", strength_value: 2, strength_unit: "mg", slug: "dup-b", created_at: Time.current, updated_at: Time.current }
      ])

      result = LocalMedicationMatcher.new(raw_names: [ "Ibuprofeno 2 mg" ]).call
      assert_empty result, "an ambiguous match (multiple candidate Medications) must fall through to Claude, not guess"
    end

    test "the URL pattern reads a pack size out of a product slug" do
      pattern = LocalMedicationMatcher::PACK_QUANTITY_URL_PATTERN

      {
        "https://www.benavides.com.mx/generico-de-marca-200-mg-tramadol-60-tabletas" => "60",
        "https://www.benavides.com.mx/bifebral-ketoprofeno-paracetamol-12-ud-comprimidos" => "12",
        "https://www.benavides.com.mx/generico-de-marca-150-mg-fluconazol-4-capsulas" => "4",
        "https://www.benavides.com.mx/cessabit-10-mg-ciclobenzaprina-30-tabletas" => "30"
      }.each do |url, expected|
        assert_equal expected, url.match(pattern)&.[](1), "wrong pack size for #{url}"
      end
    end

    test "the URL pattern does not mistake a strength for a pack size" do
      pattern = LocalMedicationMatcher::PACK_QUANTITY_URL_PATTERN

      # "500-mg" and "10-ml" are strengths - there's no pack word after the number,
      # so nothing should match.
      [
        "https://example.invalid/generico-500-mg-paracetamol",
        "https://example.invalid/jarabe-ambroxol-120-ml",
        "https://example.invalid/crema-hidrocortisona-30-g"
      ].each do |url|
        assert_nil url.match(pattern), "should not have matched a pack size in #{url}"
      end
    end

    test "handles an empty input list without querying anything" do
      assert_equal({}, LocalMedicationMatcher.new(raw_names: []).call)
    end

    test "matches a UI (unidades internacionales) strength, mapped to the stored 'unit' value" do
      known = create_medication(canonical_name: "Insulina Degludec", strength_value: 100, strength_unit: "unit")
      result = LocalMedicationMatcher.new(raw_names: [ "100 UI Insulina Degludec" ]).call

      assert_equal known, result["100 UI Insulina Degludec"][:medication]
    end

    test "matches accented names regardless of the raw text's accent usage" do
      known = create_medication(canonical_name: "Núcleo", strength_value: 5, strength_unit: "mg")
      result = LocalMedicationMatcher.new(raw_names: [ "Nucleo 5 mg" ]).call

      assert_equal known, result["Nucleo 5 mg"][:medication]
    end
  end
end

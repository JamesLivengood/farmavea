require "test_helper"

class MedicationTest < ActiveSupport::TestCase
  test "generate_slug builds name-strength slug on create" do
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    assert_equal "paracetamol-500mg", medication.slug
  end

  test "generate_slug strips trailing .0 from whole-number strengths" do
    medication = create_medication(canonical_name: "Ibuprofeno", strength_value: 600, strength_unit: "mg")
    assert_no_match(/\.0/, medication.slug)
  end

  test "generate_slug disambiguates a collision with a numeric suffix" do
    first = create_medication(canonical_name: "Amoxicilina", strength_value: 500, strength_unit: "mg")
    second = Medication.create!(canonical_name: "Amoxicilina", strength_value: 500, strength_unit: "mg", slug: nil)

    assert_not_equal first.slug, second.slug
    assert_match(/^#{first.slug}-\d+$/, second.slug)
  end

  test "generate_slug is skipped when a slug is already present" do
    medication = Medication.create!(canonical_name: "Custom", strength_value: 1, strength_unit: "mg", slug: "my-custom-slug")
    assert_equal "my-custom-slug", medication.slug
  end

  test "display_strength combines name and strength" do
    medication = create_medication(canonical_name: "Losartán", strength_value: 50, strength_unit: "mg")
    assert_equal "Losartán 50mg", medication.display_strength
  end

  test "display_strength falls back to bare name when strength is blank" do
    medication = Medication.create!(canonical_name: "Bare Name", slug: "bare-name")
    assert_equal "Bare Name", medication.display_strength
  end

  test "cheapest_offer returns the lowest price_per_mg active offer for the given city" do
    medication = create_medication
    pharmacy = create_pharmacy

    cheap = create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 0.5, city: "Morelia, Michoacán")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.5, city: "Morelia, Michoacán")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 0.1, city: "Other City")

    assert_equal cheap, medication.cheapest_offer(city: "Morelia, Michoacán")
  end

  test "cheapest_offer ignores inactive offers" do
    medication = create_medication
    pharmacy = create_pharmacy
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 0.1, active: false)
    active = create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 5.0, active: true)

    assert_equal active, medication.cheapest_offer(city: "Morelia, Michoacán")
  end

  test "search matches by canonical_name" do
    match = create_medication(canonical_name: "Sertralina", strength_value: 50, strength_unit: "mg")
    create_medication(canonical_name: "Fluoxetina", strength_value: 20, strength_unit: "mg")

    assert_equal [ match ], Medication.search("sertralina").to_a
  end

  test "search matches by a mapped raw brand name" do
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    pharmacy = create_pharmacy
    NameMapping.create!(pharmacy: pharmacy, raw_name: "Tylenol 500mg", medication: medication, confidence: 1.0, source: "claude")

    assert_equal [ medication ], Medication.search("tylenol").to_a
  end

  test "search is case-insensitive and matches partial strings" do
    medication = create_medication(canonical_name: "Escitalopram", strength_value: 10, strength_unit: "mg")
    assert_equal [ medication ], Medication.search("ESCITA").to_a
  end

  # A brand search returns the active ingredient, which the visitor may not
  # recognise as what they typed - "Aspirina" comes back as "Ácido acetilsalicílico".
  test "brand_matches_for names the brand that matched each result" do
    medication = create_medication(canonical_name: "Ácido acetilsalicílico", strength_value: 500, strength_unit: "mg")
    pharmacy = create_pharmacy
    NameMapping.create!(pharmacy: pharmacy, medication: medication,
                        raw_name: "Aspirina Dolor de Cabeza y Fiebre 40 Tabletas 500mg")

    matches = Medication.brand_matches_for("aspirina", [ medication.id ])

    assert_equal "Aspirina", matches[medication.id]
  end

  test "brand_matches_for returns nothing when the query is the generic name itself" do
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    pharmacy = create_pharmacy
    NameMapping.create!(pharmacy: pharmacy, medication: medication, raw_name: "Paracetamol 500mg caja con 20")

    matches = Medication.brand_matches_for("zzzznotpresent", [ medication.id ])

    assert_empty matches
  end

  test "extract_brand_token strips punctuation from the matched word" do
    assert_equal "Aspirina", Medication.extract_brand_token("Aspirina, 40 Tabletas", "aspirina")
  end
end

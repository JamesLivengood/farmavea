require "test_helper"

class NameMappingTest < ActiveSupport::TestCase
  test "the same raw_name can map for two different pharmacies" do
    medication = create_medication
    pharmacy_a = create_pharmacy(slug: "a", name: "Pharmacy A")
    pharmacy_b = create_pharmacy(slug: "b", name: "Pharmacy B")

    NameMapping.create!(pharmacy: pharmacy_a, raw_name: "Same Brand 500mg", medication: medication, confidence: 1.0, source: "claude")
    duplicate_across_pharmacies = NameMapping.new(pharmacy: pharmacy_b, raw_name: "Same Brand 500mg", medication: medication, confidence: 1.0, source: "claude")

    assert duplicate_across_pharmacies.valid?
  end

  test "the same raw_name cannot map twice for the same pharmacy" do
    medication = create_medication
    pharmacy = create_pharmacy

    NameMapping.create!(pharmacy: pharmacy, raw_name: "Repeated Name", medication: medication, confidence: 1.0, source: "claude")
    duplicate = NameMapping.new(pharmacy: pharmacy, raw_name: "Repeated Name", medication: medication, confidence: 1.0, source: "claude")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:raw_name], "has already been taken"
  end
end

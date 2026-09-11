require "test_helper"

module Aggregation
  class OfferBuilderTest < ActiveSupport::TestCase
    test "computes price_per_mg as price divided by total mg in the pack" do
      pharmacy = create_pharmacy
      medication = create_medication(canonical_name: "Amoxicilina", strength_value: 500, strength_unit: "mg")
      # 100 pesos for a 10-pack of 500mg tablets = 5000mg total = 0.02 pesos/mg
      listing = create_raw_listing(pharmacy: pharmacy, price_cents: 10_000, pack_quantity: 10)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { listing.id => medication }
      ).call

      offer = Offer.find_by!(raw_listing: listing)
      assert_in_delta 0.02, offer.price_per_mg, 0.0001
    end

    test "leaves price_per_mg nil when the pack size is unknown" do
      pharmacy = create_pharmacy
      medication = create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
      listing = create_raw_listing(pharmacy: pharmacy, price_cents: 4000, pack_quantity: nil)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { listing.id => medication }
      ).call

      offer = Offer.find_by!(raw_listing: listing)
      # Without a pack size we don't know how much medication is in the box. This
      # used to assume 1 tablet, dividing a whole box's price by a single tablet's
      # strength and producing figures wrong by 10-100x.
      assert_nil offer.price_per_mg
      assert_equal 4000, offer.price_cents, "the offer itself must still be stored"
    end

    test "a 20-pack costs about half as much per mg as a 10-pack at the same total price" do
      pharmacy = create_pharmacy
      medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
      ten_pack = create_raw_listing(pharmacy: pharmacy, raw_name: "10-pack", price_cents: 10_000, pack_quantity: 10)
      twenty_pack = create_raw_listing(pharmacy: pharmacy, raw_name: "20-pack", price_cents: 10_000, pack_quantity: 20)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { ten_pack.id => medication, twenty_pack.id => medication }
      ).call

      ten_pack_offer = Offer.find_by!(raw_listing: ten_pack)
      twenty_pack_offer = Offer.find_by!(raw_listing: twenty_pack)

      assert_in_delta ten_pack_offer.price_per_mg / 2, twenty_pack_offer.price_per_mg, 0.0001
      assert twenty_pack_offer.price_per_mg < ten_pack_offer.price_per_mg,
        "a 20-pack at the same price as a 10-pack should be cheaper per mg, not equal or more expensive"
    end

    test "handles mcg and g strength units by converting to mg" do
      pharmacy = create_pharmacy
      mcg_med = create_medication(canonical_name: "Levotiroxina", strength_value: 100, strength_unit: "mcg")
      g_med = create_medication(canonical_name: "Ácido valproico", strength_value: 1, strength_unit: "g")

      # pack_quantity: 1 stated explicitly - this test is about unit conversion, and
      # price_per_mg is nil without a known pack size.
      mcg_listing = create_raw_listing(pharmacy: pharmacy, raw_name: "mcg product", price_cents: 100, pack_quantity: 1)
      g_listing = create_raw_listing(pharmacy: pharmacy, raw_name: "g product", price_cents: 100, pack_quantity: 1)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { mcg_listing.id => mcg_med, g_listing.id => g_med }
      ).call

      mcg_offer = Offer.find_by!(raw_listing: mcg_listing)
      g_offer = Offer.find_by!(raw_listing: g_listing)

      # 100mcg = 0.1mg -> 1.00 / 0.1 = 10.0 pesos/mg
      assert_in_delta 10.0, mcg_offer.price_per_mg, 0.0001
      # 1g = 1000mg -> 1.00 / 1000 = 0.001 pesos/mg
      assert_in_delta 0.001, g_offer.price_per_mg, 0.0001
    end

    test "returns nil price_per_mg for non-mg-comparable units like ml or unit, but still creates the offer" do
      pharmacy = create_pharmacy
      medication = create_medication(canonical_name: "Solución Tópica", strength_value: 10, strength_unit: "ml")
      listing = create_raw_listing(pharmacy: pharmacy, price_cents: 5000)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { listing.id => medication }
      ).call

      offer = Offer.find_by!(raw_listing: listing)
      assert_nil offer.price_per_mg
      assert_equal 5000, offer.price_cents
    end

    test "raw listings with no medication match are skipped entirely" do
      pharmacy = create_pharmacy
      listing = create_raw_listing(pharmacy: pharmacy)

      OfferBuilder.new(pharmacy: pharmacy, city: "Morelia, Michoacán", raw_listing_to_medication: {}).call

      assert_nil Offer.find_by(raw_listing: listing)
    end

    test "re-running against the same raw_listing updates the existing offer instead of creating a duplicate" do
      pharmacy = create_pharmacy
      medication = create_medication
      listing = create_raw_listing(pharmacy: pharmacy, price_cents: 1000)

      2.times do
        OfferBuilder.new(
          pharmacy: pharmacy, city: "Morelia, Michoacán",
          raw_listing_to_medication: { listing.id => medication }
        ).call
      end

      assert_equal 1, Offer.where(raw_listing: listing).count
    end

    test "only a trusted prescription source can set requires_prescription, and only once" do
      pharmacy = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
      medication = create_medication
      listing = create_raw_listing(pharmacy: pharmacy, requires_prescription: true)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { listing.id => medication }
      ).call

      assert medication.reload.requires_prescription
    end

    test "an untrusted source never sets requires_prescription even if the listing claims one" do
      pharmacy = create_pharmacy(slug: "some_untrusted_source", name: "Untrusted Pharmacy")
      medication = create_medication
      listing = create_raw_listing(pharmacy: pharmacy, requires_prescription: true)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { listing.id => medication }
      ).call

      assert_nil medication.reload.requires_prescription
    end

    test "a trusted source never overwrites an already-known requires_prescription value" do
      pharmacy = create_pharmacy(slug: "farmacias_abc", name: "Farmacias ABC")
      medication = create_medication(requires_prescription: false)
      listing = create_raw_listing(pharmacy: pharmacy, requires_prescription: true)

      OfferBuilder.new(
        pharmacy: pharmacy, city: "Morelia, Michoacán",
        raw_listing_to_medication: { listing.id => medication }
      ).call

      assert_equal false, medication.reload.requires_prescription
    end
  end
end

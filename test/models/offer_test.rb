require "test_helper"

class OfferTest < ActiveSupport::TestCase
  test "cheapest_first orders by price_per_mg ascending" do
    pharmacy = create_pharmacy
    medication = create_medication

    expensive = create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 2.50)
    cheap = create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 0.80)
    mid = create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.20)

    ordered = medication.offers.cheapest_first.to_a
    assert_equal [ cheap, mid, expensive ], ordered
  end

  test "active scope excludes inactive offers" do
    pharmacy = create_pharmacy
    medication = create_medication

    active_offer = create_offer(medication: medication, pharmacy: pharmacy, active: true)
    create_offer(medication: medication, pharmacy: pharmacy, active: false)

    assert_equal [ active_offer ], medication.offers.active.to_a
  end

  test "price returns cents as a decimal peso amount" do
    offer = create_offer(medication: create_medication, pharmacy: create_pharmacy, price_cents: 4851)
    assert_in_delta 48.51, offer.price, 0.001
  end

  test "price_per_pill divides the box price by the pack quantity" do
    pharmacy = create_pharmacy
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: 20)
    offer = create_offer(medication: create_medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000)

    assert_in_delta 3.0, offer.price_per_pill, 0.001
  end

  test "price_per_pill is nil when the pack quantity is unknown" do
    pharmacy = create_pharmacy
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: nil)
    offer = create_offer(medication: create_medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000)

    assert_nil offer.price_per_pill
  end

  test "price_per_pill is nil for a single-unit pack, where it would just repeat the box price" do
    pharmacy = create_pharmacy
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: 1)
    offer = create_offer(medication: create_medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000)

    assert_nil offer.price_per_pill
  end

  test "deduplicated collapses the identical product listed twice at the same price" do
    pharmacy = create_pharmacy
    medication = create_medication
    2.times do |i|
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Clonazepam 2 mg, 30 Tabletas.",
        price_cents: 6400, product_url: "https://example.invalid/clona-#{i}")
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6400, price_per_mg: 1.0)
    end

    offers = medication.offers.includes(:raw_listing).cheapest_first
    assert_equal 2, offers.size
    assert_equal 1, Offer.deduplicated(offers).size
  end

  test "deduplicated collapses listings whose prices differ only trivially" do
    pharmacy = create_pharmacy
    medication = create_medication
    [ 6399, 6401 ].each_with_index do |cents, i|
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Clonazepam 2 mg, 30 Tabletas.",
        price_cents: cents, product_url: "https://example.invalid/c-#{i}")
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: cents, price_per_mg: 1.0)
    end

    offers = medication.offers.includes(:raw_listing).cheapest_first
    assert_equal 1, Offer.deduplicated(offers).size
  end

  test "deduplicated keeps a genuinely cheaper listing of the same product name" do
    pharmacy = create_pharmacy
    medication = create_medication
    [ 6400, 14_651 ].each_with_index do |cents, i|
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Clonazepam 2 mg, 30 Tabletas.",
        price_cents: cents, product_url: "https://example.invalid/d-#{i}")
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: cents, price_per_mg: cents / 100.0)
    end

    offers = medication.offers.includes(:raw_listing).cheapest_first
    assert_equal 2, Offer.deduplicated(offers).size,
      "a meaningfully different price is a real alternative, not a duplicate"
  end

  test "deduplicated keeps the cheapest of a duplicate set" do
    pharmacy = create_pharmacy
    medication = create_medication
    [ 6401, 6399 ].each_with_index do |cents, i|
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Clonazepam 2 mg, 30 Tabletas.",
        price_cents: cents, product_url: "https://example.invalid/e-#{i}")
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: cents, price_per_mg: cents / 100.0)
    end

    offers = medication.offers.includes(:raw_listing).cheapest_first
    assert_equal 6399, Offer.deduplicated(offers).first.price_cents
  end

  test "deduplicated keeps the same product sold by different pharmacies" do
    medication = create_medication
    2.times do
      pharmacy = create_pharmacy
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Clonazepam 2 mg, 30 Tabletas.", price_cents: 6400)
      create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6400, price_per_mg: 1.0)
    end

    offers = medication.offers.includes(:raw_listing).cheapest_first
    assert_equal 2, Offer.deduplicated(offers).size,
      "the same product at two different pharmacies is the whole point of the site"
  end

  test "unit words follow the product's own dosage form" do
    pharmacy = create_pharmacy
    medication = create_medication

    {
      "Paracetamol 500 mg, 20 Tabletas Pharmalife." => [ "tableta", "tabletas" ],
      "Omeprazol 20 mg, 7 Cápsulas Pharmalife."     => [ "cápsula", "cápsulas" ],
      "Alka Seltzer Caja con 12 Comprimidos"        => [ "comprimido", "comprimidos" ],
      "Hepa-Merz 3 gr, 30 Sobres Granulado."        => [ "sobre", "sobres" ],
      "Voltaren 24H 5 Parches"                      => [ "parche", "parches" ]
    }.each do |raw_name, (singular, plural)|
      listing = create_raw_listing(pharmacy: pharmacy, raw_name: raw_name, pack_quantity: 10)
      offer = create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing)

      assert_equal singular, offer.unit_singular, "wrong singular for #{raw_name}"
      assert_equal plural, offer.unit_plural, "wrong plural for #{raw_name}"
    end
  end

  test "unit words fall back to pieza when the name states no dosage form" do
    pharmacy = create_pharmacy
    listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Electrolit Coco 625ml", pack_quantity: 4)
    offer = create_offer(medication: create_medication, pharmacy: pharmacy, raw_listing: listing)

    assert_equal "pieza", offer.unit_singular
    assert_equal "piezas", offer.unit_plural
  end

  test "capsule products are never labelled tabletas" do
    pharmacy = create_pharmacy
    listing = create_raw_listing(pharmacy: pharmacy, raw_name: "Clendix 300 mg, 16 Cápsulas.", pack_quantity: 16)
    offer = create_offer(medication: create_medication, pharmacy: pharmacy, raw_listing: listing)

    assert_equal "cápsulas", offer.unit_plural
  end

  test "price_per_pill rounds to two decimal places" do
    pharmacy = create_pharmacy
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 1000, pack_quantity: 3)
    offer = create_offer(medication: create_medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 1000)

    assert_equal 3.33, offer.price_per_pill
  end
end

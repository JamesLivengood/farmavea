require "test_helper"

class MedicationsControllerTest < ActionDispatch::IntegrationTest
  test "index lists a common medication with its cheapest offer" do
    pharmacy = create_pharmacy
    common = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: common, pharmacy: pharmacy, price_per_mg: 1.0, city: "Morelia, Michoacán")

    get root_path
    assert_response :success
    assert_match(/Paracetamol 500mg/, response.body)
  end

  test "index excludes offers from a different city" do
    pharmacy = create_pharmacy
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0, city: "Some Other City")

    get root_path
    assert_response :success
    assert_no_match(/Paracetamol 500mg/, response.body)
  end

  test "index shows only one row per medication, the cheapest, even with multiple offers" do
    pharmacy = create_pharmacy
    medication = create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 5.0, city: "Morelia, Michoacán")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0, city: "Morelia, Michoacán")

    get root_path
    assert_response :success
    assert_equal 1, response.body.scan(/Ibuprofeno 400mg/).size
  end

  test "index lists non-common medications in the paginated section below" do
    pharmacy = create_pharmacy
    obscure = create_medication(canonical_name: "Medicamento Obscuro", strength_value: 5, strength_unit: "mg")
    create_offer(medication: obscure, pharmacy: pharmacy, price_per_mg: 1.0)

    get root_path
    assert_response :success
    assert_match(/Medicamento Obscuro/, response.body)
    assert_match(/Todos los medicamentos/, response.body)
  end

  test "index shows the empty state only when there are no offers at all" do
    get root_path
    assert_response :success
    assert_match(/Aún no hay precios cargados/, response.body)
  end

  test "index features the cheapest strength when a common generic has several" do
    pharmacy = create_pharmacy
    cheap = create_medication(canonical_name: "Levotiroxina", strength_value: 100, strength_unit: "mcg")
    pricey = create_medication(canonical_name: "Levotiroxina", strength_value: 25, strength_unit: "mcg")
    create_offer(medication: cheap, pharmacy: pharmacy, price_per_mg: 0.5)
    create_offer(medication: pricey, pharmacy: pharmacy, price_per_mg: 9.0)

    get root_path
    assert_response :success

    # The cheapest strength is promoted into the featured section...
    featured = response.body.split("Todos los medicamentos").first
    assert_match(/Levotiroxina 100mcg/, featured)
    assert_no_match(/Levotiroxina 25mcg/, featured)

    # ...and the other strength still appears below rather than being hidden.
    assert_match(/Levotiroxina 25mcg/, response.body)
  end

  test "index paginates the non-featured medications" do
    pharmacy = create_pharmacy
    (MedicationsController::PER_PAGE + 5).times do |i|
      med = create_medication(canonical_name: "Relleno #{i}", strength_value: i + 1, strength_unit: "mg")
      create_offer(medication: med, pharmacy: pharmacy, price_per_mg: (i + 1).to_f)
    end

    get root_path
    assert_response :success
    assert_equal MedicationsController::PER_PAGE, response.body.scan(/Relleno \d+ /).size
    assert_match(/Siguiente/, response.body)
  end

  test "index page 2 shows the remaining medications and a back link" do
    pharmacy = create_pharmacy
    (MedicationsController::PER_PAGE + 5).times do |i|
      med = create_medication(canonical_name: "Relleno #{i}", strength_value: i + 1, strength_unit: "mg")
      create_offer(medication: med, pharmacy: pharmacy, price_per_mg: (i + 1).to_f)
    end

    get root_path(page: 2)
    assert_response :success
    assert_equal 5, response.body.scan(/Relleno \d+ /).size
    assert_match(/Anterior/, response.body)
  end

  test "index only shows the featured section on page 1" do
    pharmacy = create_pharmacy
    common = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: common, pharmacy: pharmacy, price_per_mg: 0.1)
    (MedicationsController::PER_PAGE + 5).times do |i|
      med = create_medication(canonical_name: "Relleno #{i}", strength_value: i + 1, strength_unit: "mg")
      create_offer(medication: med, pharmacy: pharmacy, price_per_mg: (i + 10).to_f)
    end

    get root_path(page: 2)
    assert_response :success
    assert_no_match(/Los más buscados/, response.body)
  end

  test "index hides offers from pharmacies that do not serve Morelia" do
    serving = create_pharmacy(slug: "benavides", name: "Farmacias Benavides")
    not_serving = create_pharmacy(slug: "heb", name: "HEB")
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")

    # The non-serving pharmacy has the cheaper price - it must still not be shown,
    # and must not win the "cheapest" slot.
    create_offer(medication: medication, pharmacy: not_serving, price_per_mg: 0.1)
    create_offer(medication: medication, pharmacy: serving, price_per_mg: 5.0)

    get root_path
    assert_response :success
    assert_match(/Farmacias Benavides/, response.body)
    assert_no_match(/HEB/, response.body)
  end

  test "show hides offers from pharmacies that do not serve Morelia" do
    serving = create_pharmacy(slug: "guadalajara", name: "Farmacias Guadalajara")
    not_serving = create_pharmacy(slug: "yza", name: "YZA Farmacias")
    medication = create_medication

    create_offer(medication: medication, pharmacy: not_serving, price_per_mg: 0.1)
    create_offer(medication: medication, pharmacy: serving, price_per_mg: 5.0)

    get medication_path(medication)
    assert_response :success
    assert_match(/Farmacias Guadalajara/, response.body)
    assert_no_match(/YZA/, response.body)
  end

  test "search prices ignore pharmacies that do not serve Morelia" do
    serving = create_pharmacy(slug: "del_ahorro", name: "Farmacia del Ahorro")
    not_serving = create_pharmacy(slug: "farmacias_abc", name: "Farmacias ABC")
    medication = create_medication(canonical_name: "Escitalopram", strength_value: 10, strength_unit: "mg")

    create_offer(medication: medication, pharmacy: not_serving, price_per_mg: 0.1)
    create_offer(medication: medication, pharmacy: serving, price_per_mg: 5.0)

    get search_path, params: { q: "escitalopram" }
    assert_response :success
    # The displayed "desde" price must come from the serving pharmacy (5.0), not
    # the cheaper non-serving one (0.1).
    assert_no_match(/0\.1000/, response.body)
  end

  test "an excluded pharmacy's offers are still stored, just not displayed" do
    not_serving = create_pharmacy(slug: "heb", name: "HEB")
    medication = create_medication
    offer = create_offer(medication: medication, pharmacy: not_serving, price_per_mg: 0.1)

    assert Offer.exists?(offer.id), "the offer must remain in the database"
    assert_not Offer.purchasable.exists?(offer.id), "but must be excluded from displayable offers"
  end

  test "show warns that availability is not confirmed" do
    pharmacy = create_pharmacy
    medication = create_medication
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    get medication_path(medication)
    assert_response :success
    assert_match(/No podemos confirmar la disponibilidad/, response.body)
    assert_match(/Consulta directamente con la farmacia/, response.body)
  end

  test "show omits the availability warning when there are no offers to caveat" do
    medication = create_medication

    get medication_path(medication)
    assert_response :success
    assert_no_match(/No podemos confirmar la disponibilidad/, response.body)
  end

  test "index pagination has no duplicates or gaps across pages" do
    pharmacy = create_pharmacy
    (MedicationsController::PER_PAGE * 2).times do |i|
      med = create_medication(canonical_name: "Relleno #{i}", strength_value: i + 1, strength_unit: "mg")
      # Deliberately give many of them the SAME price, so ties have to be broken
      # deterministically or rows would shift between pages.
      create_offer(medication: med, pharmacy: pharmacy, price_per_mg: (i.even? ? 1.0 : 2.0))
    end

    get root_path
    page1 = response.body.scan(/Relleno (\d+) /).flatten
    get root_path(page: 2)
    page2 = response.body.scan(/Relleno (\d+) /).flatten

    assert_equal MedicationsController::PER_PAGE, page1.size
    assert_empty(page1 & page2, "a medication must not appear on two pages")
  end

  test "show displays a per-pill price when the pack size is known" do
    pharmacy = create_pharmacy
    medication = create_medication
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: 20)
    create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000, price_per_mg: 1.0)

    get medication_path(medication)
    assert_response :success
    assert_match(/\$3\.00 cada pieza/, response.body)
  end

  test "show displays the pack size next to the pharmacy name" do
    pharmacy = create_pharmacy
    medication = create_medication
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: 20)
    create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000, price_per_mg: 1.0)

    get medication_path(medication)
    assert_response :success
    assert_match(/20 piezas/, response.body)
  end

  test "show omits the pack size when it is unknown" do
    pharmacy = create_pharmacy
    medication = create_medication
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: nil)
    create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000, price_per_mg: 1.0)

    get medication_path(medication)
    assert_response :success
    assert_no_match(/piezas/, response.body)
  end

  test "show omits the per-pill price when the pack size is unknown" do
    pharmacy = create_pharmacy
    medication = create_medication
    listing = create_raw_listing(pharmacy: pharmacy, price_cents: 6000, pack_quantity: nil)
    create_offer(medication: medication, pharmacy: pharmacy, raw_listing: listing, price_cents: 6000, price_per_mg: 1.0)

    get medication_path(medication)
    assert_response :success
    assert_no_match(/cada (tableta|cápsula|pieza)/, response.body)
  end

  test "index treats a junk page param as page 1" do
    pharmacy = create_pharmacy
    common = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: common, pharmacy: pharmacy, price_per_mg: 1.0)

    get root_path(page: "not-a-number")
    assert_response :success
    assert_match(/Paracetamol 500mg/, response.body)
  end

  test "search with a blank query returns success with no results, not an error" do
    get search_path, params: { q: "" }
    assert_response :success
  end

  test "search finds a medication by canonical name" do
    medication = create_medication(canonical_name: "Escitalopram", strength_value: 10, strength_unit: "mg")

    get search_path, params: { q: "escitalopram" }
    assert_response :success
    assert_match(/Escitalopram/, response.body)
  end

  test "search finds a medication by a mapped brand name" do
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    pharmacy = create_pharmacy
    NameMapping.create!(pharmacy: pharmacy, raw_name: "Tylenol", medication: medication, confidence: 1.0, source: "claude")

    get search_path, params: { q: "tylenol" }
    assert_response :success
    assert_match(/Paracetamol/, response.body)
  end

  test "search for something with no matches renders success with an empty-state message" do
    get search_path, params: { q: "completely-made-up-drug-xyz" }
    assert_response :success
    assert_match(/No encontramos/, response.body)
  end

  test "show lists every active offer for the medication, cheapest first" do
    pharmacy_a = create_pharmacy(name: "Pharmacy A")
    pharmacy_b = create_pharmacy(name: "Pharmacy B")
    medication = create_medication

    create_offer(medication: medication, pharmacy: pharmacy_a, price_per_mg: 2.0)
    create_offer(medication: medication, pharmacy: pharmacy_b, price_per_mg: 1.0)

    get medication_path(medication)
    assert_response :success

    cheap_pos = response.body.index("Pharmacy B")
    expensive_pos = response.body.index("Pharmacy A")
    assert cheap_pos < expensive_pos, "the cheaper offer (Pharmacy B) should render before the pricier one (Pharmacy A)"
  end

  test "show excludes inactive offers" do
    pharmacy = create_pharmacy
    medication = create_medication
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0, active: false)

    get medication_path(medication)
    assert_response :success
    assert_match(/No hay precios disponibles/, response.body)
  end

  test "show 404s for a nonexistent medication id" do
    get medication_path(id: 999_999_999)
    assert_response :not_found
  end

  test "autocomplete returns JSON suggestions matching the query" do
    medication = create_medication(canonical_name: "Sertralina", strength_value: 50, strength_unit: "mg")

    get autocomplete_path, params: { q: "sertra" }, as: :json
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 1, body.size
    assert_equal medication.display_strength, body.first["label"]
  end

  test "autocomplete returns an empty array for a blank query" do
    get autocomplete_path, params: { q: "" }, as: :json
    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "autocomplete caps results at 8" do
    9.times { |i| create_medication(canonical_name: "Multitest", strength_value: i + 1, strength_unit: "mg") }

    get autocomplete_path, params: { q: "multitest" }, as: :json
    assert_response :success
    assert_equal 8, JSON.parse(response.body).size
  end
end

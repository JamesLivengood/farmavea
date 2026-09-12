require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "the privacy notice is reachable" do
    get privacy_path
    assert_response :success
    assert_select "h1", text: /Aviso de privacidad/
  end

  test "every page links to the privacy notice" do
    pharmacy = create_pharmacy
    medication = create_medication
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    [ root_path, medication_path(medication), search_path(q: "test") ].each do |path|
      get path
      assert_select "a[href=?]", privacy_path, { minimum: 1 }, "no privacy link on #{path}"
    end
  end

  # The notice makes specific claims about what is and isn't stored. If the
  # tracking changes without the notice changing, the notice becomes a false
  # statement rather than a disclosure - these tie the two together.
  test "the notice's claims match what the tracker actually does" do
    get root_path, headers: {
      "REMOTE_ADDR" => "203.0.113.9",
      "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh) Chrome/124",
      "HTTP_REFERER" => "https://www.google.com/search?q=something+private"
    }
    visit = PageVisit.last

    # "No guardamos tu dirección IP"
    assert_no_match(/203\.0\.113\.9/, visit.attributes.values.join(" "))

    # "solo el dominio ... nunca la dirección completa"
    assert_equal "www.google.com", visit.referrer_host

    # "no tenemos cuentas de usuario" - nothing here should identify a person
    assert_nil PageVisit.column_names.find { |c| c.match?(/email|name|phone|address/) }
  end

  test "the visitor id rotates daily, as the notice claims" do
    today = PageVisit.visitor_hash_for(ip: "203.0.113.9", user_agent: "UA", on: Date.current)
    tomorrow = PageVisit.visitor_hash_for(ip: "203.0.113.9", user_agent: "UA", on: Date.current + 1)
    assert_not_equal today, tomorrow
  end

  # The homepage links only a few dozen medications, so without a sitemap the other
  # ~2,000 are reachable to search engines only by luck.
  test "the sitemap lists medications that have a purchasable offer" do
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: create_pharmacy(slug: "benavides"))

    get sitemap_path

    assert_response :success
    assert_equal "application/xml", @response.media_type
    assert_includes @response.body, "https://farmavea.com/medications/#{medication.id}"
    assert_includes @response.body, "https://farmavea.com/"
  end

  test "a medication with no purchasable offer is left out of the sitemap" do
    listed = create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
    create_offer(medication: listed, pharmacy: create_pharmacy(slug: "benavides"))
    # No offer at all: a page with no prices is a poor search result.
    unlisted = create_medication(canonical_name: "Fantasmol", strength_value: 10, strength_unit: "mg")

    get sitemap_path

    assert_includes @response.body, "/medications/#{listed.id}"
    assert_not_includes @response.body, "/medications/#{unlisted.id}"
  end

  # The disclaimer must be on the page before anyone types, not only in the privacy
  # notice - it exists so people do not mistake the chat for clinical advice.
  test "the chat widget states that it is not medical advice" do
    get root_path

    assert_response :success
    assert_includes @response.body, "Esto no es asesoría médica"
    assert_includes @response.body, "sustituye el diagnóstico"
  end

  # A US nursing licence does not authorise practice in Mexico, which requires a
  # cédula profesional from the SEP. The widget may state the licence as a fact but
  # must never imply a Mexican credential or that this site vouches for one.
  test "the chat widget does not claim a verified or Mexican nursing credential" do
    get root_path

    body = @response.body
    assert_includes body, "licencia en EE.UU."
    assert_not_includes body, "enfermera verificada"
    assert_not_includes body, "verificada"
    assert_not_includes body, "certificada en México"
  end

  test "the privacy notice explains that chat messages are stored" do
    get privacy_path

    assert_response :success
    assert_includes @response.body, "El chat"
    assert_includes @response.body, "no es asesoría médica"
  end

  test "robots.txt points crawlers at the sitemap" do
    robots = Rails.root.join("public", "robots.txt").read

    assert_includes robots, "Sitemap: https://farmavea.com/sitemap.xml"
    assert_includes robots, "Disallow: /autocomplete"
  end
end

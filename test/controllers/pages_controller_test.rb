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
      assert_select "a[href=?]", privacy_path, { count: 1 }, "no privacy link on #{path}"
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
end

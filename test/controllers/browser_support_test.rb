require "test_helper"

# Rails' default `allow_browser versions: :modern` served a hard "browser not
# supported" page to real visitors on older iPhones, even though every page here
# is server-rendered and works fine without JavaScript. These guard against that
# gate being reintroduced.
class BrowserSupportTest < ActionDispatch::IntegrationTest
  OLD_IPHONE_AGENTS = {
    "iOS 16.7 (Safari 16.6)" => "Mozilla/5.0 (iPhone; CPU iPhone OS 16_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1",
    "iOS 15.8 (Safari 15.6)" => "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6 Mobile/15E148 Safari/604.1",
    "iOS 12.5 (Safari 12.1)" => "Mozilla/5.0 (iPhone; CPU iPhone OS 12_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.1.2 Mobile/15E148 Safari/604.1"
  }.freeze

  test "old iPhones can load the homepage" do
    pharmacy = create_pharmacy
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    OLD_IPHONE_AGENTS.each do |label, agent|
      get root_path, headers: { "HTTP_USER_AGENT" => agent }
      assert_response :success, "#{label} should not be blocked from the homepage"
      assert_match(/Paracetamol 500mg/, response.body, "#{label} should see real prices")
    end
  end

  test "old iPhones can search" do
    pharmacy = create_pharmacy
    medication = create_medication(canonical_name: "Ibuprofeno", strength_value: 400, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    OLD_IPHONE_AGENTS.each do |label, agent|
      get search_path, params: { q: "ibuprofeno" }, headers: { "HTTP_USER_AGENT" => agent }
      assert_response :success, "#{label} should not be blocked from search"
      assert_match(/Ibuprofeno/, response.body)
    end
  end

  test "old iPhones can view a medication's prices" do
    pharmacy = create_pharmacy
    medication = create_medication
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    OLD_IPHONE_AGENTS.each do |label, agent|
      get medication_path(medication), headers: { "HTTP_USER_AGENT" => agent }
      assert_response :success, "#{label} should not be blocked from a medication page"
    end
  end

  test "the search form works without JavaScript" do
    # The dropdown is a progressive enhancement - the form itself must be a plain
    # GET that works with no JS at all, which is what old Safari falls back to.
    get root_path
    assert_response :success
    assert_select "form[action=?][method=?]", search_path, "get"
    assert_select "form input[name=?]", "q"
  end
end

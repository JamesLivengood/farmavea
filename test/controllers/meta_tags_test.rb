require "test_helper"

# Open Graph tags fail silently - a broken or missing tag looks completely normal
# in a browser and only shows up when someone shares a link and gets a blank card.
class MetaTagsTest < ActionDispatch::IntegrationTest
  test "every page has the core Open Graph tags" do
    pharmacy = create_pharmacy
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    [ root_path, medication_path(medication), search_path(q: "paracetamol") ].each do |path|
      get path
      assert_response :success

      %w[og:title og:description og:image og:url].each do |property|
        assert_select "meta[property='#{property}']", { count: 1 }, "missing #{property} on #{path}"
      end
      assert_select "meta[name='description']", { count: 1 }, "missing meta description on #{path}"
      assert_select "meta[name='twitter:card']", { count: 1 }, "missing twitter:card on #{path}"
    end
  end

  test "og:image is an absolute URL" do
    get root_path
    image = css_select("meta[property='og:image']").first["content"]

    # Social platforms fetch this from their own servers - a relative path yields a
    # card with no image at all.
    assert_match %r{\Ahttps?://}, image, "og:image must be absolute, got #{image.inspect}"
    assert_match(/og-image\.png\z/, image)
  end

  test "a medication page describes that specific medication, not the site default" do
    pharmacy = create_pharmacy
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    create_offer(medication: medication, pharmacy: pharmacy, price_cents: 6391, price_per_mg: 1.0)

    get medication_path(medication)

    description = css_select("meta[property='og:description']").first["content"]
    assert_match(/Paracetamol 500mg/, description)
    assert_match(/\$63\.91/, description, "should lead with the cheapest real price")

    title = css_select("meta[property='og:title']").first["content"]
    assert_match(/Paracetamol 500mg/, title)
  end

  test "a medication page with no offers still gets a sensible description" do
    medication = create_medication(canonical_name: "Sin Ofertas", strength_value: 10, strength_unit: "mg")

    get medication_path(medication)
    assert_response :success

    description = css_select("meta[property='og:description']").first["content"]
    assert_match(/Sin Ofertas 10mg/, description)
    assert_no_match(/\$/, description, "shouldn't quote a price when there are none")
  end

  test "the pharmacy count in a description uses Spanish pluralisation" do
    medication = create_medication(canonical_name: "Paracetamol", strength_value: 500, strength_unit: "mg")
    2.times do
      pharmacy = create_pharmacy
      create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)
    end

    get medication_path(medication)
    description = css_select("meta[property='og:description']").first["content"]

    # Rails' pluralize is English-only and rendered this as "2 farmacia".
    assert_match(/2 farmacias/, description)
  end

  test "og:url points at the page being viewed" do
    pharmacy = create_pharmacy
    medication = create_medication
    create_offer(medication: medication, pharmacy: pharmacy, price_per_mg: 1.0)

    get medication_path(medication)
    url = css_select("meta[property='og:url']").first["content"]

    assert_match(%r{/medications/#{medication.id}\z}, url)
  end

  test "every page has a canonical link" do
    get root_path
    assert_select "link[rel='canonical']", count: 1
  end

  test "www and apex hosts produce the same canonical URL and image" do
    # Left unnormalised, www.farmavea.com and farmavea.com emit different og:image
    # and canonical URLs, so Meta caches them as two separate pages.
    get root_path, headers: { "HTTP_HOST" => "www.farmavea.com" }
    www_canonical = css_select("link[rel='canonical']").first["href"]
    www_image = css_select("meta[property='og:image']").first["content"]
    www_url = css_select("meta[property='og:url']").first["content"]

    get root_path, headers: { "HTTP_HOST" => "farmavea.com" }
    apex_canonical = css_select("link[rel='canonical']").first["href"]
    apex_image = css_select("meta[property='og:image']").first["content"]
    apex_url = css_select("meta[property='og:url']").first["content"]

    assert_equal apex_canonical, www_canonical
    assert_equal apex_image, www_image
    assert_equal apex_url, www_url
    assert_match %r{\Ahttps://farmavea\.com}, apex_canonical
  end

  test "non-production hosts keep their own host so local links still work" do
    get root_path, headers: { "HTTP_HOST" => "localhost" }
    image = css_select("meta[property='og:image']").first["content"]

    assert_match %r{\Ahttp://localhost}, image,
      "localhost shouldn't be rewritten to the production host"
  end
end

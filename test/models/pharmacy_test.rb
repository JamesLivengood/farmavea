require "test_helper"

class PharmacyTest < ActiveSupport::TestCase
  test "requires a unique name" do
    create_pharmacy(name: "Farmacia Ejemplo", slug: "one")
    duplicate = Pharmacy.new(name: "Farmacia Ejemplo", slug: "two", base_url: "https://example.invalid")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:name], "has already been taken"
  end

  test "requires a unique slug" do
    create_pharmacy(slug: "shared_slug", name: "First")
    duplicate = Pharmacy.new(slug: "shared_slug", name: "Second", base_url: "https://example.invalid")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], "has already been taken"
  end

  test "requires a base_url" do
    pharmacy = Pharmacy.new(name: "No URL", slug: "no-url", base_url: nil)
    assert_not pharmacy.valid?
    assert_includes pharmacy.errors[:base_url], "can't be blank"
  end

  test "active scope excludes inactive pharmacies" do
    active = create_pharmacy(slug: "active-one", name: "Active One", active: true)
    create_pharmacy(slug: "inactive-one", name: "Inactive One", active: false)

    assert_equal [ active ], Pharmacy.active.to_a
  end
end

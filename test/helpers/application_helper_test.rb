require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  # The homepage badge used to say "Actualizado hoy" unconditionally, over prices
  # that were ten days old. On a site people use to decide where to spend money,
  # that is the one claim that must never be decorative.
  test "the freshness label reflects how old the prices actually are" do
    assert_equal "Actualizado hoy", price_freshness_label(Time.current)
    assert_equal "Actualizado ayer", price_freshness_label(1.day.ago)
    assert_equal "Actualizado hace 3 días", price_freshness_label(3.days.ago)
    assert_equal "Precios de hace más de una semana", price_freshness_label(10.days.ago)
  end

  test "the freshness label is honest when there are no prices at all" do
    assert_equal "Sin precios recientes", price_freshness_label(nil)
  end
end

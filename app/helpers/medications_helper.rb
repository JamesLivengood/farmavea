module MedicationsHelper
  PHARMACY_BADGE_STYLES = {
    "del_ahorro" => "bg-orange-50 text-orange-700 ring-1 ring-inset ring-orange-200",
    "guadalajara" => "bg-blue-50 text-blue-700 ring-1 ring-inset ring-blue-200",
    "chedraui" => "bg-purple-50 text-purple-700 ring-1 ring-inset ring-purple-200"
  }.freeze

  DEFAULT_BADGE_STYLE = "bg-slate-100 text-slate-600 ring-1 ring-inset ring-slate-200".freeze

  def pharmacy_badge_classes(pharmacy)
    PHARMACY_BADGE_STYLES.fetch(pharmacy.slug, DEFAULT_BADGE_STYLE)
  end

  def format_price(amount)
    number_to_currency(amount, unit: "$", precision: 2)
  end

  # Social/search preview text for a medication page. Leads with the cheapest real
  # price when we have one, since that's the thing worth clicking through for.
  def medication_share_description(medication, offers)
    cheapest = offers.find { |offer| offer.price_per_mg.present? } || offers.first
    pharmacy_count = offers.map(&:pharmacy_id).uniq.size

    if cheapest
      # Spanish plural, not Rails' English pluralize - that produced "7 farmacia".
      farmacias = "#{pharmacy_count} #{pharmacy_count == 1 ? 'farmacia' : 'farmacias'}"
      "Desde #{format_price(cheapest.price)} en #{farmacias}. " \
        "Compara precios de #{medication.display_strength} y encuentra la opción más barata."
    else
      "Compara precios de #{medication.display_strength} entre farmacias en Morelia."
    end
  end

  def format_price_per_mg(amount)
    "#{number_to_currency(amount, unit: '$', precision: 4)} / mg"
  end

  # Reads as "$0.64 cada tableta" - spelled out rather than abbreviated "c/u", and
  # using the product's own dosage-form word so it stays consistent with the
  # "100 tabletas" pack-size badge shown beside it.
  def format_price_per_pill(offer)
    "#{number_to_currency(offer.price_per_pill, unit: '$', precision: 2)} cada #{offer.unit_singular}"
  end

  # "100 tabletas" / "30 cápsulas" - the pack size in the product's own wording.
  def format_pack_size(offer)
    "#{offer.raw_listing.pack_quantity} #{offer.unit_plural}"
  end
end

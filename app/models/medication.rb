class Medication < ApplicationRecord
  has_many :name_mappings, dependent: :destroy
  has_many :offers, dependent: :destroy

  validates :canonical_name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :generate_slug, on: :create

  scope :search, ->(query) {
    where("canonical_name ILIKE :q", q: "%#{sanitize_sql_like(query)}%")
      .or(where(id: NameMapping.where("raw_name ILIKE :q", q: "%#{sanitize_sql_like(query)}%").select(:medication_id)))
  }

  # Someone searching a brand ("Aspirina", "Avirena") gets results named after the
  # active ingredient, which they may not recognise as what they asked for. This
  # returns { medication_id => "Aspirina" } so each result can show the brand that
  # matched it, making the generic/brand connection visible instead of implied.
  def self.brand_matches_for(query, medication_ids)
    return {} if query.blank? || medication_ids.empty?

    NameMapping.where(medication_id: medication_ids)
               .where("raw_name ILIKE :q", q: "%#{sanitize_sql_like(query)}%")
               .pluck(:medication_id, :raw_name)
               .each_with_object({}) do |(id, raw_name), matches|
      # The raw listing is a full product title; show just the word the visitor
      # typed, capitalised as they'd recognise it, not the whole scraped name.
      matches[id] ||= extract_brand_token(raw_name, query)
    end
  end

  # Pulls the matched word out of a scraped product name, so "Aspirina Dolor de
  # Cabeza y Fiebre 40 Tabletas" shown for the query "aspirina" reads "Aspirina".
  def self.extract_brand_token(raw_name, query)
    word = raw_name.to_s.split(/\s+/).find { |w| w.downcase.include?(query.to_s.downcase) }
    (word || query).gsub(/[^\p{L}\p{N}\-]/, "")
  end

  def cheapest_offer(city:)
    offers.active.where(city: city).order(:price_per_mg).first
  end

  def display_strength
    return canonical_name if strength_value.blank?
    "#{canonical_name} #{strength_value.to_s('F').sub(/\.0$/, '')}#{strength_unit}"
  end

  private

  def generate_slug
    return if slug.present?
    base = canonical_name.to_s.parameterize
    if strength_value.present?
      base += "-#{strength_value.to_s('F').sub(/\.0$/, '')}#{strength_unit}"
    end
    candidate = base
    n = 1
    while Medication.exists?(slug: candidate)
      n += 1
      candidate = "#{base}-#{n}"
    end
    self.slug = candidate
  end
end

class PagesController < ApplicationController
  # Bump this whenever the privacy notice's contents change.
  PRIVACY_LAST_UPDATED = Date.new(2026, 9, 7).freeze

  def privacy
  end
end

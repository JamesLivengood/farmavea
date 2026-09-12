module ApplicationHelper
  # The one host social platforms and search engines should attribute pages to.
  # Without pinning this, www.farmavea.com and farmavea.com produce different
  # og:image and canonical URLs, so Meta caches them as two separate pages and any
  # link equity is split between them.
  CANONICAL_HOST = "https://farmavea.com".freeze

  # Absolute URL to the social share image. Open Graph and Twitter Card consumers
  # (WhatsApp, Facebook, iMessage, Slack) fetch this from their own servers, so a
  # relative path or a host-less URL silently produces a card with no image.
  def image_url_for_sharing
    URI.join(canonical_base_url, "/og-image.png").to_s
  end

  # How old the displayed prices actually are. Said plainly rather than optimistically:
  # someone deciding where to drive for a medication needs to know whether the figure
  # is from this morning or last week.
  def price_freshness_label(scraped_at)
    return "Sin precios recientes" if scraped_at.blank?

    days = (Date.current - scraped_at.to_date).to_i
    case days
    when 0 then "Actualizado hoy"
    when 1 then "Actualizado ayer"
    when 2..6 then "Actualizado hace #{days} días"
    else "Precios de hace más de una semana"
    end
  end

  SPANISH_MONTHS = %w[
    enero febrero marzo abril mayo junio
    julio agosto septiembre octubre noviembre diciembre
  ].freeze

  # "7 de septiembre de 2026". Rails' `l` needs a Spanish locale configured, which
  # this app doesn't have - without one it renders "7 de September de 2026", which
  # reads badly on a page written in Spanish.
  def spanish_date(date)
    "#{date.day} de #{SPANISH_MONTHS[date.month - 1]} de #{date.year}"
  end

  # This page's URL on the canonical host, preserving the path and any query.
  def canonical_page_url
    uri = URI.parse(request.original_url)
    URI.join(canonical_base_url, uri.path).to_s
  rescue URI::InvalidURIError
    canonical_base_url
  end

  private

  # Production traffic is normalised onto CANONICAL_HOST; anywhere else (localhost,
  # the fly.dev hostname, a preview deploy) keeps its own host so links still work.
  def canonical_base_url
    request.host.to_s.end_with?("farmavea.com") ? CANONICAL_HOST : request.base_url
  end
end

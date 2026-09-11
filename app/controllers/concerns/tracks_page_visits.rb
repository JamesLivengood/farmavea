# Records page visits for analytics. See PageVisit and its migration for why the
# visitor id is a rotating one-way hash rather than an IP address.
#
# Every failure here is swallowed: analytics is never worth returning a 500 to
# someone trying to look up a medication price.
module TracksPageVisits
  extend ActiveSupport::Concern

  BOT_PATTERN = /bot|crawler|spider|crawling|facebookexternalhit|whatsapp|slackbot|bingpreview|headlesschrome|curl|wget|python-requests|ruby/i
  PHONE_PATTERN = /iphone|android.*mobile|windows phone|ipod/i
  TABLET_PATTERN = /ipad|android(?!.*mobile)|tablet/i

  included do
    after_action :track_page_visit
  end

  private

  def track_page_visit
    return unless request.get?
    return unless response.successful?
    # Don't log the JSON autocomplete endpoint - it fires on every keystroke and
    # would bury real page views in noise.
    return if request.path == "/autocomplete"

    user_agent = request.user_agent.to_s

    PageVisit.create!(
      visitor_hash: PageVisit.visitor_hash_for(ip: request.remote_ip, user_agent: user_agent),
      path: request.path.first(255),
      page_type: page_type_for(request.path),
      medication_id: tracked_medication_id,
      search_query: params[:q].presence&.first(100),
      referrer_host: referrer_host,
      device_type: device_type_for(user_agent),
      browser: browser_for(user_agent),
      # Fly-Client-IP-Country is the visitor's actual country (ISO-3166 alpha-2,
      # "MX"). Fly-Region, which this used to store, is the DATACENTRE that served
      # the request - so a Morelia visitor routed via Amsterdam recorded as "ams",
      # making the whole column read as international traffic that doesn't exist.
      country: fly_country,
      edge_region: request.headers["Fly-Region"].presence,
      visited_at: Time.current
    )
  rescue StandardError => e
    # Deliberately broad: a tracking bug must never take a page down.
    Rails.logger.warn("[TracksPageVisits] could not record visit: #{e.class}: #{e.message}")
  end

  def page_type_for(path)
    case path
    when "/" then "home"
    when "/search" then "search"
    when %r{\A/medications/\d+\z} then "medication"
    else "other"
    end
  end

  def tracked_medication_id
    return nil unless request.path.match?(%r{\A/medications/\d+\z})

    params[:id].to_i.positive? ? params[:id].to_i : nil
  end

  # Verified against production 2026-09-10: Fly's proxy sends NO country header.
  # The full set is Fly-Client-IP, Fly-Forwarded-{Port,Proto,Ssl}, Fly-Region,
  # Fly-Request-Id and Fly-Traceparent/Tracestate. Populating `country` therefore
  # needs a GeoIP lookup on Fly-Client-IP - a deliberate feature, not a header read,
  # so the column stays nil until that is built. `edge_region` is the datacentre
  # that served the request and is NOT a proxy for where the visitor is.
  def fly_country
    nil
  end

  # Host only, never the full referring URL - the path someone came from can leak
  # what they were reading elsewhere.
  def referrer_host
    return nil if request.referer.blank?

    host = URI.parse(request.referer).host
    return nil if host.blank? || host.end_with?("farmavea.com")

    host.first(120)
  rescue URI::InvalidURIError
    nil
  end

  def device_type_for(user_agent)
    return "bot" if user_agent.blank? || user_agent.match?(BOT_PATTERN)
    return "tablet" if user_agent.match?(TABLET_PATTERN)
    return "phone" if user_agent.match?(PHONE_PATTERN)

    "desktop"
  end

  def browser_for(user_agent)
    case user_agent
    when /edg/i then "Edge"
    when /opr|opera/i then "Opera"
    when /chrome|crios/i then "Chrome"
    when /firefox|fxios/i then "Firefox"
    when /safari/i then "Safari"
    end
  end
end

class ApplicationController < ActionController::Base
  include TracksPageVisits

  # No browser gate on purpose.
  #
  # Rails ships `allow_browser versions: :modern`, which turns away anything
  # lacking web push, badges, CSS nesting or CSS :has() - none of which this app
  # uses. It was serving a hard "browser not supported" page to real visitors on
  # older iPhones for no reason.
  #
  # Every page here is server-rendered and verified to work with JavaScript fully
  # disabled: browsing prices, searching (a plain GET form), and medication detail
  # all render completely. JS only adds the search box's recent-searches and
  # autocomplete dropdown, which degrade to an ordinary text input when import maps
  # aren't supported (Safari < 16.4). A visitor on an old phone should get the
  # prices they came for, not a wall.

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end

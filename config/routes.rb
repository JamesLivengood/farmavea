Rails.application.routes.draw do
  root "medications#index"

  get "search" => "medications#search", as: :search
  get "autocomplete" => "medications#autocomplete", as: :autocomplete
  get "medications/:id" => "medications#show", as: :medication

  # "Aviso de privacidad" is the term Mexican law (LFPDPPP) uses, so the URL uses
  # it too - it's what a Mexican visitor would look for.
  get "aviso-de-privacidad" => "pages#privacy", as: :privacy

  # Search engines find medication pages on their own by following links from the
  # homepage, which only lists a few dozen - a sitemap is how the other ~2,000
  # purchasable medications get discovered.
  get "sitemap.xml" => "pages#sitemap", as: :sitemap, defaults: { format: "xml" }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end

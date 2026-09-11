module Crawlers
  # Proasse (proasse.mx), Shopify. This is a specialty/high-cost medication pharmacy -
  # unlike Del Ahorro or Chedraui, its entire catalog is medications (confirmed by
  # sampling: no groceries, cosmetics, etc.), so the site-wide feed needs no
  # medication-only filtering. The narrower "medicamentos-*" collections are
  # Shopify Search & Discovery filtered collections that return empty via the
  # classic /collections/{handle}/products.json endpoint despite showing products
  # in their HTML pages - the site-wide feed is the only reliable JSON source.
  class ProasseCrawler < ShopifyCrawler
    private

    def base_url
      "https://proasse.mx"
    end

    def products_json_path
      "/products.json"
    end
  end
end

module Crawlers
  # Farmacias ABC (farmaciasabc.com), Shopify. The "farmacia" collection is the real
  # medications catalog (the "medicamentos" slug does not exist on this store).
  class FarmaciasAbcCrawler < ShopifyCrawler
    private

    def base_url
      "https://www.farmaciasabc.com"
    end

    def products_json_path
      "/collections/farmacia/products.json"
    end
  end
end

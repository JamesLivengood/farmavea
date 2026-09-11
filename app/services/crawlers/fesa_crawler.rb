module Crawlers
  # Farmacias Especializadas FESA (farmaciasespecializadas.com). Standard Magento
  # Luma theme, server-rendered category pages, no bot mitigation. Specializes in
  # high-cost/specialty medications (oncology, etc.) - the main /especialidades.html
  # category covers the full catalog.
  class FesaCrawler < MagentoCategoryCrawler
    private

    def base_url
      "https://www.farmaciasespecializadas.com"
    end

    def category_paths
      %w[/especialidades.html]
    end
  end
end

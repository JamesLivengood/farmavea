module Crawlers
  # Farmacias Probemedic (probemedic.mx). Standard Magento Luma theme (same agency
  # template as Benavides), server-rendered category pages, no bot mitigation.
  class ProbemedicCrawler < MagentoCategoryCrawler
    private

    def base_url
      "https://www.probemedic.mx"
    end

    def category_paths
      %w[/farmacias.html]
    end
  end
end

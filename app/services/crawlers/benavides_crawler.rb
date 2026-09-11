module Crawlers
  # Farmacias Benavides (benavides.com.mx). Standard Magento Luma theme, server-
  # rendered category pages, no bot mitigation observed. The top-level /medicamentos
  # nav entry is a CMS landing page (a curated carousel, not a real paginated grid) -
  # the actual product listings live under specific subcategories, discovered via
  # site navigation.
  class BenavidesCrawler < MagentoCategoryCrawler
    private

    def base_url
      "https://www.benavides.com.mx"
    end

    def category_paths
      %w[
        /medicamentos-dolor
        /medicamentos-antibioticos
        /medicamentos-estomacales
        /medicamentos-respiratorios
        /medicamentos-infecciones
        /medicamentos-otico
        /medicamentos-hemorroides
        /medicamentos-insomnio
        /medicamentos-pediatrico
        /medicamentos-especialidades-cardiologia
        /medicamentos-especialidades-dermatologia
        /medicamentos-especialidades-endocrinologia
        /medicamentos-especialidades-gastroenterologia
        /medicamentos-especialidades-ginecologia
        /medicamentos-especialidades-hematologia
        /medicamentos-especialidades-hipertension
        /medicamentos-especialidades-neurologia
        /medicamentos-especialidades-odontologia
        /medicamentos-especialidades-oftalmologia
        /medicamentos-especialidades-oncologia
        /medicamentos-especialidades-psiquiatria
        /medicamentos-especialidades-reumatologia
        /medicamentos-especialidades-urologia
      ]
    end
  end
end

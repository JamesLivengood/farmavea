# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

[
  { name: "Farmacia del Ahorro", slug: "del_ahorro", base_url: "https://www.fahorro.com" },
  { name: "Farmacias Guadalajara", slug: "guadalajara", base_url: "https://www.farmaciasguadalajara.com" },
  { name: "Chedraui", slug: "chedraui", base_url: "https://www.chedraui.com.mx" },
  { name: "Farmacias Benavides", slug: "benavides", base_url: "https://www.benavides.com.mx" },
  { name: "Farmacias Probemedic", slug: "probemedic", base_url: "https://www.probemedic.mx" },
  { name: "Farmacias Especializadas FESA", slug: "fesa", base_url: "https://www.farmaciasespecializadas.com" },
  { name: "Farmacias ABC", slug: "farmacias_abc", base_url: "https://www.farmaciasabc.com" },
  { name: "Proasse", slug: "proasse", base_url: "https://proasse.mx" },
  { name: "Farmacia Similares", slug: "farmacia_similares", base_url: "https://www.farmaciasdesimilares.com" },
  { name: "Farmacia Emergencias", slug: "farmacia_emergencias", base_url: "https://farmaciaemergencias.com.mx" },
  { name: "Costco", slug: "costco", base_url: "https://www.costco.com.mx" },
  { name: "YZA Farmacias", slug: "yza", base_url: "https://www.yza.mx" },
  { name: "HEB", slug: "heb", base_url: "https://www.heb.com.mx" },
  { name: "Farmalisto", slug: "farmalisto", base_url: "https://farmalisto.com.mx" },
  { name: "Vida Farmacias", slug: "vida_farmacias", base_url: "https://vidafarmacias.com" },
  { name: "Vitau", slug: "vitau", base_url: "https://vitau.mx" },
  { name: "Farmacia San Pablo", slug: "san_pablo", base_url: "https://www.farmaciasanpablo.com.mx" }
].each do |attrs|
  Pharmacy.find_or_create_by!(slug: attrs[:slug]) do |pharmacy|
    pharmacy.name = attrs[:name]
    pharmacy.base_url = attrs[:base_url]
    pharmacy.active = true
  end
end

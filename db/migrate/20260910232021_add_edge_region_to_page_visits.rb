class AddEdgeRegionToPageVisits < ActiveRecord::Migration[8.1]
  def up
    add_column :page_visits, :edge_region, :string

    # Existing `country` values are not countries: the tracker was storing the
    # Fly-Region header (the datacentre that served the request, e.g. "ams") in a
    # column named `country`. Move them to the column that actually describes them,
    # then null out `country` so nothing reads a datacentre code as geography.
    execute <<~SQL
      UPDATE page_visits SET edge_region = country WHERE country IS NOT NULL
    SQL
    execute <<~SQL
      UPDATE page_visits SET country = NULL
    SQL
  end

  def down
    execute <<~SQL
      UPDATE page_visits SET country = edge_region WHERE edge_region IS NOT NULL
    SQL
    remove_column :page_visits, :edge_region
  end
end

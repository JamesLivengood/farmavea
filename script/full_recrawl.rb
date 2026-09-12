# Recrawls every active pharmacy and reports what changed since the previous run.
#
# Each pharmacy is independent: one failing does not stop the rest, and results are
# reported per pharmacy as they finish so a long run can be watched in the log.
#
# Run with:
#   bin/rails runner script/full_recrawl.rb
#   ONLY=del_ahorro,chedraui bin/rails runner script/full_recrawl.rb

CITY = "Morelia, Michoacán".freeze

only = ENV["ONLY"].to_s.split(",").map(&:strip).reject(&:empty?)
pharmacies = only.any? ? Pharmacy.active.where(slug: only) : Pharmacy.active
abort "No pharmacies matched #{only.inspect}" if pharmacies.empty?

log = ->(msg) { puts "[#{Time.current.strftime('%H:%M:%S')}] #{msg}"; $stdout.flush }

log.call "Recrawling #{pharmacies.count} pharmacies"
puts "=" * 74

totals = { listings: 0, changed: 0, new: 0, gone: 0, failed: [] }
started_at = Time.current

pharmacies.each do |pharmacy|
  # Previous prices, keyed by product URL, so the new crawl can be diffed against
  # them. Taken from the latest completed run BEFORE this one starts.
  # Skip runs that produced nothing: a failed run would otherwise become the
  # baseline and make every product in the next crawl look brand new.
  previous_run = CrawlRun.where(pharmacy: pharmacy)
                         .where(id: RawListing.select(:crawl_run_id).distinct)
                         .order(created_at: :desc)
                         .first
  previous_prices =
    if previous_run
      RawListing.where(crawl_run: previous_run)
                .where.not(product_url: nil)
                .pluck(:product_url, :price_cents, :raw_name)
                .each_with_object({}) { |(url, cents, name), h| h[url] = [ cents, name ] }
    else
      {}
    end

  crawl_run = CrawlRun.create!(pharmacy: pharmacy, city: CITY, started_at: Time.current, status: "running")
  crawler_class = "Crawlers::#{pharmacy.slug.camelize}Crawler".safe_constantize

  unless crawler_class
    log.call "#{pharmacy.slug}: NO CRAWLER CLASS - skipped"
    crawl_run.update!(status: "failed", finished_at: Time.current)
    totals[:failed] << pharmacy.slug
    next
  end

  log.call "#{pharmacy.slug}: starting (had #{previous_prices.size} priced products)"

  begin
    count = crawler_class.new(pharmacy: pharmacy, crawl_run: crawl_run).call
    crawl_run.update!(status: "succeeded", finished_at: Time.current, items_found: count)

    current = RawListing.where(crawl_run: crawl_run)
                        .where.not(product_url: nil)
                        .pluck(:product_url, :price_cents, :raw_name)
                        .each_with_object({}) { |(url, cents, name), h| h[url] = [ cents, name ] }

    changed = current.filter_map do |url, (cents, name)|
      old = previous_prices[url]
      next if old.nil? || old[0] == cents
      [ name, old[0], cents ]
    end
    added = (current.keys - previous_prices.keys).size
    removed = (previous_prices.keys - current.keys).size

    totals[:listings] += count
    totals[:changed] += changed.size
    totals[:new] += added
    totals[:gone] += removed

    log.call "#{pharmacy.slug}: #{count} listings | #{changed.size} price changes | #{added} new | #{removed} gone"

    changed.sort_by { |_, old, new| -((new - old).abs.to_f / old) }.first(5).each do |name, old, new|
      pct = ((new - old) * 100.0 / old).round
      arrow = new > old ? "UP  " : "DOWN"
      puts "      #{arrow} #{pct.abs}%  $#{(old / 100.0).round(2)} -> $#{(new / 100.0).round(2)}  #{name.to_s[0, 46]}"
    end
  rescue StandardError => e
    crawl_run.update!(status: "failed", finished_at: Time.current)
    totals[:failed] << pharmacy.slug
    log.call "#{pharmacy.slug}: FAILED - #{e.class}: #{e.message.to_s[0, 160]}"
  end
end

puts "=" * 74
log.call "Done in #{((Time.current - started_at) / 60).round} min"
puts "  listings:      #{totals[:listings]}"
puts "  price changes: #{totals[:changed]}"
puts "  new products:  #{totals[:new]}"
puts "  disappeared:   #{totals[:gone]}"
puts "  failed:        #{totals[:failed].any? ? totals[:failed].join(', ') : 'none'}"
puts ""
puts "Nothing here touches production. To publish these prices, aggregate first"
puts "(bin/rails runner script/aggregate_latest.rb) then sync to production."

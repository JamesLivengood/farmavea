# Prints a traffic report from the page_visits table.
#
# Deliberately a script rather than a web page: the data includes what people
# searched for, which is health-adjacent, so it shouldn't sit behind a URL that
# could be found or left unauthenticated.
#
# Run with:
#   bin/rails runner script/traffic_report.rb           # last 30 days
#   DAYS=7 bin/rails runner script/traffic_report.rb    # last week

days = (ENV["DAYS"] || 30).to_i
since = days.days.ago

summary = PageVisit.summary(since: since)

puts "=" * 66
puts "Traffic report - last #{days} days"
puts "=" * 66
puts ""

if summary[:views].zero?
  puts "No visits recorded yet."
  puts "(Tracking starts once the migration is deployed and people visit.)"
  exit
end

puts "  page views:        #{summary[:views]}"
puts "  distinct visitors: #{summary[:visitors]}"
puts "  views per visitor: #{(summary[:views].to_f / summary[:visitors]).round(1)}"
puts "  bot hits excluded: #{summary[:bots_excluded]}"
puts ""

puts "-- how often people come back " + "-" * 35
PageVisit.visit_frequency(since: since).each do |bucket, count|
  puts format("  %-14s %d visitors", bucket, count)
end
puts ""

puts "-- devices " + "-" * 54
summary[:by_device].sort_by { |_, v| -v }.each { |d, c| puts format("  %-10s %d", d || "unknown", c) }
puts ""

puts "-- page types " + "-" * 51
summary[:by_page_type].sort_by { |_, v| -v }.each { |t, c| puts format("  %-12s %d", t || "unknown", c) }
puts ""

if summary[:top_referrers].any?
  puts "-- what was filtered out " + "-" * 40
  puts format("  %-28s %d", "declared bots", summary[:bots_excluded])
  puts format("  %-28s %d views from %d sources", "bots posing as browsers",
              summary[:undeclared_bot_views], summary[:undeclared_bot_sources])
  puts "  (crawlers that send a Chrome user agent, plus single hits on / from"
  puts "   datacentres - uptime checks, scanners and link previewers)"
  puts ""

  puts "-- where people came from " + "-" * 39
  summary[:top_referrers].each { |host, c| puts format("  %-28s %d", host, c) }
  # Direct traffic is the bulk of it early on, and a referrer list that omits it
  # makes two Google clicks look like the whole story.
  puts format("  %-28s %d", "(direct / no referrer)", summary[:direct_views])
  puts ""

  # Deliberately NOT labelled as visitor location: this is the Fly datacentre that
  # served the request, which reflects network routing, not where anyone lives.
  if summary[:by_edge_region].any?
    puts "-- served by (fly datacentre, NOT visitor location) " + "-" * 13
    summary[:by_edge_region].each { |code, c| puts format("  %-28s %d", code, c) }
    puts ""
  end
end

searches = PageVisit.popular_searches(since: since, limit: 15)
if searches.any?
  puts "-- what people searched for " + "-" * 37
  puts "   (the most useful signal here - it says which medications to prioritise)"
  searches.each { |q, c| puts format("  %-34s %d", q.to_s.truncate(32), c) }
  puts ""
end

meds = PageVisit.popular_medications(since: since, limit: 15)
if meds.any?
  puts "-- most viewed medications " + "-" * 38
  names = Medication.where(id: meds.keys).index_by(&:id)
  meds.each do |id, count|
    med = names[id]
    puts format("  %-34s %d", med ? med.display_strength.truncate(32) : "(deleted ##{id})", count)
  end
  puts ""
end

puts "-- most visited pages " + "-" * 43
PageVisit.popular_pages(since: since, limit: 15).each do |row|
  puts format("  %-38s %5d views  %4d visitors", row.path.truncate(36), row.views, row.visitors)
end
puts ""
puts "=" * 66

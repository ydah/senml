# frozen_string_literal: true

require "csv"
require "yaml"
require_relative "prepare_fixtures"
rows = CSV.read(ReferenceFixtures.fetch("senml-units.csv"), headers: true)
units = rows.map { |row| row.fetch("Symbol") }
path = File.join(ReferenceFixtures::ROOT, "data/units.yml")
if ARGV.include?("--write")
  File.write(path, units.to_yaml)
else
  raise "Unit registry changed; audit and use --write" unless YAML.safe_load_file(path) == units
end
labels = YAML.safe_load_file(File.join(ReferenceFixtures::ROOT, "data/labels.yml"))
CSV.read(ReferenceFixtures.fetch("senml-labels.csv"), headers: true).each do |row|
  known = labels.fetch(row.fetch("Label"))
  raise "CBOR label mismatch" unless known["cbor"] == (row["CBOR Label"] && row["CBOR Label"].to_i)
end
puts "Verified #{units.length} units and #{labels.length} labels"

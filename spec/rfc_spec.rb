# frozen_string_literal: true

require "spec_helper"
RSpec.describe "temporary RFC 8428 fixtures" do
  root = File.expand_path("../tmp/rfc/fixtures", __dir__)
  manifest = JSON.parse(File.read(File.join(root, "manifest.json")))
  manifest.each do |entry|
    it "roundtrips #{entry.fetch("name")}" do
      data = File.read(File.join(root, "#{entry.fetch("name")}.json"))
      pack = SenML.parse(data)
      expect(JSON.parse(pack.to_json)).to eq(JSON.parse(data))
      expect(pack.resolve(now: Time.at(1_700_000_000)).length).to eq(pack.length)
    end
  end
  it "resolves section 5.1.3 exactly to the section 5.1.4 result" do
    input = SenML.parse(File.read(File.join(root, "5.1.3-1.json")))
    expected = JSON.parse(File.read(File.join(root, "5.1.4-1.json")))
    expect(input.resolve(now: Time.at(1_700_000_000)).to_h).to eq(expected)
  end
  it "retains and explicitly rejects the conflicting base-only original example" do
    source = File.read(File.join(root, "5.1.7-1.original.txt"))
    expect { SenML.parse(source) }.to raise_error(SenML::ValidationError, /exactly one/)
  end
  it "selects every section 9.1 fragment with its original base context" do
    records = Array.new(25) { |index| { "n" => index.to_s, "v" => index } }
    records[0].merge!("bn" => "sensor:", "bt" => 1_700_000_000)
    pack = SenML::Pack.new(records)
    expected = [[3], [3, 4, 5, 6], (19..25).to_a, [3, 5], [3, 4, 5, 10, *(19..25)]]
    JSON.parse(File.read(File.join(root, "9.1-fragments.json"))).zip(expected).each do |fragment, indexes|
      selected = pack.select_fragment(fragment)
      expect(selected.map(&:value)).to eq(indexes.map { |i| i - 1 })
      expect(selected.map(&:time)).to all(eq(1_700_000_000))
      expect(selected.map(&:name)).to eq(indexes.map { |i| "sensor:#{i - 1}" })
    end
  end
end

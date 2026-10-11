# frozen_string_literal: true

require "spec_helper"
RSpec.describe SenML do
  it "resolves bases, units, relative times, sums and stable sorting" do
    pack = SenML.parse('[{"bn":"meter:","bt":-1,"bu":"A","bv":10,"bs":50,"n":"x","v":2,"s":3},{"n":"y","t":-1,"v":0},{"n":"z","v":4}]')
    result = pack.resolve(now: Time.at(1_700_000_000)).to_a.map(&:to_h)
    expect(result.map { |r| r["n"] }).to eq(%w[meter:y meter:x meter:z])
    expect(result.map { |r| r["v"] }).to eq([10, 12, 14])
    expect(result.map { |r| r["s"] }).to eq([50, 53, 50])
    expect(result.first["t"]).to eq(1_699_999_998)
    expect(result.first["u"]).to eq("A")
  end
  it "keeps unknown extensions and every JSON value type" do
    data = [{ "n" => "a", "v" => 0, "custom" => { "x" => [nil, true, "µ"] } }]
    expect(SenML.parse(SenML::Pack.new(data).to_json).to_h).to eq(data)
  end
  it "rejects unknown critical labels and future or mixed versions even leniently" do
    ['[{"n":"a","v":1,"private_":3}]', '[{"n":"a","v":1,"bver":11}]', '[{"n":"a","v":1},{"n":"b","v":1,"bver":5}]'].each do |source|
      expect { SenML.parse(source, strict: false) }.to raise_error(SenML::ValidationError)
    end
  end
end

RSpec.describe "SenML public API and boundaries" do
  it "builds packs without introducing base-only records" do
    pack = SenML::Pack.build(base_name: "device:", base_time: 1_700_000_000, base_unit: "Cel") do |builder|
      builder.add(n: "temperature", v: 19.5).add(n: "door", vb: false, t: 2)
    end
    expect(pack[0].name).to eq("device:temperature")
    expect(pack[1].value).to eq(false)
    expect(pack[1].time_at).to eq(Time.at(1_700_000_002))
    expect(pack[0].base_time).to eq(1_700_000_000)
    expect(pack.resolve.to_h.map(&:keys).flatten).not_to include("bn", "bt", "bu")
    expect { SenML::Pack.build { |_builder| nil } }.to raise_error(SenML::ValidationError)
  end
  it "handles absent names/times, sum-only records and base defaults" do
    pack = SenML.parse('[{"bn":"sensor","bv":10,"v":0},{"s":4},{"bv":0,"bs":5,"s":1}]')
    expect(pack.map(&:value)).to eq([10, 10, 0])
    resolved = pack.resolve(now: 1_700_000_000)
    expect(resolved[1]["v"]).to eq(10)
    expect(resolved[2].sum).to eq(6)
    expect(SenML.parse('[{"n":"x","s":3}]').resolve(now: 1_700_000_000)[0].to_h).not_to have_key("v")
    record = SenML.parse('[{"n":"x","v":1}]')[0]
    expect { record.time_at }.to raise_error(SenML::ConversionError)
    expect(record.time_at(now: Time.at(1_700_000_000))).to eq(Time.at(1_700_000_000))
  end
  it "allows older versions and retains them on every resolved record" do
    pack = SenML.parse('[{"bn":"old:","bver":5,"n":"a","v":1},{"n":"b","v":2}]')
    expect(pack.resolve(now: 1_700_000_000).to_h.map { |r| r["bver"] }).to eq([5, 5])
    expect(SenML.parse('[{"n":"x","bver":10,"v":1}]').resolve(now: 1_700_000_000)[0].to_h).not_to have_key("bver")
  end
  it "resolves content-format extensions only on binary data values" do
    pack = SenML.parse('[{"bn":"x:","bct":"60","n":"a","vd":"AA"},{"n":"b","vd":"AQ","ct":"image/png"},{"n":"c","vs":"text"}]')
    records = pack.resolve(now: 1_700_000_000).to_h
    expect(records.map { |r| r["ct"] }).to eq(["60", "image/png", nil])
    expect(records).to all(satisfy { |r| !r.key?("bct") })
    expect(SenML.parse('[{"n":"x","vlo":"3:0"}]')[0].value).to eq("3:0")
  end
  it "decodes binary data lazily without accepting padding or noncanonical pad bits" do
    pack = SenML.parse('[{"n":"x","vd":"AP9h"}]')
    expect(pack[0].data).to eq("\0\xffa".b)
    expect(pack[0].value).to eq("\0\xffa".b)
    expect(pack[0].data_value).to eq("AP9h")
    expect(SenML.parse('[{"n":"x","vd":""}]')[0].data).to eq("".b)
    %w[A AA= AA+ AA/ AB AAB].each do |text|
      expect { SenML::Pack.new([{ "n" => "x", "vd" => text }]) }.to raise_error(SenML::ValidationError)
    end
    expect { SenML.parse('[{"n":"x","vd":"AAAA"}]', max_data_bytes: 1) }.to raise_error(SenML::LimitError)
    expect { SenML.parse('[{"n":"x","vd":"AB"}]', strict: false)[0].data }.to raise_error(SenML::ValidationError)
  end
  it "validates effective names and detects invalid measurement shapes" do
    [[], [{}], [{ "n" => "x" }], [{ "n" => "x", "v" => 1, "vb" => false }], [{ "n" => "_x", "v" => 1 }],
     [{ "n" => "bad name", "v" => 1 }], [{ "n" => "x", "v" => 1, "ut" => -1 }]].each do |data|
      expect { SenML::Pack.new(data) }.to raise_error(SenML::ValidationError)
    end
    expect(SenML.parse('[{"bn":"ok","n":"_suffix","v":1}]')[0].name).to eq("ok_suffix")
  end
  it "reports ordinary validation warnings but rejects invalid types and versions" do
    pack = SenML.parse('[{"n":"bad name","v":1,"u":"custom"}]', strict: false)
    expect(pack.warnings.map(&:pointer)).to eq(["/0/n", "/0/u"])
    expect { pack.to_json }.to raise_error(SenML::ValidationError)
    [{ "v" => "x" }, { "vb" => 1 }, { "vs" => false }, { "bver" => 0 }, { "bt" => nil }].each do |bad|
      expect { SenML::Pack.new([{ "n" => "x", "v" => 1 }.merge(bad)], strict: false) }.to raise_error(SenML::ParseError)
    end
    expect(SenML::Units.registered?("NTU")).to be(true)
    expect(SenML::Units.registered?("invalid")).to be(false)
  end
  it "rejects malformed JSON, duplicate keys and uppercase numeric exponents" do
    ["{}", "[3]", "[", '[{"n":"x","v":1,"v":2}]', '[{"n":"x","v":1E3}]'].each do |source|
      expect { SenML.parse(source) }.to raise_error(SenML::ParseError)
    end
    expect { SenML.parse("[\xff]".b) }.to raise_error(SenML::ParseError)
    expect(SenML.parse('[{"n":"x","vs":"1E3"}]')[0].value).to eq("1E3")
  end
  it "preserves IEEE binary64 extremes and randomized numbers" do
    random = Random.new(8428)
    numbers = [0.0, -0.0, Float::MAX, Float::MIN, 5e-324]
    300.times do
      value = [random.rand(2**64)].pack("Q>").unpack1("G")
      numbers << value if value.finite?
    end
    numbers.each do |value|
      serialized = SenML::Pack.new([{ "n" => "x", "v" => value }]).to_json
      actual = SenML.parse(serialized)[0]["v"]
      expect([actual].pack("G")).to eq([value].pack("G"))
    end
  end
  it "bounds input, recursion, record count and binary values" do
    json = '[{"n":"x","v":1}]'
    expect { SenML.parse(json, max_bytes: 2) }.to raise_error(SenML::LimitError)
    expect { SenML.parse(json, max_record_bytes: 2) }.to raise_error(SenML::LimitError)
    expect { SenML::Pack.new([{ "n" => "a", "v" => 1 }] * 2, max_records: 1) }.to raise_error(SenML::LimitError)
    expect { SenML::Pack.new([{ "n" => "x", "v" => 1, "e" => [[[[1]]]] }], max_depth: 2) }.to raise_error(SenML::LimitError)
    cyclic = {}
    cyclic["x"] = cyclic
    expect { SenML::Record.new(cyclic) }.to raise_error(SenML::LimitError)
    expect { SenML.parse(json, typo: 1) }.to raise_error(ArgumentError)
    expect { SenML.parse(json, max_depth: 1000) }.to raise_error(ArgumentError)
    expect { SenML.parse(json, max_bytes: -1) }.to raise_error(ArgumentError)
    expect { SenML::Pack.new([{ "n" => "x", "v" => Float::INFINITY }]) }.to raise_error(SenML::ParseError)
    expect { SenML::Pack.new([{ "n" => "x", "v" => 1 }], max_bytes: 1).to_json }.to raise_error(SenML::LimitError)
  end
  it "does not silently discard unsupported base extensions when resolving" do
    pack = SenML.parse('[{"n":"x","v":1,"bextra":2}]')
    expect { pack.resolve }.to raise_error(SenML::ConversionError)
    expect { SenML.parse('[{"n":"x","v":1}]').resolve(now: Float::INFINITY) }.to raise_error(ArgumentError)
    expect { SenML.parse('[{"n":"x","v":1}]').resolve(now: 0) }.to raise_error(SenML::ConversionError)
  end
  it "preserves context across fragment selections and rejects unbounded ranges" do
    pack = SenML.parse('[{"bn":"a:","bt":1700000000,"n":"x","v":1},{"n":"y","v":2},{"bn":"b:","n":"z","v":3}]')
    expect(pack.select_fragment("#rec=2,3").map(&:name)).to eq(%w[a:y b:z])
    expect(pack.select_fragment("rec=3,1,3").map(&:value)).to eq([1, 3])
    ["rec=0", "rec=1-999999999999", "rec=3-1", "rec=4", "rec=1,", "rec=x", "wrong=1"].each do |fragment|
      expect { pack.select_fragment(fragment) }.to raise_error(SenML::ValidationError)
    end
  end
  it "isolates mutable application data" do
    data = [{ "n" => "x", "v" => 1, "unknown" => [2] }]
    pack = SenML::Pack.new(data)
    data[0]["unknown"] << 3
    pack.to_h[0]["unknown"] << 4
    expect(pack[0]["unknown"]).to eq([2])
    expect(SenML::Pack.new(pack.to_a)[0].name).to eq("x")
  end
end

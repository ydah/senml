# frozen_string_literal: true

require "spec_helper"
require "senml/cbor"
RSpec.describe "CBOR" do
  let(:root) { File.expand_path("../tmp/rfc/fixtures", __dir__) }
  it "decodes and byte-for-byte reencodes the complete RFC section 6 dump" do
    bytes = File.binread(File.join(root, "6.cbor"))
    pack = SenML.parse_cbor(bytes)
    expect(pack.to_cbor).to eq(bytes)
    json = SenML.parse(File.read(File.join(root, "5.1.2-2.json")))
    expect(pack.resolve(now: 1_700_000_000).to_h).to eq(json.resolve(now: 1_700_000_000).to_h)
  end
  it "roundtrips every RFC JSON example through CBOR and retains extensions" do
    JSON.parse(File.read(File.join(root, "manifest.json"))).each do |entry|
      pack = SenML.parse(File.read(File.join(root, "#{entry.fetch("name")}.json")))
      expect(SenML.parse_cbor(pack.to_cbor).to_h).to eq(pack.to_h)
    end
    data = [{ "n" => "x", "vd" => "AP8", "custom" => { "data" => [nil, true, false, 2.25] }, "ct" => "60" }]
    pack = SenML::Pack.new(data)
    decoded = SenML::BinaryCBOR.decode(pack.to_cbor)
    expect(decoded[0][8]).to eq("\0\xff".b)
    expect(SenML.parse_cbor(pack.to_cbor).to_h).to eq(data)
  end
  it "accepts tagged decimal fractions and streaming arrays" do
    records = [{ 0 => "x", 2 => SenML::BinaryCBOR::Tagged.new(4, [-2, 125]) }]
    expect(SenML.parse_cbor(SenML::BinaryCBOR.encode(records))[0].value).to eq(1.25)
    bytes = "\x9f".b + SenML::BinaryCBOR.encode({ 0 => "x", 2 => 1 }) + "\xff".b
    expect { SenML.parse_cbor(bytes) }.to raise_error(SenML::ParseError, /definite/)
    expect(SenML.parse_cbor(bytes, streaming: true)[0].value).to eq(1)
    map = "\x81\xbf\x00\x61x\x02\x01\xff".b
    expect(SenML.parse_cbor(map)[0].name).to eq("x")
  end
  it "rejects duplicate, aliased and unknown integer labels before information is lost" do
    [%w[81 A3 00 61 78 02 01 02 02], %w[81 A3 00 61 78 02 01 18 02 02]].each do |octets|
      expect { SenML.parse_cbor([octets.join].pack("H*")) }.to raise_error(SenML::ParseError, /duplicate/)
    end
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1, "v" => 2 }])) }.to raise_error(SenML::ParseError, /duplicate/)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1, 99 => 2 }])) }.to raise_error(SenML::ParseError, /unknown integer/)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1, "private_" => 2 }]), strict: false) }.to raise_error(SenML::ValidationError)
  end
  it "requires byte strings for data and safely rejects values without JSON equivalents" do
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 8 => "text" }])) }.to raise_error(SenML::ParseError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1, "custom" => "binary".b }])) }.to raise_error(SenML::ConversionError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => SenML::BinaryCBOR::Tagged.new(7, "x") }])) }.to raise_error(SenML::ParseError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => SenML::BinaryCBOR::Tagged.new(4, [1]) }])) }.to raise_error(SenML::ParseError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => SenML::BinaryCBOR::Tagged.new(4, [1_000_000, 1]) }])) }.to raise_error(SenML::ParseError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => Float::NAN }])) }.to raise_error(SenML::ParseError)
  end
  it "enforces string kinds, bounds, complete framing and depth during bounded decoding" do
    pack = SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1 }])
    expect { SenML.parse_cbor(pack, max_bytes: 2) }.to raise_error(SenML::LimitError)
    expect { SenML.parse_cbor(pack, max_record_bytes: 2) }.to raise_error(SenML::LimitError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1 }, { 0 => "y", 2 => 2 }]), max_records: 1) }.to raise_error(SenML::LimitError)
    expect { SenML.parse_cbor(SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1, "x" => [[[]]] }]), max_depth: 2) }.to raise_error(SenML::LimitError)
    expect { SenML.parse_cbor("#{pack}\0") }.to raise_error(SenML::ParseError)
    %w[80FF 8101 8180 9BFFFFFFFFFFFFFFFF 81A200617802F8FF 81A2007F6178FF0201 81A2016178021F 81A2F461780201].each do |hex|
      expect { SenML.parse_cbor([hex].pack("H*")) }.to raise_error(SenML::Error)
    end
    expect { SenML::Pack.new([{ "n" => "x", "v" => 1 }], max_bytes: 1).to_cbor }.to raise_error(SenML::LimitError)
  end
  it "fuzzes truncations and random CBOR with documented exceptions" do
    random = Random.new(8428)
    valid = SenML::BinaryCBOR.encode([{ 0 => "x", 2 => 1.25 }])
    samples = valid.bytesize.times.map { |size| valid.byteslice(0, size) }
    1000.times { samples << random.bytes(random.rand(100)) }
    samples.each do |bytes|
      SenML.parse_cbor(bytes)
    rescue SenML::Error
      next
    end
  end
  it "roundtrips randomly generated packs through JSON and CBOR" do
    random = Random.new(8484)
    100.times do
      records = Array.new(5) { |i| { "n" => "sensor#{i}", "v" => random.rand * 100, "t" => 1_700_000_000 + i } }
      pack = SenML::Pack.new(records)
      expect(SenML.parse(SenML.parse_cbor(pack.to_cbor).to_json).to_h).to eq(records)
    end
  end
end

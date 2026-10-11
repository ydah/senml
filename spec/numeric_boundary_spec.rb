# frozen_string_literal: true

require "spec_helper"
require "senml/cbor"
RSpec.describe "measurement edge cases" do
  it "keeps sum-only values absent and applies numeric bases only to numeric values" do
    expect(SenML.parse('[{"n":"x","s":0}]')[0].value).to be_nil
    pack = SenML.parse('[{"n":"x","bv":10,"vs":"text"},{"n":"y","v":2}]')
    expect(pack.resolve(now: 1_700_000_000).to_h).to eq([{ "n" => "x", "vs" => "text", "t" => 1_700_000_000 },
                                                         { "n" => "y", "v" => 12, "t" => 1_700_000_000 }])
  end
  it "rejects invalid extension object keys and non-JSON application values" do
    expect { SenML::Pack.new([{ "n" => "x", "v" => 1, "e" => { "\xff".dup.force_encoding("UTF-8") => 1 } }]) }.to raise_error(SenML::ParseError)
    expect { SenML::Pack.new([{ "n" => "x", "v" => 1, "e" => Object.new }]) }.to raise_error(SenML::ParseError)
  end
  it "rejects numeric overflow after resolution instead of emitting infinity" do
    pack = SenML::Pack.new([{ "n" => "x", "v" => Float::MAX, "bv" => Float::MAX }])
    expect { pack.resolve(now: 1_700_000_000) }.to raise_error(SenML::ParseError)
  end
  it "resolves base numbers, units and timestamps to explicit expected measurements" do
    data = [{ "bn" => "meter:", "bt" => 1_700_000_010, "bu" => "Cel", "bv" => 14, "bs" => 11, "n" => "first", "v" => 2, "s" => 4 },
            { "n" => "second", "v" => 3, "t" => -2 }, { "bn" => "other:", "bv" => 0, "bs" => 0, "n" => "third", "vs" => "online", "t" => 1 }]
    expected = [{ "n" => "meter:second", "v" => 17, "s" => 11, "t" => 1_700_000_008, "u" => "Cel" },
                { "n" => "meter:first", "v" => 16, "s" => 15, "t" => 1_700_000_010, "u" => "Cel" },
                { "n" => "other:third", "vs" => "online", "s" => 0, "t" => 1_700_000_011, "u" => "Cel" }]
    pack = SenML::Pack.new(data)
    expect(pack.resolve(now: 1_700_000_000).to_h).to eq(expected)
    expect(SenML.parse_cbor(pack.to_cbor).resolve(now: 1_700_000_000).to_h).to eq(expected)
  end
  it "encodes exactly representable large integers and refuses lossy CBOR conversion" do
    require "senml/cbor"
    exact = SenML::Pack.new([{ "n" => "x", "v" => 2**80 }])
    expect(SenML.parse_cbor(exact.to_cbor)[0].value).to eq(2**80)
    expect { SenML::Pack.new([{ "n" => "x", "v" => (2**80) + 1 }]).to_cbor }.to raise_error(SenML::ConversionError)
  end
  it "reports application input type errors and validates all resource settings" do
    [nil, [], 12].each { |value| expect { SenML.parse(value) }.to raise_error(SenML::ParseError) }
    [0, -1, 1.5, nil].each { |value| expect { SenML.parse("[]", max_records: value) }.to raise_error(ArgumentError) }
    expect { SenML.parse("[]", max_depth: 129) }.to raise_error(ArgumentError)
    expect { SenML.parse("[]", unsupported: 1) }.to raise_error(ArgumentError)
    expect { SenML::Pack.new([{ "n" => "x", "v" => 1, "key".encode("UTF-16LE") => 1 }]) }.to raise_error(SenML::ParseError)
    expect { SenML.parse_cbor(nil) }.to raise_error(SenML::ParseError)
  end
  it "refuses to silently discard unknown base context during fragment selection" do
    pack = SenML::Pack.new([{ "n" => "x", "v" => 1, "bvendor" => 2 }, { "n" => "y", "v" => 3 }])
    expect { pack.select_fragment("rec=2") }.to raise_error(SenML::ConversionError, /unknown base/)
  end
end

RSpec.describe "inherited base safety" do
  it "escapes extension labels in critical-field diagnostic pointers" do
    expect { SenML.parse('[{"n":"x","v":1,"bad/~_":true}]') }.to raise_error(SenML::ValidationError) do |error|
      expect(error.pointer).to eq("/0/bad~1~0_")
    end
  end

  it "refuses to resolve a later record with an unknown inherited base" do
    pack = SenML.parse('[{"n":"a","v":1,"bvendor":2},{"n":"b","v":3}]')
    expect { pack[1].resolved(now: 1_700_000_000) }.to raise_error(SenML::ConversionError, /unknown base/)
    reader = SenML::StreamReader.new(StringIO.new('[{"n":"a","v":1,"bvendor":2},{"n":"b","v":3}]'))
    expect { reader.to_a[1].resolved(now: 1_700_000_000) }.to raise_error(SenML::ConversionError, /unknown base/)
  end

  it "shares immutable inherited strings instead of duplicating each large base" do
    prefix = "sensor:#{"a" * 100_000}"
    records = [{ "bn" => prefix, "bu" => "Cel", "n" => ":first", "v" => 1 }] + Array.new(99) { { "n" => ":next", "v" => 2 } }
    pack = SenML::Pack.new(records)
    contexts = pack.map { |record| record.instance_variable_get(:@base) }
    expect(contexts.map { |base| base.fetch("bn").object_id }.uniq.length).to eq(1)
    expect(contexts).to all(be_frozen)
    expect(contexts.map { |base| base.fetch("bn") }).to all(be_frozen)
    prefix.replace("changed:")
    expect(pack[-1].name).to end_with(":next")
    expect(pack[-1].name).to start_with("sensor:")
  end

  it "checks inherited name validity without weakening suffix or reset validation" do
    good = SenML.parse('[{"bn":"device:","n":"_x","v":1},{"n":"/y","v":2},{"bn":"","n":"z","v":3}]')
    expect(good.map(&:name)).to eq(%w[device:_x device:/y z])
    ['[{"bn":"bad name:","n":"x","v":1},{"n":"y","v":2}]',
     '[{"bn":"device:","n":"x","v":1},{"n":" bad","v":2}]',
     '[{"bn":"device:","n":"x","v":1},{"bn":"","n":"_bad","v":2}]'].each do |source|
      expect { SenML.parse(source) }.to raise_error(SenML::ValidationError)
    end
    warnings = SenML.parse('[{"bn":"bad name:","n":"x","v":1},{"n":"y","v":2}]', strict: false).warnings
    expect(warnings.map(&:pointer)).to eq(["/0/n", "/1/n"])
  end

  it "stops resolution before base expansion exceeds the output byte budget" do
    source = [{ "bn" => "device:#{"a" * 10_000}", "n" => "x", "v" => 1 }] + Array.new(9) { { "n" => "x", "v" => 2 } }
    pack = SenML::Pack.new(source, max_bytes: 30_000)
    expect { pack.resolve(now: 1_700_000_000) }.to raise_error(SenML::LimitError, /max_bytes/)
  end
  it "bounds complete native packs and decoded CBOR representations" do
    records = Array.new(5) { { "n" => "sensor", "v" => 1 } }
    expect { SenML::Pack.new(records, max_bytes: 60) }.to raise_error(SenML::LimitError, /max_bytes/)

    bytes = SenML::BinaryCBOR.encode(Array.new(5) { { 0 => "s", 2 => 1 } })
    expect(bytes.bytesize).to be < 60
    expect { SenML.parse_cbor(bytes, max_bytes: 60) }.to raise_error(SenML::LimitError, /max_bytes/)
  end

  it "carries bases only when necessary in a selected fragment" do
    records = [{ "bn" => "a:#{"x" * 10_000}", "n" => "first", "v" => 1 }]
    records.concat(Array.new(8) { |index| { "n" => "n#{index}", "v" => index } })
    records << { "bn" => "b:", "n" => "last", "v" => 9 }
    pack = SenML::Pack.new(records, max_bytes: 20_000)
    selected = pack.select_fragment("rec=2-*")
    expect(selected.to_h.count { |record| record.key?("bn") }).to eq(2)
    expect(selected.map(&:name)).to eq(pack.to_a.drop(1).map(&:name))
    expect(selected.to_json.bytesize).to be < 20_000
  end
end

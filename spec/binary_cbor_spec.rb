# frozen_string_literal: true

require "spec_helper"
require "senml/cbor"

RSpec.describe "Ruby CBOR wire codec" do
  let(:codec) { SenML::BinaryCBOR }

  def wire(hex)
    [hex.delete(" ")].pack("H*")
  end

  it "uses only the project's Ruby codec" do
    expect(SenML.const_defined?(:BinaryCBOR, false)).to be(true)
    expect($LOADED_FEATURES.grep(%r{/gems/cbor-[^/]+/})).to be_empty
  end

  { 19 => "13", 26 => "181a", 251 => "18fb", 333 => "19014d", 65_534 => "19fffe", 65_543 => "1a00010007",
    4_294_967_296 => "1b0000000100000000", (2**64) - 1 => "1bffffffffffffffff",
    -20 => "33", -334 => "39014d", -(2**64) => "3bffffffffffffffff" }.each do |number, hex|
    it "preserves integer #{number} with the required argument width" do
      expect(codec.encode(number)).to eq(wire(hex))
      expect(codec.decode(wire(hex))).to eq(number)
    end
  end

  it "encodes arbitrary integers as bignums without passing through Float" do
    [2**81 + 7, -(2**81) - 8].each do |number|
      decoded = codec.decode(codec.encode(number))
      expect(decoded.tag).to eq(number.positive? ? 2 : 3)
      expect(decoded.value.encoding).to eq(Encoding::BINARY)
      magnitude = decoded.value.unpack1("H*").to_i(16)
      expect(number.positive? ? magnitude : -1 - magnitude).to eq(number)
    end
  end

  it "distinguishes UTF-8 text and uninterpreted byte strings" do
    expect(codec.encode("水")).to eq(wire("63e6b0b4"))
    expect(codec.encode("水".b)).to eq(wire("43e6b0b4"))
    expect(codec.decode(wire("63e6b0b4"))).to eq("水")
    expect(codec.decode(wire("43e6b0b4")).encoding).to eq(Encoding::BINARY)
    expect { codec.decode(wire("62c0af")) }.to raise_error(codec::Error, /UTF-8/)
    expect { codec.encode("\xff".dup.force_encoding("UTF-8")) }.to raise_error(codec::Error, /UTF-8/)
  end

  it "handles all definite length widths without premature allocations" do
    [0, 23, 24, 255, 256, 65_536].each do |size|
      text = "t" * size
      expect(codec.decode(codec.encode(text))).to eq(text)
    end
    expect { codec.decode(wire("7bffffffffffffffff")) }.to raise_error(codec::Error)
    expect { codec.decode(wire("9bffffffffffffffff")) }.to raise_error(codec::LimitError)
  end

  it "decodes indefinite containers and strings while validating each chunk" do
    expect(codec.decode(wire("9f04bf616b07616d9ff5f6ffffff"))).to eq([4, { "k" => 7, "m" => [true, nil] }])
    expect(codec.decode(wire("7f61616162ff"))).to eq("ab")
    expect(codec.decode(wire("5f41ff4100ff"))).to eq("\xff\0".b)
    %w[7f61c362a971ff 7f5fff 5f7fff 7f7fffff bf616bff].each do |hex|
      expect { codec.decode(wire(hex)) }.to raise_error(codec::Error)
    end
    expect { codec.decode(wire("7fff"), allow_indefinite_strings: false) }.to raise_error(codec::Error)
  end

  it "preserves tag numbers and text without coercion" do
    tagged = codec::Tagged.new(32, "HTTP://Example.test/%2f")
    expect(codec.decode(codec.encode(tagged))).to eq(tagged)
    expect { codec.decode(codec.encode(tagged), allowed_tags: [0]) }.to raise_error(codec::UnsupportedError)
  end

  it "rejects duplicate keys even when their wire encodings differ" do
    %w[a20a01180a02 a26161017f6161ff02].each do |hex|
      expect { codec.decode(wire(hex)) }.to raise_error(codec::Error, /duplicate/)
    end
    %w[a1416101 a1f501 a18001].each do |hex|
      expect { codec.decode(wire(hex)) }.to raise_error(codec::UnsupportedError, /keys/)
    end
  end

  it "supports booleans, null and explicit unsupported simple values" do
    expect(codec.decode(codec.encode([true, false, nil]))).to eq([true, false, nil])
    [7, 23, 42, 255].each do |value|
      expect(codec.decode(codec.encode(codec::Simple.new(value)))).to eq(codec::Simple.new(value))
    end
    expect { codec.decode(wire("f817")) }.to raise_error(codec::Error)
    expect { codec.encode(codec::Simple.new(30)) }.to raise_error(codec::Error)
  end

  it "decodes binary16 including subnormals and signed zero" do
    expect(codec.decode(wire("f93c80"))).to eq(1.125)
    expect(codec.decode(wire("f90001"))).to eq(2.0**-24)
    expect(codec.decode(wire("f9bc80"))).to eq(-1.125)
    expect(1.0 / codec.decode(wire("f98000"))).to eq(-Float::INFINITY)
    expect(codec.decode(wire("f97c00"))).to eq(Float::INFINITY)
    expect(codec.decode(wire("f97c01"))).to be_nan
  end

  it "uses the shortest exact float representation, with an explicit binary32 override" do
    expect(codec.encode(1.125)).to eq(wire("f93c80"))
    expect(codec.encode(1.0000001192092896)).to eq(wire("fa3f800001"))
    expect(codec.encode(codec::Float32.new(1.125))).to eq(wire("fa3f900000"))
    [0.1, -0.0, 1.0e-300, Float::MAX, Float::INFINITY].each do |value|
      expect(codec.decode(codec.encode(value))).to eq(value)
    end
    expect(1.0 / codec.decode(codec.encode(-0.0))).to eq(-Float::INFINITY)
    expect(codec.decode(codec.encode(Float::NAN))).to be_nan
  end

  it "rejects reserved heads, truncated items, invalid breaks and trailing data" do
    %w[1c 1d 1e 1f 5c 7e 9c bc df fc fd fe ff 1b0000 63e6b0 8101ff 8201ff bf00ff].each do |hex|
      expect { codec.decode(wire(hex)) }.to raise_error(codec::Error)
    end
    encoded = codec.encode({ "report" => [1.125, "水", false] })
    encoded.bytesize.times { |length| expect { codec.decode(encoded.byteslice(0, length)) }.to raise_error(codec::Error) }
  end

  it "roundtrips all finite binary16 encodings, including the sign of zero" do
    65_536.times do |bits|
      next if ((bits >> 10) & 31) == 31

      original = codec.decode("\xf9".b + [bits].pack("n"))
      encoded = codec.encode(original)
      expect(encoded).to eq("\xf9".b + [bits].pack("n"))
    end
  end

  it "preserves generated binary64 values and large integer magnitudes" do
    random = Random.new(41_893)
    1000.times do
      value = random.bytes(8).unpack1("G")
      next unless value.finite?

      expect(codec.decode(codec.encode(value))).to eq(value)
      number = random.rand(-(2**63)...2**64)
      expect(codec.decode(codec.encode(number))).to eq(number)
    end
  end

  it "enforces byte, node, nesting and container bounds before retaining input" do
    expect { codec.decode(wire("820102"), max_input_size: 2) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("820102"), max_nodes: 2) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("818100"), max_depth: 1) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("9f0001ff"), max_collection_size: 1) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("5f41014102ff"), max_binary_size: 1) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("626162"), max_string_size: 1) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("820102"), max_records: 1) }.to raise_error(codec::LimitError)
    expect { codec.decode(wire("81626162"), max_record_bytes: 2) }.to raise_error(codec::LimitError)
    expect { codec.encode("abcdef", max_output_size: 4) }.to raise_error(codec::LimitError)
    cycle = []
    cycle << cycle
    expect { codec.encode(cycle, max_depth: 4) }.to raise_error(codec::LimitError)
    expect { codec.encode(Object.new) }.to raise_error(codec::Error)
  end
end

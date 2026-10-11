# frozen_string_literal: true

require "spec_helper"
RSpec.describe SenML::StreamReader do
  it "yields records before the complete array is available and retains base context" do
    source = '[{"bn":"device:","bt":1700000000,"n":"a","v":1},{"n":"b","v":2}]'
    reader = described_class.new(StringIO.new(source))
    expect(reader.map(&:name)).to eq(%w[device:a device:b])
    expect(reader.warnings).to be_empty
  end
  it "handles byte boundaries, escaped delimiters and multibyte UTF-8" do
    io = Object.new
    chunks = JSON.generate([{ "n" => "a", "vs" => 'café \" [ ] { }', "x" => { "nested" => [1, 2] } }]).b.bytes.map(&:chr)
    io.define_singleton_method(:read) { |_size| chunks.shift }
    expect(described_class.new(io).first.value).to include("café", "[ ]")
  end
  it "enforces shape, completion, record count and byte limits" do
    ["[]", "{}", "[{}", "[1]", '[{"n":"a","v":1},]', '[{"n":"a","v":1}]x'].each do |source|
      expect { described_class.new(StringIO.new(source)).to_a }.to raise_error(SenML::Error)
    end
    expect { described_class.new(StringIO.new('[{"n":"a","v":1}]'), max_record_bytes: 5).to_a }.to raise_error(SenML::LimitError)
    expect { described_class.new(StringIO.new('[{"n":"a","v":1},{"n":"b","v":2}]'), max_records: 1).to_a }.to raise_error(SenML::LimitError)
    expect { described_class.new(StringIO.new('[{"n":"a","v":1,"x":[[[]]]}]'), max_depth: 2).to_a }.to raise_error(SenML::LimitError)
    expect(described_class.new(StringIO.new('[{"n":"a","v":1},'), allow_incomplete: true).count).to eq(1)
  end
  it "validates version continuity and exposes lenient warnings" do
    expect { described_class.new(StringIO.new('[{"n":"a","v":1},{"n":"b","v":2,"bver":5}]')).to_a }.to raise_error(SenML::ValidationError)
    reader = described_class.new(StringIO.new('[{"n":"bad name","v":1}]'), strict: false)
    expect(reader.count).to eq(1)
    expect(reader.warnings.length).to eq(1)
  end
  it "processes 100000 records without retaining the full stream" do
    index = 0
    io = Object.new
    io.define_singleton_method(:read) do |_size|
      index += 1
      case index
      when 1 then '[{"bn":"many:","n":"x","v":1}'
      when 2..100_000 then ',{"n":"x","v":1}'
      when 100_001 then "]"
      end
    end
    expect(described_class.new(io).count).to eq(100_000)
  end
end

RSpec.describe "bounded lenient diagnostics" do
  it "limits retained warnings and stops before yielding an incompletely validated record" do
    source = JSON.generate(Array.new(10) { { "n" => "bad name", "v" => 1, "u" => "custom" } })
    reader = SenML::StreamReader.new(StringIO.new(source), strict: false, max_warnings: 3)
    yielded = []
    expect { reader.each { |record| yielded << record } }.to raise_error(SenML::LimitError, /max_warnings/)
    expect(yielded.length).to eq(1)
    expect(reader.warnings.length).to eq(3)
    expect(reader.warnings.map(&:pointer)).to eq(["/0/n", "/0/u", "/1/n"])
    expect { SenML.parse(source, strict: false, max_warnings: 3) }.to raise_error(SenML::LimitError, /max_warnings/)
  end

  it "resets warnings when the stream is rewound and enumerated again" do
    source = StringIO.new('[{"n":"bad name","v":1}]')
    reader = SenML::StreamReader.new(source, strict: false, max_warnings: 1)
    expect(reader.count).to eq(1)
    source.rewind
    expect(reader.count).to eq(1)
    expect(reader.warnings.length).to eq(1)
  end
end

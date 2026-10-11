<h1 align="center">SenML</h1>

<p align="center">Sensor measurements with base resolution, streams, and CBOR.</p>

<p align="center">
  <a href="https://rubygems.org/gems/senml"><img src="https://img.shields.io/gem/v/senml" alt="Gem version"></a>
  <a href="https://github.com/ydah/senml/actions/workflows/main.yml"><img src="https://github.com/ydah/senml/actions/workflows/main.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/Ruby-%3E%3D%203.3-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby 3.3 or later"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center">
  <a href="https://ydah.github.io/senml/">Website</a> &middot;
  <a href="#installation">Installation</a> &middot;
  <a href="#quick-start">Quick start</a> &middot;
  <a href="#scope-and-reference-data">Scope and reference data</a> &middot;
  <a href="#development">Development</a> &middot;
  <a href="#license">License</a>
</p>

Read, validate, write, and resolve [RFC 8428](https://www.rfc-editor.org/rfc/rfc8428) sensor measurements in Ruby. Supports SenML JSON, incremental SenSML JSON, record fragments, and CBOR.

## Features

- Read and write SenML JSON and CBOR without a separate CBOR gem.
- Resolve base fields and relative times into ordered measurements.
- Read incremental SenSML JSON streams and select record fragments.

## Installation

Add the gem to your Gemfile:

```ruby
gem "senml"
```

Then run `bundle install`.

Requires Ruby 3.3 or later and JSON 2.19.4 or later, below version 4. JSON and the built-in Ruby CBOR codec work on CRuby, JRuby, and TruffleRuby, including CRuby development builds. There are no dependencies on other measurement or JSON-format gems.

## Quick start

```ruby
require "senml"

pack = SenML::Pack.build(base_name: "room:", base_time: 1_700_000_000, base_unit: "Cel") do |p|
  p.add(n: "temperature", v: 21.5, t: 2)
  p.add(n: "temperature", v: 21.8, t: 1)
end

parsed = SenML.parse(pack.to_json)
parsed.first.name                         # => "room:temperature"
parsed.first.time                         # => 1700000002
parsed.first["t"]                         # => 2 (the original field)
resolved = parsed.resolve(now: Time.at(1_700_000_000))
resolved.map(&:value)                     # => [21.8, 21.5]
resolved.first.time_at                    # => a UTC Time
```

`name`, `unit`, `time`, `value`, and `sum` apply the current base fields. `[]` and `to_h` preserve original fields, including unknown noncritical extensions. `Record#data` lazily decodes unpadded base64url `vd` into a binary String. String and boolean measurements do not receive numeric base values. A record may have a value, a sum, or both; an inherited base value or base sum can supply a missing measurement field.

Resolution removes base fields, expands names, units, values and sums, converts relative times using `now`, and stably sorts by time. Version 10 is implicit; legacy positive versions up to 10 are retained when resolving. Future versions and mixed versions are rejected. A relative `Record#time_at` needs an explicit `now:`. Integers retain Ruby precision; nonintegral numbers use binary64 Float, and generated JSON preserves finite Float values across parsing.

## Streams and fragments

```ruby
File.open("measurements.json", "rb") do |io|
  SenML::StreamReader.new(io).each { |record| puts record.name }
end

selected = pack.select_fragment("#rec=1,2-*")
```

The stream reader yields each complete object without retaining the whole array. It carries immutable base fields and version state between records. Repeated records reuse inherited base strings; name-prefix validation is cached until the base changes. `allow_incomplete: true` also accepts a SenSML stream that ends after a complete record without a closing array bracket; an unfinished object still fails. This reader handles JSON streams; CBOR parsing consumes a complete input String.

Fragments use one-based record indices and support single records, closed ranges, open ranges, and comma-separated combinations. Selection keeps original order, removes duplicates, and carries each selected record's effective base context, emitting inherited base fields only at the first selected record and when they change. Out-of-range and reversed ranges fail.

## Validation and limits

Strict parsing checks field types, value counts, resolved names, registered units, versions, and canonical unpadded base64url. Duplicate JSON keys and uppercase numeric exponents fail. `strict: false` preserves recoverable semantic problems as `pack.warnings`; field types, unknown critical labels ending in `_`, and version problems always fail. Writing and resolving perform strict validation again.

All APIs that construct packs or readers accept these positive integer limits:

| Option | Default | Applies to |
| --- | ---: | --- |
| `max_bytes` | 16,777,216 | Complete inputs/outputs and the JSON representation of native or decoded packs |
| `max_records` | 100,000 | Packs and streams |
| `max_record_bytes` | 1,048,576 | Each record, including stream buffers |
| `max_data_bytes` | 786,432 | Decoded binary measurement size |
| `max_depth` | 32 | Nested values; hard maximum 128 |
| `max_warnings` | 1,000 | Retained lenient diagnostics in packs and streams |

Native array construction and CBOR decoding also check the cumulative JSON representation size against `max_bytes`; the decoded representation may be larger than its CBOR input. Streams use record limits instead of a total byte limit. Exceeding `max_warnings` raises `LimitError` before yielding the next record; `reader.warnings` retains the diagnostics collected so far. Resolution checks `max_bytes` incrementally as base fields expand, before retaining an oversized resolved pack. Binary size is checked before decoding. `SenML::ParseError` reports malformed input or field types, `ValidationError` reports semantic problems with a `pointer`, `UnsupportedVersionError` identifies unknown versions, and `LimitError` reports exceeded bounds. A conversion that cannot preserve supported semantics raises `ConversionError`.

## CBOR

```ruby
require "senml/cbor"
bytes = pack.to_cbor
SenML.parse_cbor(bytes)
# Accept a complete SenSML indefinite-length CBOR array:
SenML.parse_cbor(stream_bytes, streaming: true)
```

CBOR maps the RFC's integer labels and binary data values, preserves JSON-compatible extension fields, and supports decimal-fraction tag 4 with exponents from -400 to 400. The decoder checks lengths, nesting, UTF-8, duplicate map keys, and allowed types while reading. No separate CBOR gem is required. Unknown integer labels, non-JSON binary extension values, other tags, indefinite strings, and lossy conversion of large integers fail explicitly. JSON nonintegral values use Float; conversion of arbitrary decimal fractions can round to binary64.

## Scope and reference data

| Supported | Outside this release |
| --- | --- |
| SenML and incremental SenSML JSON | XML and EXI |
| Base resolution and record fragments | Unit conversion and CoAP transport |
| CBOR on the runtimes listed above | Incremental CBOR decoding |
| RFC 8428 version rules and registered labels | FETCH/PATCH and RFC 9100 feature versions |

The implementation supports RFC 8428 sections 4–6 and 9: SenML/SenSML JSON, base resolution, CBOR, and record fragments. It recognizes the IANA unit identifiers and registered labels checked on 2026-10-11, including `vlo` and the `ct`/`bct` labels from [RFC 9193](https://www.rfc-editor.org/rfc/rfc9193). Content-format strings are preserved opaquely, and `bct` resolves onto binary measurements. Unknown base labels stop resolution and fragment selection because their inheritance rules are unknown, including when resolving a later record that inherits the unsupported base.

XML, EXI, unit conversion, CoAP transport, FETCH/PATCH variants, and feature-version negotiation from RFC 9100 are outside this release. The library makes no network requests when parsing or resolving measurements.

The identifier/type metadata in `data/` records the supported protocol fields. RFC text, examples, grammars, IANA source files, and external implementation code are never committed or packaged. Development scripts fetch checksum-pinned references into ignored `tmp/` directories, retain notices, and extract test fixtures there. See [IANA terms](https://www.iana.org/help/licensing-terms), [IETF terms](https://trustee.ietf.org/license-info), and `script/sources.json` for sources and checksums.

The RFC's explicitly unfinished section 5.1.2 stream is closed after its final complete measurement for whole-pack tests. The first section 5.1.7 thermostat example starts with a base-only record, conflicting with section 4.2's value-or-sum requirement; strict parsing rejects the original, and its base name is moved into the first measurement for the roundtrip fixture. Original excerpts and corrections remain together in ignored fixture storage. [Erratum 6728](https://www.rfc-editor.org/errata/eid6728), held for document update, concerns an XML/CDDL comma and does not change the supported encodings.

## Development

```sh
bundle install
bundle exec rake test
COVERAGE=1 bundle exec rake test
bundle exec rbs -I sig validate
bundle exec ruby script/benchmark.rb
```

Tests cover all 14 RFC JSON examples, the full CBOR hex example, all five fragment examples, MUST violations, malformed and random CBOR, random numeric roundtrips, and a generated 100,000-record stream. Normalization tests use original examples with explicit expected measurements; CBOR tests run on every supported Ruby engine without external codec or language tools. The IANA checker fails on unexpected registry changes; review updated sources and checksums before running `bundle exec ruby script/update_registry.rb --write`.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/ydah/senml/issues). See [Development](#development) for the checks to run before submitting a change. Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## License

Project code is MIT licensed; see [LICENSE.txt](LICENSE.txt). Added library dependencies are limited to MIT-licensed libraries. Ruby implementations and standard/default libraries (including JSON) are exceptions and retain their own licenses. Downloaded standards material is test reference data under its source terms and is neither committed nor packaged. These statements do not relicense third-party material.

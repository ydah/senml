# frozen_string_literal: true

require_relative "../senml"
require_relative "binary_cbor"
module SenML
  module CBORCodec
    KEYS = LABELS.to_h { |label, spec| [spec.fetch("cbor", label), label] }.freeze
    def self.decode(bytes, limits, streaming)
      raise ParseError, "CBOR pack must be an array" unless bytes.getbyte(0)&.div(32) == 4
      raise ParseError, "SenML CBOR requires a definite-length array" if bytes.getbyte(0) == 159 && !streaming

      raw = BinaryCBOR.decode(bytes, max_input_size: limits[:max_bytes], max_depth: limits[:max_depth], max_nodes: limits[:max_bytes],
                             max_collection_size: limits[:max_bytes], max_string_size: limits[:max_record_bytes],
                             max_binary_size: limits[:max_record_bytes], max_records: limits[:max_records],
                             max_record_bytes: limits[:max_record_bytes], allowed_tags: [4], allow_indefinite_strings: false)
      raw.map do |record|
        raise ParseError, "CBOR record must be a map" unless record.is_a?(Hash)

        mapped = record.to_h do |key, value|
          label = KEYS[key]
          raise ParseError, "unknown integer CBOR label" if key.is_a?(Integer) && !label

          label ||= key
          raise ParseError, "CBOR labels must be text or defined integers" unless label.is_a?(String)

          if label == "vd"
            raise ParseError, "CBOR data value must be a byte string" unless value.is_a?(String) && value.encoding == Encoding::BINARY

            value = [value].pack("m0").tr("+/", "-_").delete("=")
          else
            value = json_value(value)
          end
          [label, value]
        end
        raise ParseError, "duplicate translated CBOR label" unless mapped.size == record.size

        mapped
      end
    rescue BinaryCBOR::LimitError => e
      raise LimitError, e.message
    rescue BinaryCBOR::Error => e
      raise ParseError, e.message
    end

    def self.json_value(value)
      case value
      when BinaryCBOR::Tagged
        raise ParseError, "invalid decimal fraction" unless value.tag == 4 && value.value.is_a?(Array) && value.value.length == 2 && value.value.all?(Integer)

        exponent, mantissa = value.value
        raise ParseError, "decimal fraction exponent outside supported range" unless exponent.between?(-400, 400)

        (mantissa * (10.to_r**exponent)).to_f
      when BinaryCBOR::Simple then raise ParseError, "unsupported CBOR simple value"
      when Hash then value.transform_values { |v| json_value(v) }
      when Array then value.map { |v| json_value(v) }
      when String
        raise ConversionError, "unknown binary extension cannot be represented as JSON" if value.encoding == Encoding::BINARY

        value
      else value
      end
    end

    def self.encode(records, limits)
      values = records.map do |record|
        record.to_h do |label, value|
          value = label == "vd" ? Record.new(record, **limits).data : cbor_value(value)
          [LABELS.fetch(label, {}).fetch("cbor", label), value]
        end
      end
      BinaryCBOR.encode(values, max_output_size: limits[:max_bytes])
    rescue BinaryCBOR::LimitError => e
      raise LimitError, e.message
    rescue BinaryCBOR::Error, RangeError => e
      raise ConversionError, e.message
    end

    def self.cbor_value(value)
      case value
      when Hash then value.transform_values { |v| cbor_value(v) }
      when Array then value.map { |v| cbor_value(v) }
      when Integer
        return value if value.between?(-(2**64), (2**64) - 1)

        number = value.to_f
        raise ConversionError, "integer cannot be represented exactly in supported CBOR numbers" unless number.finite? && number.to_i == value

        number
      else value
      end
    end
  end

  # Parse a complete binary CBOR pack; load this API with require 'senml/cbor'.
  # @param bytes [String] CBOR octets
  # @param streaming [Boolean] permit a SenSML indefinite-length array
  # @return [Pack]
  def self.parse_cbor(bytes, strict: true, streaming: false, **options)
    options = limits(options)
    raise ParseError, "CBOR input must be a String" unless bytes.is_a?(String)
    raise LimitError, "CBOR pack exceeds max_bytes" if bytes.bytesize > options[:max_bytes]

    Pack.new(CBORCodec.decode(bytes, options, streaming), strict: strict, **options)
  end

  class Pack
    def to_cbor
      self.class.new(to_h, **@limits)
      result = CBORCodec.encode(to_h, @limits)
      raise LimitError, "CBOR output exceeds max_bytes" if result.bytesize > @limits[:max_bytes]

      result
    end
  end
end

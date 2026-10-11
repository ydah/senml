# frozen_string_literal: true

require "json"
require "yaml"
require "time"
require_relative "senml/version"

module SenML
  VERSION = Senml::VERSION
  FORMAT_VERSION = 10
  ABSOLUTE_TIME = 2**28
  LIMITS = { max_bytes: 16_777_216, max_records: 100_000, max_record_bytes: 1_048_576, max_data_bytes: 786_432, max_depth: 32, max_warnings: 1_000 }.freeze
  class Error < StandardError; end
  class ParseError < Error; end
  class ConversionError < Error; end
  class LimitError < ParseError; end

  class ValidationError < Error
    attr_reader :pointer

    def initialize(message, pointer: "")
      @pointer = pointer
      super("#{pointer.empty? ? "/" : pointer}: #{message}")
    end
  end

  class UnsupportedVersionError < ValidationError; end

  def self.limits(options)
    raise ArgumentError, "unknown limit option" unless (options.keys - LIMITS.keys).empty?

    values = LIMITS.merge(options)
    raise ArgumentError, "limits must be positive integers" unless values.values.all? { |v| v.is_a?(Integer) && v.positive? }
    raise ArgumentError, "max_depth must be at most 128" if values[:max_depth] > 128

    values
  end

  def self.copy(value, depth = 0)
    raise LimitError, "data exceeds safe copy depth" if depth > 128

    case value
    when Hash then value.to_h { |k, v| [k.dup, copy(v, depth + 1)] }
    when Array then value.map { |v| copy(v, depth + 1) }
    when String then value.dup
    else value
    end
  end

  # Parse a complete SenML JSON pack without executing or fetching its contents.
  # @param source [String] UTF-8 JSON array
  # @param strict [Boolean] raise on recoverable semantic violations
  # @return [Pack]
  # @raise [ParseError, ValidationError, LimitError]
  def self.parse(source, strict: true, **options)
    options = limits(options)
    raise ParseError, "JSON input must be a String" unless source.is_a?(String)
    raise LimitError, "pack exceeds max_bytes" if source.bytesize > options[:max_bytes]

    records = JSONCodec.parse(source, max_depth: options[:max_depth])
    Pack.new(records, strict: strict, **options)
  end
end
require_relative "senml/labels"
require_relative "senml/json_codec"
require_relative "senml/validator"
require_relative "senml/record"
require_relative "senml/pack"
require_relative "senml/stream_reader"

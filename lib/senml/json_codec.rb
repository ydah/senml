# frozen_string_literal: true

module SenML
  module JSONCodec
    class Number
      def initialize(source)
        raise ParseError, "numeric exponent must use lowercase e" if source.include?("E")

        @value = Float(source)
      end
      attr_reader :value
    end

    def self.parse(source, max_depth:)
      source = source.dup.force_encoding(Encoding::UTF_8)
      raise ParseError, "JSON must be valid UTF-8" unless source.valid_encoding?

      convert(JSON.parse(source, allow_duplicate_key: false, decimal_class: Number, max_nesting: max_depth))
    rescue JSON::ParserError, EncodingError => e
      raise ParseError, e.message
    end

    def self.convert(value)
      case value
      when Hash then value.transform_values { |v| convert(v) }
      when Array then value.map { |v| convert(v) }
      when Number then value.value
      else value
      end
    end

    def self.generate(value)
      case value
      when Hash then "{#{value.map { |k, v| "#{JSON.generate(k)}:#{generate(v)}" }.join(",")}}"
      when Array then "[#{value.map { |v| generate(v) }.join(",")}]"
      when Float
        raise ValidationError, "nonfinite number" unless value.finite?

        number = format("%.17g", value)
        number += ".0" unless number.match?(/[.e]/)
        number
      else JSON.generate(value)
      end
    rescue JSON::GeneratorError, EncodingError => e
      raise ValidationError, e.message
    end
  end
end

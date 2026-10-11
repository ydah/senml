# frozen_string_literal: true

module SenML
  class Validator
    attr_reader :base, :warnings, :version, :record_bytes

    def initialize(strict:, limits:)
      @strict = strict
      @limits = limits
      @base = {}
      @warnings = []
      @version = nil
    end

    def accept(record, index)
      pointer = "/#{index}"
      raise ParseError, "#{pointer}: record must be an object" unless record.is_a?(Hash)

      json_value(record, pointer, 0)
      @record_bytes = JSONCodec.generate(record).bytesize
      raise LimitError, "record exceeds max_record_bytes" if @record_bytes > @limits[:max_record_bytes]

      record.each do |label, value|
        raise ParseError, "record labels must be strings" unless label.is_a?(String)

        if label.end_with?("_") && !LABELS.key?(label)
          escaped = label.gsub("~", "~0").gsub("/", "~1")
          raise ValidationError.new("unknown critical field", pointer: "#{pointer}/#{escaped}")
        end

        spec = LABELS[label]
        next unless spec

        valid = case spec["type"]
                when "string" then value.is_a?(String)
                when "number" then (value.is_a?(Integer) || value.is_a?(Float)) && value.finite?
                when "integer" then value.is_a?(Integer) && value.positive?
                when "boolean" then [true, false].include?(value)
                end
        raise ParseError, "#{pointer}/#{label}: invalid #{spec["type"]} value" unless valid
      end
      BASE_LABELS.each do |key|
        next unless record.key?(key)

        value = record[key]
        @base[key] = value.is_a?(String) ? value.dup.freeze : value
      end
      # Only the first unknown base name is needed to prevent unsafe resolution;
      # do not retain arbitrary unknown base payloads across the whole stream.
      @unknown_base ||= record.keys.find { |key| key.start_with?("b") && !BASE_LABELS.include?(key) }
      @base[@unknown_base] = nil if @unknown_base
      @base_name_valid = @base.fetch("bn", "").match?(%r{\A[A-Za-z0-9][A-Za-z0-9:._/-]*\z}) if record.key?("bn")
      current = @base.fetch("bver", FORMAT_VERSION)
      raise UnsupportedVersionError.new("unsupported version #{current}", pointer: "#{pointer}/bver") if current > FORMAT_VERSION
      raise ValidationError.new("all records must use the same version", pointer: "#{pointer}/bver") if @version && @version != current

      @version = current
      fields = VALUE_LABELS.count { |key| record.key?(key) }
      effective_value = fields == 1 || (fields.zero? && @base.key?("bv"))
      effective_sum = record.key?("s") || @base.key?("bs")
      violation("expected exactly one value, or a sum", pointer) if fields > 1 || (!effective_value && !effective_sum)
      suffix = record.fetch("n", "")
      valid_name = if @base.fetch("bn", "").empty?
                     suffix.match?(%r{\A[A-Za-z0-9][A-Za-z0-9:._/-]*\z})
                   else
                     @base_name_valid && suffix.match?(%r{\A[A-Za-z0-9:._/-]*\z})
                   end
      violation("invalid resolved name", "#{pointer}/n") unless valid_name
      %w[bu u].each do |key|
        violation("unregistered unit", "#{pointer}/#{key}") if record.key?(key) && !Units.registered?(record[key])
      end
      violation("update time must be nonnegative", "#{pointer}/ut") if record.key?("ut") && record["ut"].negative?
      validate_data(record["vd"], "#{pointer}/vd") if record.key?("vd")
      @base.dup.freeze
    end

    def validate_data(text, pointer)
      valid = text.match?(/\A[A-Za-z0-9_-]*\z/) && text.length % 4 != 1
      if valid && !text.empty? && text.length % 4 != 0
        value = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".index(text[-1])
        valid = value.nobits?(text.length % 4 == 2 ? 15 : 3)
      end
      violation("expected canonical unpadded base64url", pointer) unless valid
      raise LimitError, "binary value exceeds max_data_bytes" if text.bytesize * 3 / 4 > @limits[:max_data_bytes]
    end

    def json_value(value, pointer, depth)
      raise LimitError, "value exceeds max_depth" if depth > @limits[:max_depth]

      case value
      when Hash
        value.each do |key, child|
          valid = key.is_a?(String) && key.valid_encoding? && (key.encoding == Encoding::UTF_8 || key.ascii_only?)
          raise ParseError, "JSON keys must be valid UTF-8 text" unless valid

          json_value(child, "#{pointer}/#{key.gsub("~", "~0").gsub("/", "~1")}", depth + 1)
        end
      when Array then value.each_with_index { |child, i| json_value(child, "#{pointer}/#{i}", depth + 1) }
      when Float then raise ParseError, "nonfinite number" unless value.finite?
      when String then raise ParseError, "invalid UTF-8 string" unless value.encoding == Encoding::UTF_8 ? value.valid_encoding? : value.ascii_only?
      when Integer, TrueClass, FalseClass, NilClass
        nil
      else raise ParseError, "unsupported JSON value"
      end
    end

    private

    def violation(message, pointer)
      error = ValidationError.new(message, pointer: pointer)
      raise error if @strict

      raise LimitError, "diagnostics exceed max_warnings" if @warnings.length >= @limits[:max_warnings]

      @warnings << error
    end
  end
end

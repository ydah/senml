# frozen_string_literal: true

module SenML
  class Record
    LABELS.each { |label, fields| define_method(fields.fetch("accessor")) { self[label] } }
    def initialize(data, base: {}, **options)
      @data = SenML.copy(data)
      # Validator snapshots contain immutable strings, which can be shared even
      # when a long base name applies to thousands of short records.
      @base = base.transform_values { |value| value.frozen? ? value : SenML.copy(value).freeze }.freeze
      @limits = SenML.limits(options)
    end

    def [](key) = @data[key.to_s]
    def to_h = SenML.copy(@data)
    def name = @base.fetch("bn", "") + @data.fetch("n", "")
    def unit = @data.fetch("u") { @base["bu"] }&.dup
    def time = @base.fetch("bt", 0) + @data.fetch("t", 0)

    def value
      key = VALUE_LABELS.find { |label| @data.key?(label) }
      return data if key == "vd"
      return @data[key] if key && key != "v"
      return nil unless key || @base.key?("bv")

      @base.fetch("bv", 0) + @data.fetch("v", 0)
    end

    def sum
      return unless @data.key?("s") || @base.key?("bs")

      @base.fetch("bs", 0) + @data.fetch("s", 0)
    end

    def time_at(now: nil)
      seconds = time
      if seconds < ABSOLUTE_TIME
        raise ConversionError, "relative time requires explicit now" unless now

        seconds += now.is_a?(Time) ? now.to_r : now
      end
      Time.at(seconds).utc
    end

    # Decode the data value only when requested, after checking its size.
    # @return [String, nil] binary octets, or nil if vd is absent
    def data
      encoded = @data["vd"]
      return unless encoded

      Validator.new(strict: true, limits: @limits).validate_data(encoded, "/vd")
      padded = encoded.tr("-_", "+/") + ("=" * ((4 - (encoded.length % 4)) % 4))
      padded.unpack1("m0")
    rescue ArgumentError => e
      raise ConversionError, e.message
    end

    def resolved(now:)
      Validator.new(strict: true, limits: @limits).accept(@base.merge(@data), 0)
      unknown_base = (@base.keys | @data.keys).find { |key| key.start_with?("b") && !BASE_LABELS.include?(key) }
      raise ConversionError, "cannot resolve unknown base field #{unknown_base}" if unknown_base

      result = @data.except(*BASE_LABELS)
      result["n"] = name
      result["u"] = unit if unit
      seconds = time
      seconds += now if seconds < ABSOLUTE_TIME
      raise ConversionError, "resolved time must be absolute and finite" unless seconds.finite? && seconds >= ABSOLUTE_TIME

      result["t"] = seconds
      result["v"] = @base.fetch("bv", 0) + @data.fetch("v", 0) if @data.key?("v") || (VALUE_LABELS.none? { |key| @data.key?(key) } && @base.key?("bv"))
      result["s"] = sum if sum
      result["ct"] ||= @base["bct"] if @data.key?("vd") && @base.key?("bct")
      version = @base.fetch("bver", FORMAT_VERSION)
      result["bver"] = version if version != FORMAT_VERSION
      result
    end
  end
end

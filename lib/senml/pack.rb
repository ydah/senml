# frozen_string_literal: true

module SenML
  class Pack
    include Enumerable

    attr_reader :warnings

    def initialize(records, strict: true, **options)
      @limits = SenML.limits(options)
      raise ParseError, "pack must be an array" unless records.is_a?(Array)
      raise ValidationError, "pack must contain at least one record" if records.empty?
      raise LimitError, "pack exceeds max_records" if records.length > @limits[:max_records]

      validator = Validator.new(strict: strict, limits: @limits)
      bytes = 2
      @records = records.each_with_index.map do |data, index|
        data = data.to_h if data.is_a?(Record)
        base = validator.accept(data, index)
        bytes += validator.record_bytes + (index.zero? ? 0 : 1)
        raise LimitError, "pack exceeds max_bytes" if bytes > @limits[:max_bytes]

        Record.new(data, base: base, **@limits)
      end
      @warnings = validator.warnings
    end

    def each(&) = @records.each(&)
    def [](index) = @records[index]
    def size = @records.size
    alias length size
    def to_h = @records.map(&:to_h)

    def to_json(*_args)
      self.class.new(to_h, **@limits)
      text = JSONCodec.generate(to_h)
      raise LimitError, "pack exceeds max_bytes" if text.bytesize > @limits[:max_bytes]

      text
    end

    # Expand inherited base fields and stably sort absolute measurement times.
    # @param now [Time, Integer, Float] reference for relative timestamps
    # @return [Pack] a new pack without inherited base fields
    def resolve(now: Time.now)
      reference = now.is_a?(Time) ? now.to_f : now
      raise ArgumentError, "now must be a finite number or Time" unless reference.is_a?(Numeric) && reference.finite?

      bytes = 2 # JSON array delimiters
      validator = Validator.new(strict: true, limits: @limits)
      records = @records.each_with_index.map do |record, index|
        resolved = record.resolved(now: reference)
        validator.json_value(resolved, "/#{index}", 0)
        bytes += JSONCodec.generate(resolved).bytesize + (index.zero? ? 0 : 1)
        raise LimitError, "resolved pack exceeds max_bytes" if bytes > @limits[:max_bytes]

        [resolved, index]
      end
      self.class.new(records.sort_by { |record, index| [record["t"], index] }.map(&:first), **@limits)
    end

    # Select one-based indices and ranges, preserving inherited base context.
    # @param fragment [String] RFC 8428 fragment, optionally beginning with '#'
    # @return [Pack]
    def select_fragment(fragment)
      fragment = fragment.delete_prefix("#")
      raise ValidationError, "invalid record fragment" unless fragment.match?(/\Arec=[1-9]\d*(?:-(?:[1-9]\d*|\*))?(?:,[1-9]\d*(?:-(?:[1-9]\d*|\*))?)*\z/)

      selected = {}
      fragment.delete_prefix("rec=").split(",").each do |range|
        start, stop = range.split("-", 2)
        first = start.to_i
        last = if stop == "*"
                 size
               else
                 (stop ? stop.to_i : first)
               end
        raise ValidationError, "fragment outside pack bounds" unless last.between?(first, size)

        (first..last).each { |index| selected[index - 1] = true }
      end
      base = {}
      emitted_base = {}
      bytes = 2
      selected_count = 0
      records = @records.each_with_index.filter_map do |record, index|
        data = record.to_h
        unknown_base = data.keys.find { |key| key.start_with?("b") && !BASE_LABELS.include?(key) }
        raise ConversionError, "cannot select with unknown base field #{unknown_base}" if unknown_base

        BASE_LABELS.each { |label| base[label] = data[label] if data.key?(label) }
        next unless selected[index]

        changes = base.reject { |label, value| emitted_base.key?(label) && emitted_base[label] == value }
        entry = changes.merge(data)
        bytes += JSONCodec.generate(entry).bytesize + (selected_count.zero? ? 0 : 1)
        raise LimitError, "selected pack exceeds max_bytes" if bytes > @limits[:max_bytes]

        emitted_base = base.dup
        selected_count += 1
        entry
      end
      self.class.new(records, **@limits)
    end

    def self.build(base_name: nil, base_time: nil, base_unit: nil, **)
      builder = Builder.new({ "bn" => base_name, "bt" => base_time, "bu" => base_unit }.compact)
      yield builder
      new(builder.records, **)
    end

    class Builder
      attr_reader :records

      def initialize(base)
        @base = base
        @records = []
      end

      def add(**values)
        data = values.transform_keys(&:to_s)
        data = @base.merge(data) if @records.empty?
        @records << data
        self
      end
    end
  end
end

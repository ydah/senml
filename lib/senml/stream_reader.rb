# frozen_string_literal: true

module SenML
  class StreamReader
    include Enumerable

    attr_reader :warnings

    def initialize(io, strict: true, allow_incomplete: false, **options)
      @io = io
      @strict = strict
      @allow_incomplete = allow_incomplete
      @limits = SenML.limits(options)
      @warnings = []
    end

    # Yield records immediately; a later malformed record can still raise.
    # @yieldparam record [Record] measurement with the current base context
    # @return [StreamReader, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      validator = Validator.new(strict: @strict, limits: @limits)
      @warnings = validator.warnings
      phase = :start
      buffer = +"".b
      depth = 0
      quoted = false
      escaped = false
      index = 0
      while (chunk = @io.read(4096)) && !chunk.empty?
        chunk.each_byte do |byte|
          if depth.positive?
            buffer << byte
            raise LimitError, "stream record exceeds max_record_bytes" if buffer.bytesize > @limits[:max_record_bytes]

            if quoted
              if escaped then escaped = false
              elsif byte == 92 then escaped = true
              elsif byte == 34 then quoted = false
              end
            elsif byte == 34 then quoted = true
            elsif [123, 91].include?(byte) then depth += 1
            elsif [125, 93].include?(byte) then depth -= 1
            end
            raise LimitError, "stream record exceeds max_depth" if depth > @limits[:max_depth]
            next unless depth.zero?

            raw = JSONCodec.parse(buffer, max_depth: @limits[:max_depth])
            base = validator.accept(raw, index)
            yield Record.new(raw, base: base, **@limits)
            index += 1
            phase = :separator
          elsif [9, 10, 13, 32].include?(byte)
            next
          elsif (phase == :start && byte == 91) || (phase == :separator && byte == 44)
            phase = :record
          elsif phase == :record && byte == 123
            raise LimitError, "stream exceeds max_records" if index >= @limits[:max_records]

            buffer = +"{".b
            depth = 1
          elsif phase == :separator && byte == 93
            phase = :end
          else
            raise ParseError, "invalid SenSML array structure"
          end
        end
      end
      raise ParseError, "incomplete SenSML array" unless phase == :end || (@allow_incomplete && index.positive? && depth.zero?)

      self
    end
  end
end

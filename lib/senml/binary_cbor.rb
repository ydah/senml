# frozen_string_literal: true

module SenML
  # Internal wire codec. RFC 8949 sections 3.1–3.4 define the byte format;
  # application-specific tag meanings belong to the caller.
  module BinaryCBOR
    class Error < StandardError; end
    class LimitError < Error; end
    class UnsupportedError < Error; end
    Tagged = Struct.new(:tag, :value)
    Simple = Struct.new(:value)
    Float32 = Struct.new(:value)

    def self.decode(bytes, **options)
      Decoder.new(bytes, **options).read
    end

    def self.encode(value, **options)
      Encoder.new(**options).write(value)
    end

    class Decoder
      DEFAULTS = { max_input_size: 16_777_216, max_depth: 32, max_nodes: 1_000_000, max_collection_size: 200_000,
                   max_string_size: 16_777_216, max_binary_size: 16_777_216, allowed_tags: nil, allow_indefinite_strings: true,
                   max_records: nil, max_record_bytes: nil }.freeze

      def initialize(bytes, **options)
        @limits = DEFAULTS.merge(options)
        raise Error, "CBOR input must be a String" unless bytes.is_a?(String)
        raise LimitError, "CBOR exceeds max_input_size" if bytes.bytesize > @limits[:max_input_size]

        @bytes = bytes
        @offset = 0
        @nodes = 0
      end

      def read
        value = read_value(0)
        raise Error, "trailing CBOR input" unless @offset == @bytes.bytesize

        value
      end

      private

      def take(size)
        raise Error, "truncated CBOR input" if size > @bytes.bytesize - @offset
        if @record_start && @limits[:max_record_bytes] && @offset + size - @record_start > @limits[:max_record_bytes]
          raise LimitError, "CBOR record exceeds max_record_bytes"
        end

        result = @bytes.byteslice(@offset, size)
        @offset += size
        result
      end

      def argument(info)
        return info if info < 24
        return nil if info == 31

        format = { 24 => [1, "C"], 25 => [2, "n"], 26 => [4, "N"], 27 => [8, "Q>"] }[info]
        raise Error, "reserved CBOR additional information" unless format

        take(format[0]).unpack1(format[1])
      end

      def read_value(depth)
        @nodes += 1
        raise LimitError, "CBOR exceeds max_nodes" if @nodes > @limits[:max_nodes]
        raise LimitError, "CBOR exceeds max_depth" if depth > @limits[:max_depth]

        initial = take(1).getbyte(0)
        major, info = initial.divmod(32)
        return read_simple(info) if major == 7

        size = argument(info)
        raise Error, "indefinite CBOR integer or tag" if size.nil? && [0, 1, 6].include?(major)

        case major
        when 0 then size
        when 1 then -1 - size
        when 2, 3 then read_string(major, size, depth)
        when 4, 5 then read_collection(major, size, depth)
        when 6
          raise UnsupportedError, "unsupported CBOR tag" if @limits[:allowed_tags] && !@limits[:allowed_tags].include?(size)

          Tagged.new(size, read_value(depth + 1))
        end
      end

      def read_string(major, size, depth)
        limit = @limits[:max_string_size]
        limit = [limit, @limits[:max_binary_size]].min if major == 2
        if size
          raise LimitError, "CBOR string exceeds #{major == 2 ? "max_binary_size" : "max_string_size"}" if size > limit

          value = take(size).dup
          value.force_encoding(major == 2 ? Encoding::BINARY : Encoding::UTF_8)
          raise Error, "invalid CBOR UTF-8 text" unless value.valid_encoding?

          return value
        end
        raise Error, "CBOR strings must have definite length" unless @limits[:allow_indefinite_strings]

        result = String.new(encoding: major == 2 ? Encoding::BINARY : Encoding::UTF_8)
        until @bytes.getbyte(@offset) == 255
          initial = @bytes.getbyte(@offset)
          raise Error, "invalid indefinite CBOR string chunk" unless initial && initial.div(32) == major && (initial & 31) < 28

          chunk = read_value(depth + 1)
          raise LimitError, "CBOR string exceeds byte limit" if result.bytesize + chunk.bytesize > limit

          result << chunk
        end
        take(1)
        result
      end

      def read_collection(major, size, depth)
        limit = @limits[:max_collection_size]
        limit = [limit, @limits[:max_records]].min if depth.zero? && @limits[:max_records]
        raise LimitError, "CBOR exceeds collection limit" if size && size > limit

        result = major == 4 ? [] : {}
        count = 0
        until size ? count == size : @bytes.getbyte(@offset) == 255
          raise LimitError, "CBOR exceeds collection limit" if count >= limit

          @record_start = @offset if depth.zero? && @limits[:max_record_bytes]
          if major == 4
            result << read_value(depth + 1)
          else
            key = read_value(depth + 1)
            unless key.is_a?(Integer) || (key.is_a?(String) && key.encoding == Encoding::UTF_8)
              raise UnsupportedError, "CBOR map keys must be text or integers"
            end
            raise Error, "duplicate CBOR map key" if result.key?(key)

            result[key] = read_value(depth + 1)
          end
          @record_start = nil if depth.zero?
          count += 1
        end
        take(1) unless size
        result
      end

      def read_simple(info)
        case info
        when 20 then false
        when 21 then true
        when 22 then nil
        when 0..19, 23 then Simple.new(info)
        when 24
          value = take(1).getbyte(0)
          raise Error, "reserved CBOR simple value" if value < 32

          Simple.new(value)
        when 25 then half(take(2).unpack1("n"))
        when 26 then take(4).unpack1("g")
        when 27 then take(8).unpack1("G")
        else raise Error, "reserved CBOR value or unexpected break"
        end
      end

      def half(bits)
        exponent = (bits >> 10) & 31
        fraction = bits & 1023
        magnitude = if exponent == 31
                      fraction.zero? ? Float::INFINITY : Float::NAN
                    elsif exponent.zero?
                      Math.ldexp(fraction.to_f, -24)
                    else
                      Math.ldexp((1024 + fraction).to_f, exponent - 25)
                    end
        bits[15].zero? ? magnitude : -magnitude
      end
    end

    class Encoder
      def initialize(max_output_size: 16_777_216, max_depth: 128)
        @max_output_size = max_output_size
        @max_depth = max_depth
        @buffer = String.new(encoding: Encoding::BINARY)
      end

      def write(value)
        append_value(value, 0)
        @buffer
      end

      private

      def append(bytes)
        raise LimitError, "CBOR output exceeds max_input_size" if @buffer.bytesize + bytes.bytesize > @max_output_size

        @buffer << bytes.b
      end

      def header(major, number)
        raise Error, "CBOR argument outside unsigned 64-bit range" unless number.is_a?(Integer) && number.between?(0, (2**64) - 1)

        case number
        when 0...24 then append([(major << 5) | number].pack("C"))
        when 24..255 then append([(major << 5) | 24, number].pack("CC"))
        when 256..65_535 then append([(major << 5) | 25, number].pack("Cn"))
        when 65_536..4_294_967_295 then append([(major << 5) | 26, number].pack("CN"))
        else append([(major << 5) | 27, number].pack("CQ>"))
        end
      end

      def append_value(value, depth)
        raise LimitError, "CBOR output exceeds max_depth" if depth > @max_depth

        case value
        when Integer then append_integer(value)
        when Float then append_float(value)
        when Float32 then append("\xfa".b + [value.value].pack("g"))
        when String then append_string(value)
        when Array
          header(4, value.length)
          value.each { |item| append_value(item, depth + 1) }
        when Hash
          header(5, value.length)
          value.each { |key, item| append_value(key, depth + 1); append_value(item, depth + 1) }
        when Tagged
          header(6, value.tag)
          append_value(value.value, depth + 1)
        when Simple
          raise Error, "invalid CBOR simple value" unless value.value.is_a?(Integer) && (value.value.between?(0, 23) || value.value.between?(32, 255))

          header(7, value.value)
        when TrueClass then append("\xf5".b)
        when FalseClass then append("\xf4".b)
        when NilClass then append("\xf6".b)
        else raise Error, "unsupported CBOR value type"
        end
      end

      def append_integer(value)
        magnitude = value.negative? ? -1 - value : value
        return header(value.negative? ? 1 : 0, magnitude) if magnitude < 2**64

        header(6, value.negative? ? 3 : 2)
        hex = magnitude.to_s(16)
        hex = "0#{hex}" if hex.length.odd?
        append_string([hex].pack("H*"))
      end

      def append_float(value)
        half = half_bits(value)
        return append("\xf9".b + [half].pack("n")) if half

        single = [value].pack("g")
        append(single.unpack1("g") == value ? "\xfa".b + single : "\xfb".b + [value].pack("G"))
      end

      def half_bits(value)
        return 0x7e00 if value.nan?

        sign = value.negative? || (value.zero? && (1.0 / value).negative?) ? 0x8000 : 0
        return sign | 0x7c00 if value.infinite?
        return sign if value.zero?

        significand, exponent = Math.frexp(value.abs)
        if exponent < -13
          fraction = Math.ldexp(value.abs, 24)
          return sign | fraction.to_i if fraction == fraction.to_i
        elsif exponent <= 16
          fraction = significand * 2048 - 1024
          return sign | ((exponent + 14) << 10) | fraction.to_i if fraction == fraction.to_i
        end
        nil
      end

      def append_string(value)
        binary = value.encoding == Encoding::BINARY
        raise Error, "invalid CBOR UTF-8 text" unless binary || (value.valid_encoding? && (value.encoding == Encoding::UTF_8 || value.ascii_only?))

        header(binary ? 2 : 3, value.bytesize)
        append(value)
      end
    end
  end
end

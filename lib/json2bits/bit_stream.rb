module Json2Bits
  class BitWriter
    def initialize
      @bits = +""
    end

    def write_bits(value, length)
      raise ArgumentError, "length must be positive" if length.negative?
      return if length.zero?
      max = (1 << length) - 1
      raise SerializationError, "value #{value} does not fit in #{length} bits" if value < 0 || value > max

      length.times do |i|
        bit_index = length - i - 1
        bit = (value >> bit_index) & 1
        @bits << (bit == 1 ? "1" : "0")
      end
    end

    def write_bool(value)
      write_bits(value ? 1 : 0, 1)
    end

    def write_bytes(bytes)
      bytes.each_byte { |byte| write_bits(byte, 8) }
    end

    def write_bitstring(bit_string)
      unless bit_string.is_a?(String) && bit_string.match?(/\A[01]*\z/)
        raise ArgumentError, "bit_string must contain only 0 or 1 characters"
      end

      @bits << bit_string
    end

    def bits
      @bits.dup
    end

    def size
      @bits.length
    end

    def to_bytes
      return "".b if @bits.empty?

      padded_bits = @bits.dup
      padding = (8 - (padded_bits.length % 8)) % 8
      padded_bits << "0" * padding if padding.positive?
      [padded_bits].pack("B*")
    end
  end

  class BitReader
    def initialize(bytes)
      bit_string = bytes.unpack1("B*") || ""
      @bits = bit_string
      @position = 0
    end

    def read_bits(length)
      raise ArgumentError, "length must be positive" if length.negative?
      return 0 if length.zero?
      raise DeserializationError, "not enough bits available" if remaining_bits < length

      slice = @bits.slice(@position, length)
      @position += length
      slice.to_i(2)
    end

    def read_bool
      read_bits(1) == 1
    end

    def remaining_bits
      @bits.length - @position
    end

    def align_to_byte!
      offset = @position % 8
      return if offset.zero?

      @position += (8 - offset)
    end
  end
end

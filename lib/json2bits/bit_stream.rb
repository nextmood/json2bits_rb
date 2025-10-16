

class BitStream

    attr_reader :bytes, :nb_bits_written, :nb_bits_read

    def initialize(bytes: [])
        @index = 0
        @bytes = bytes
        @nb_bits_written = 0
        @nb_bits_readable = bytes.size * 8
        @nb_bits_read = 0
    end
        
    def read_bits(nb_bit)
        raise Json2Bits::NoMoreBitsError if (@index + nb_bit) > @nb_bits_readable
        @nb_bits_read += nb_bit
        value = 0
        nb_bit.times do
            byte_index, bit_index = compute_indexes
            bit = (@bytes[byte_index] >> bit_index) & 0x01
            value = (value << 1) | bit
            @index += 1
        end
        value
    end

    def write_bits(value, nb_bit)
        @nb_bits_written += nb_bit
        nb_bit.downto(1) do |i|
            bit = (value >> (i - 1)) & 0x01
            byte_index, bit_index = compute_indexes
            @bytes << 0 if @bytes.size <= byte_index
            @bytes[byte_index] |= (bit << bit_index)
            @index += 1
        end
    end

    
    def compute_indexes
        [@index / 8, 7 - (@index % 8)]
    end
end
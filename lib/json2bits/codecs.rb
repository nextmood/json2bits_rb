class Codec
    attr_reader :key, :codecs, :comment

    def initialize(key:, comment: nil)
        @key = key
        @comment = comment
    end

    def post_initialize(codecs)
        @codecs = codecs
    end

    def to_s
        "#{self.class} #{@key}"
    end

    # parameters value depends of the subclass (could be an integer, a float, a list of bytes, a string etc...)
    # also bit_stream is modified in place
    # always return the bit_stream
    def serialize(bit_stream, value, is_last: true)
        #raise NotImplementedError, "serialize method must be implemented in subclass"
        bit_stream
    end

    def serialize_to_bytes(value)
      writer = BitStream.new
      serialize(writer, value)
      writer.bytes
      #serialize(BitStream.new, value).bytes
    end

    def deserialize(bit_stream)
        raise NotImplementedError, "deserialize method must be implemented in subclass"
    end

    def deserialize_from_bytes(bytes)
        deserialize(BitStream.new(bytes: bytes))
    end

    # remove all sequence keys
    def deserialize_and_flatten(bit_stream)
        h = deserialize(bit_stream)
        if h.is_a?(Hash)
            h.each_with_object({}) do |(k, v), result|
                if v.is_a?(Hash) && @codecs.key_2_codec(k).is_a?(CodecSequence)
                    v.each do |sub_k, sub_v|
                        result[sub_k] = sub_v
                    end
                else
                    result[k] = v
                end
            end
        else
            h
        end
    end
end

class CodecFixLength < Codec
    def initialize(key:, nb_bit:, comment: nil)
        super(key: key, comment: comment)
        @nb_bit = nb_bit
    end

    def to_s
        "#{super} nb_bit=#{@nb_bit}"
    end
end

class CodecVoid < CodecFixLength
    def initialize(key:, comment: nil)
        super(key: key, nb_bit: 0, comment: comment)
    end

    def deserialize(bit_stream)
        nil
    end
end

class CodecInteger < CodecFixLength
    def initialize(key:, max_integer: nil, nb_bit: nil, comment: nil)
        nb_bit ||= Math.log2(max_integer + 1).ceil
        raise "nb_bit must be greater than 0 and less than or equal to 64" if nb_bit < 1 || nb_bit > 64
        @max_integer ||= (2 ** nb_bit) - 1
        super(key: key, nb_bit: nb_bit, comment: comment)
    end

    def serialize(bit_stream, value, is_last: true)
        raise "Value #{value} exceeds maximum integer #{@max_integer}" if value > @max_integer
        bit_stream.write_bits(value, @nb_bit)
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        bit_stream.read_bits(@nb_bit)
    end
end

class CodecBoolean < CodecInteger
    def initialize(key:, comment: nil)
        super(key: key, max_integer: 1, nb_bit: 1, comment: comment)
    end

    def serialize(bit_stream, value, is_last: true)
        int_value = value ? 1 : 0
        super(bit_stream, int_value, is_last: is_last)
    end

    def deserialize(bit_stream)
        int_value = super(bit_stream)
        int_value == 1
    end
    
end

class CodecSymbol < CodecInteger
    def initialize(key:, symbols:, nb_bit: nil, comment: nil)
        @symbols = symbols
        super(key: key, max_integer: symbols.size - 1, nb_bit: nb_bit, comment: comment)
    end

    def serialize(bit_stream, value, is_last: true)
        super(bit_stream, @symbols.index(value), is_last: is_last)
    end

    def deserialize(bit_stream)
        @symbols[super(bit_stream)]
    end

    def to_s
        "#{super} symbols=#{@symbols}"
    end
end

class CodecFloat < CodecInteger
    def initialize(key:, min_float:, max_float:, nb_bit:, comment: nil)
        @min_float = min_float
        @max_float = max_float
        super(key: key, nb_bit: nb_bit, comment: comment)
    end

    def serialize(bit_stream, value, is_last: true)
        raise "Value #{value} is out of range (#{@min_float}, #{@max_float})" unless value.between?(@min_float, @max_float)
        int_value = ((value - @min_float) / (@max_float - @min_float) * @max_integer).round
        super(bit_stream, int_value)
    end

    def deserialize(bit_stream)
        int_value = super(bit_stream)
        ((int_value.to_f / @max_integer) * (@max_float - @min_float) + @min_float)
    end

    def to_s
        "#{super} range=(#{@min_float}, #{@max_float})"
    end
end

class CodecBytes < CodecFixLength
    def initialize(key:, nb_bytes:, comment: nil)
        super(key: key, nb_bit: nb_bytes * 8, comment: comment)
    end

    def serialize(bit_stream, value, is_last: true)
        raise "Value length #{value.length} does not match expected length #{@nb_bit / 8}" if value.length != @nb_bit / 8
        value.each_byte do |byte|
            bit_stream.write_bits(byte, 8)
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        bytes = []
        (@nb_bit / 8).times do
            byte = bit_stream.read_bits(8)
            bytes << byte
        end
        bytes.pack("C*")
    end
end

class CodecHexa < CodecBytes
    def serialize(bit_stream, value, is_last: true)
        bytes = [value].pack("H*")
        super(bit_stream, bytes, is_last: is_last)
    end

    def deserialize(bit_stream)
        bytes = super(bit_stream)
        bytes.unpack1("H*")
    end
end

class CodecComposite < Codec
end

class CodecAlias < CodecComposite
    def initialize(key:, target_key:, comment: nil)
        super(key: key, comment: comment)
        @target_key = target_key
    end

    def serialize(bit_stream, value, is_last: true)
        target_codec = @codecs.key_2_codec(@target_key)
        raise "Target codec #{@target_key} not found for alias #{@key}" if target_codec.nil?
        target_codec.serialize(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        target_codec = @codecs.key_2_codec(@target_key)
        raise "Target codec #{@target_key} not found for alias #{@key}" if target_codec.nil?
        target_codec.deserialize(bit_stream)
    end
end

class CodecIntegerLong < CodecComposite
    def initialize(key:, bits_segement:, comment: nil)
        super(key: key, comment: comment)
        @bits_segment = bits_segement.sort.map { |nb_bit| [nb_bit, 2**nb_bit - 1] } 
        raise "integer can't have more than 64 bits" if @bits_segment.last.first > 64
        @max_value = @bits_segment.last.last
        @selector_nb_bits = Math.log2(@bits_segment.size).ceil
    end

    def serialize(bit_stream, value, is_last: true)        
        raise "Value #{value} exceeds maximum integer #{@max_value}" if value > @max_value
        @bits_segment.find.with_index do |(nb_bit, max_value), index|
            if value <= max_value
                bit_stream.write_bits(index, @selector_nb_bits)
                bit_stream.write_bits(value, nb_bit)
                return
            end
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        segment_index = bit_stream.read_bits(@selector_nb_bits)
        nb_bit, = @bits_segment[segment_index]
        bit_stream.read_bits(nb_bit)
    end


end

class CodecSequence < CodecComposite
    def initialize(key:, keys:, comment: nil)
        super(key: key, comment: comment)
        @keys = keys
    end

    def serialize(bit_stream, value, is_last: true)
        last_key = @keys.last
        @keys.each do |key|
            codec = @codecs.key_2_codec(key)
            codec.serialize(bit_stream, value.fetch(key), is_last: key == last_key && is_last)
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        @keys.each_with_object({}) do |key, result|
            codec = @codecs.key_2_codec(key)
            result[key] = codec.deserialize(bit_stream)
        end
    end

    def to_s
        "#{super} [#{@keys.join(' -> ')}]"
    end
end

class CodecArray < CodecComposite
    def initialize(key:, item_key:, nb_item_max: nil, nb_bit: nil, comment: nil)
        super(key: key, comment: comment)
        @item_key = item_key
        @counter_nb_bits = nb_bit || Math.log2(nb_item_max + 1).ceil
    end

    def serialize(bit_stream, value, is_last: true)
        nb_item = value.size
        bit_stream.write_bits(nb_item, @counter_nb_bits)
        item_codec = @codecs.key_2_codec(@item_key)
        last_item = value.last
        value.each do |item|
            item_codec.serialize(bit_stream, item, is_last: item == last_item && is_last)
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        nb_item = bit_stream.read_bits(@counter_nb_bits)
        item_codec = @codecs.key_2_codec(@item_key)
        nb_item.times.map { item_codec.deserialize(bit_stream) }
    end
    
    def to_s
        "#{super} [#{@item_key}, ...] #{2**@counter_nb_bits -1} max items"
    end
end

class CodecXor < CodecComposite
    attr_reader :bkey_2_codec, :key_2_bkey, :nb_bit_binary_key

    def initialize(key:, comment: nil, nb_bit_binary_key: nil, binary_keys:)
        super(key: key, comment: comment)
        @nb_bit_binary_key = nb_bit_binary_key || Math.log2(@binary_keys.size).ceil
        @binary_keys = binary_keys
        @max_type = 2 ** @nb_bit_binary_key
        @binary_keys.each do |k, bkey|
            raise "Binary key value #{bkey} exceeds maximum #{@max_type - 1}" if bkey >= @max_type
        end
        @option_keys = @binary_keys.keys
        @bkey_2_codec = {}
        @key_2_bkey = {}
    end

    def safe_for_list?
        raise "The binary value 0x0 is not allowed for list" if @bkey_2_codec[0x0]
    end

    def post_initialize(codecs)
        super(codecs)
        # update the CodecList(s) if any
        @binary_keys.each do |key, binary_key|
            codec = codecs.key_2_codec(key) || raise("Codec #{key} not found for adding binary key")
            add_codec(codec: codec, binary_key: binary_key)
        end
    end

    def serialize(bit_stream, value , is_last: true)
        raise "Expecting a hash with a single key among #{@option_keys}" unless value.is_a?(Hash) && value.size == 1
        item_key = value.keys.first
        item_value = value[item_key]
        item_bkey = @key_2_bkey[item_key]
        raise "Unknown option key #{item_key} for XOR serialization" if item_bkey.nil?
        bit_stream.write_bits(item_bkey, @nb_bit_binary_key)
        codec = @codecs.key_2_codec(item_key)
        codec.serialize(bit_stream, item_value, is_last: is_last)
    end

    def deserialize(bit_stream)
        item_bkey = bit_stream.read_bits(@nb_bit_binary_key)
        item_codec = @bkey_2_codec[item_bkey]
        { item_codec.key => item_codec.deserialize(bit_stream) }
    end

    def to_s
        "#{super} options=#{@option_keys.join(', ')}"
    end

    private

    def add_codec(codec:, binary_key:)
        @bkey_2_codec[binary_key] = codec
        @key_2_bkey[codec.key] = binary_key
    end

end

# concept of list
class CodecListXor < CodecComposite

    def initialize(key:, key_xor:, comment: nil)
        super(key: key, comment: comment)
        @key_xor = key_xor
    end

    def post_initialize(codecs)
        super(codecs)
        @xor_codec = @codecs.key_2_codec(@key_xor)
        @nb_bit_binary_key = @xor_codec.nb_bit_binary_key
        raise "XOR codec #{@key_xor} not found or not CodecXor for list #{@key}" if @xor_codec.nil? || !@xor_codec.is_a?(CodecXor)
        @xor_codec.safe_for_list?
    end

    # value is a list of value of xor
    def serialize(bit_stream, keys_values, is_last: true)
        raise "Expecting an array of hashes value matching the xor definition" unless keys_values.is_a?(Array) && keys_values.all? { |item| item.is_a?(Hash) && item.size == 1 }
        @last_item_key = keys_values.last.to_a.first.first
        keys_values.each do |key_value|
            @xor_codec.serialize(bit_stream, key_value, is_last: key_value.first.first == @last_item_key && is_last)
        end
        bit_stream.write_bits(0x0, @nb_bit_binary_key) unless is_last
        super(bit_stream, keys_values, is_last: is_last)
    end

    def deserialize(bit_stream)
        result = []
        while (bkey = read_bkey(bit_stream)) != 0x0
            item_codec = @xor_codec.bkey_2_codec[bkey]
            raise "Unknown binary key #{bkey} during list item deserialization" if item_codec.nil?
            item_value = item_codec.deserialize(bit_stream)
            result << { item_codec.key => item_value }
        end
        result
    end

    private

    def read_bkey(bit_stream)
        begin
            bit_stream.read_bits(@nb_bit_binary_key)
        rescue Json2Bits::NoMoreBitsError
            0x0
        end
    end
    
end


class Codecs

    attr_reader :dictionnary

    def initialize
        @dictionnary = {}
    end

    def add_codec(codec)
        @dictionnary[codec.key] = codec
        codec.post_initialize(self)
        codec
    end

    def key_2_codec(key)
        @dictionnary[key]
    end

    def to_s
        s = @dictionnary.map do |key, codec|
            "\n- #{codec}"
        end.join(", ")
        "#{self.class} nb_codec=#{@dictionnary.size}#{s}"
    end

end

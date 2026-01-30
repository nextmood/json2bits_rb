class Codec
    attr_reader :key, :codecs, :statics, :comment

    def initialize(key:, statics: {}, comment: nil)
        @key = key
        @statics = statics
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

    def serialize_to_bytes(value, compute_nb_bit: false)
      writer = BitStream.new
      serialize(writer, value)
      compute_nb_bit ? [writer.bytes, writer.nb_bits_written] : writer.bytes
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
    def initialize(key:, nb_bit:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @nb_bit = nb_bit
    end

    def to_s
        "#{super} nb_bit=#{@nb_bit}"
    end
end

class CodecVoid < CodecFixLength
    def initialize(key:, statics: {}, comment: nil)
        super(key: key, nb_bit: 0, statics: statics, comment: comment)
    end

    def deserialize(bit_stream)
        nil
    end
end

class CodecInteger < CodecFixLength
    def initialize(key:, max_integer: nil, nb_bit: nil, statics: {}, comment: nil)
        nb_bit ||= Math.log2(max_integer + 1).ceil
        raise "nb_bit must be greater than 0 and less than or equal to 64" if nb_bit < 1 || nb_bit > 64
        @max_integer ||= (2 ** nb_bit) - 1
        super(key: key, nb_bit: nb_bit, statics: statics, comment: comment)
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
    def initialize(key:, statics: {}, comment: nil)
        super(key: key, max_integer: 1, nb_bit: 1, statics: statics, comment: comment)
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
    def initialize(key:, symbols:, nb_bit: nil, statics: {}, comment: nil)
        @symbols = symbols
        super(key: key, max_integer: symbols.size - 1, nb_bit: nb_bit, statics: statics, comment: comment)
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
    def initialize(key:, min_float:, max_float:, nb_bit:, statics: {}, comment: nil)
        @min_float = min_float
        @max_float = max_float
        super(key: key, nb_bit: nb_bit, statics: statics, comment: comment)
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
    def initialize(key:, nb_bytes:, statics: {}, comment: nil)
        super(key: key, nb_bit: nb_bytes * 8, statics: statics, comment: comment)
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
    def initialize(key:, target_key:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
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
    def initialize(key:, bits_segement:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
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
    def initialize(key:, keys:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
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
    def initialize(key:, item_key:, nb_item_max: nil, nb_bit: nil, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
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

    def initialize(key:, statics: {}, comment: nil, nb_bit_binary_key: nil, binary_keys:, prefix_keys: [])
        super(key: key, statics: statics, comment: comment)
        @nb_bit_binary_key = nb_bit_binary_key || Math.log2(@binary_keys.size).ceil
        @binary_keys = binary_keys
        @prefix_keys = prefix_keys
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
        @prefix_codecs = @prefix_keys.collect do |prefix_key|
            codec = codecs.key_2_codec(prefix_key) || raise("Codec #{prefix_key} not found for adding prefix key")
            raise("Prefix codec #{prefix_key} must be CodecFixLength") unless codec.is_a?(CodecFixLength)
            codec
        end
    end

    def serialize(bit_stream, value , is_last: true)
        raise "Expecting a Hash for value" unless value.is_a?(Hash)
        raise "Expecting the following key: #{@prefix_keys.join(', ')}" unless @prefix_keys.all? { |prefix_key| value.key?(prefix_key) }
        xor_key = value.keys.find { |k| @option_keys.include?(k) }
        raise "Expecting a key among #{@option_keys}" unless xor_key
        
        xor_value = value[xor_key]
        xor_bkey = @key_2_bkey[xor_key]
        raise "Unknown option key #{xor_key.inspect} for XOR serialization" if xor_bkey.nil?
        bit_stream.write_bits(xor_bkey, @nb_bit_binary_key)

        @prefix_codecs.each { |prefix_codec| prefix_codec.serialize(bit_stream, value[prefix_codec.key], is_last: false) }
        xor_codec = @codecs.key_2_codec(xor_key)
        xor_codec.serialize(bit_stream, xor_value, is_last: is_last)
    end

    def deserialize(bit_stream)
        xor_bkey = bit_stream.read_bits(@nb_bit_binary_key)
        xor_codec = @bkey_2_codec[xor_bkey]
        raise "Unknown binary key #{xor_bkey} during XOR deserialization" if xor_codec.nil?
        h = {}
        @prefix_codecs.each { |prefix_codec| h[prefix_codec.key] = prefix_codec.deserialize(bit_stream) }
        h[xor_codec.key] = xor_codec.deserialize(bit_stream)
        h
    end

    def to_s
        "#{super} options=#{@option_keys.join(', ')} prefixes=#{@prefix_keys.join(', ')}"
    end

    private

    def add_codec(codec:, binary_key:)
        @bkey_2_codec[binary_key] = codec
        @key_2_bkey[codec.key] = binary_key
    end

end

# List
class CodecList < CodecComposite
    def initialize(key:, item_key:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @item_key = item_key
    end

    def post_initialize(codecs)
        super(codecs)
        @item_codec = @codecs.key_2_codec(@item_key)
        raise "Item codec #{@item_key} not found for list #{@key}" if @item_codec.nil?
        @item_codec.safe_for_list?
        @nb_bit_binary_key = @item_codec.nb_bit_binary_key
    end

    def serialize(bit_stream, item_values, is_last: true)
        raise "Expecting an array value for list #{@key}" unless item_values.is_a?(Array)
        last_index = item_values.size - 1
        item_values.each_with_index do |item_value, index|
            @item_codec.serialize(bit_stream, item_value, is_last: index == last_index && is_last)
        end
        bit_stream.write_bits(0x0, @nb_bit_binary_key) unless is_last
        super(bit_stream, item_values, is_last: is_last)
    end

    def deserialize(bit_stream, result: [])
        return result if is_end_of_list?(bit_stream)
        result << @item_codec.deserialize(bit_stream)
        deserialize(bit_stream, result: result)
    end

    private

    def is_end_of_list?(bit_stream)
        value = begin
            bit_stream.read_bits(@nb_bit_binary_key, dry_run: true)
        rescue Json2Bits::NoMoreBitsError
            return true  # No more bits, end of list
        end

        if value == 0x0
            bit_stream.read_bits(@nb_bit_binary_key)  # Consume the terminator
            true
        else
            false
        end
    end

end


class Codecs

    attr_reader :dictionnary

    def initialize
        @dictionnary = {}
    end

    def serialize_to_bytes(key, value, compute_nb_bit: false)
        key_2_codec(key).serialize_to_bytes(value, compute_nb_bit: compute_nb_bit)
    end

    def deserialize_from_bytes(key, bytes)
        key_2_codec(key).deserialize_from_bytes(bytes)
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

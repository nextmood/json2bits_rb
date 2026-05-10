require 'time'

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

    def integer_encoding_little_endian? = @codecs.integer_encoding_little_endian?

    def fix_length? = false

    def to_s
        "#{self.class} #{@key}"
    end

    def descriptor
        s = statics.transform_keys(&:to_sym)
        s[:unit] = Codec.extract_unit_from_format(s[:format]) if s[:format]
        s.merge(key: @key, comment: comment)
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


    def self.extract_unit_from_format(format)
        return nil unless format.is_a?(String)
        # format follows sprintf style, for example
        # - format="%dms" -> unit is "ms"
        # - format="%.2f°C" -> unit is "°C"
        # - format="%d" -> no unit
        # - format="%.1f%%" -> unit is "%"
        unit = format[/^%[-+ #0]*\d*(?:\.\d+)?[a-zA-Z](.+)$/, 1]
        unit&.gsub('%%', '%')
    end

end

class CodecFixLength < Codec
    def initialize(key:, nb_bit:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @nb_bit = nb_bit
    end

    def eol_nb_bit = @nb_bit

    def fix_length? = true

    def to_s
        "#{super} nb_bit=#{@nb_bit}"
    end

end

# Emits no payload (0 bits); useful as a marker or placeholder
class CodecVoid < CodecFixLength
    def initialize(key:, statics: {}, comment: nil)
        super(key: key, nb_bit: 0, statics: statics, comment: comment)
    end

    def descriptor
        super.merge(type: :void)
    end

    def deserialize(bit_stream)
        nil
    end
end

# Unsigned integer encoded on a fixed number of bits (1-64)
class CodecInteger < CodecFixLength
    def initialize(key:, max_integer: nil, nb_bit: nil, statics: {}, comment: nil)
        nb_bit ||= Math.log2(max_integer + 1).ceil
        raise "nb_bit must be greater than 0 and less than or equal to 64" if nb_bit < 1 || nb_bit > 64
        @max_integer ||= (2 ** nb_bit) - 1
        super(key: key, nb_bit: nb_bit, statics: statics, comment: comment)
    end

    def descriptor
        super.merge(type: :integer, min:0, max: @max_integer)
    end

    def serialize(bit_stream, value, is_last: true)
        raise "Value #{value} exceeds maximum integer #{@max_integer}" if value > @max_integer
        if integer_encoding_little_endian? && @nb_bit > 8
            nb_full_bytes = @nb_bit / 8
            remaining_bits = @nb_bit % 8
            nb_full_bytes.times { |i| bit_stream.write_bits((value >> (8 * i)) & 0xFF, 8) }
            bit_stream.write_bits((value >> (8 * nb_full_bytes)) & ((1 << remaining_bits) - 1), remaining_bits) if remaining_bits > 0
        else
            bit_stream.write_bits(value, @nb_bit)
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        if integer_encoding_little_endian? && @nb_bit > 8
            nb_full_bytes = @nb_bit / 8
            remaining_bits = @nb_bit % 8
            result = nb_full_bytes.times.reduce(0) { |acc, i| acc | (bit_stream.read_bits(8) << (8 * i)) }
            result |= bit_stream.read_bits(remaining_bits) << (8 * nb_full_bytes) if remaining_bits > 0
            result
        else
            bit_stream.read_bits(@nb_bit)
        end
    end
end

class CodexDateTime < CodecFixLength
    # Milliseconds between Unix epoch (1970-01-01) and Y2K epoch (2000-01-01 UTC)
    Y2K_EPOCH_MS = 946_684_800_000

    def initialize(key:, statics: {}, comment: nil)
        # 48 bits can encode up to ~34.8 years from Y2K epoch in milliseconds
        super(key: key, nb_bit: 48, statics: statics, comment: comment)
    end

    def descriptor
        super.merge(type: :datetime)
    end

    def serialize(bit_stream, value, is_last: true)
        value = Time.parse(value) if value.is_a?(String)
        ms = value.to_i * 1000 + value.usec / 1000 - Y2K_EPOCH_MS
        6.times { |i| bit_stream.write_bits((ms >> (8 * i)) & 0xFF, 8) }
        bit_stream
    end

    def deserialize(bit_stream)
        ms = 6.times.reduce(0) { |acc, i| acc | (bit_stream.read_bits(8) << (8 * i)) }
        Time.at(Rational(ms + Y2K_EPOCH_MS, 1000)).utc
    end
end

# Single-bit boolean (true/false)
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
    
    def descriptor
        super.reject { |k, _| [:min, :max].include?(k) }.merge(type: :boolean)
    end
end

# Encodes a symbol from a predefined list as its index
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

    def descriptor
        super.merge(type: :symbol, symbols: @symbols)
    end
end

# Maps an integer range to a float interval [min, max]
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

    def descriptor
        super.merge(type: :float, min: @min_float, max: @max_float)
    end
end

# Raw byte data of fixed length
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

    def descriptor
        super.merge(type: :bytes, nb_bytes: @nb_bit / 8 )
    end
end

# Hex string representation of byte data (e.g., "a1b2c3")
class CodecHexa < CodecBytes
    def serialize(bit_stream, value, is_last: true)
        bytes = [value].pack("H*")
        super(bit_stream, bytes, is_last: is_last)
    end

    def deserialize(bit_stream)
        bytes = super(bit_stream)
        bytes.unpack1("H*")
    end

    def descriptor
        super.merge(type: :hexa)
    end
end

class CodecComposite < Codec
end

# References another codec under a different name
class CodecAlias < CodecComposite
    def initialize(key:, target_key:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @target_key = target_key
    end

    def post_initialize(codecs)
        super(codecs)
        @target_codec = @codecs.key_2_codec(@target_key)
        raise "Target codec #{@target_key} not found for alias #{@key}" if @target_codec.nil?
    end

    def eol_nb_bit = @target_codec.eol_nb_bit

    def fix_length? = @target_codec.fix_length?

    def serialize(bit_stream, value, is_last: true)
        @target_codec.serialize(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        @target_codec.deserialize(bit_stream)
    end

    def descriptor
        super.merge(type: :alias, item: @target_codec.descriptor)
    end

end

# Variable-length integer that selects the smallest segment able to hold the value
class CodecIntegerLong < CodecComposite
    def initialize(key:, bits_segment:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @bits_segment = bits_segment.sort.map { |nb_bit| [nb_bit, 2**nb_bit - 1] } 
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

    def descriptor
        super.merge(type: :integer, min: 0, max: @max_value)
    end

end

# Concatenates multiple codecs in order
class CodecSequence < CodecComposite
    def initialize(key:, keys:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @keys = keys
    end

    def serialize(bit_stream, value, is_last: true)
        last_codec = @sequence_codecs.last
        @sequence_codecs.each do |codec|
            codec.serialize(bit_stream, value.fetch(codec.key), is_last: codec == last_codec && is_last)
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        @sequence_codecs.each_with_object({}) do |codec, result|
            result[codec.key] = codec.deserialize(bit_stream)
        end
    end

    def post_initialize(codecs)
        super(codecs)
        @sequence_codecs = @keys.map { |key| @codecs.key_2_codec(key) }
    end

    def fix_length? = @sequence_codecs.all?(&:fix_length?)

    def to_s
        "#{super} [#{@keys.join(' -> ')}]"
    end

    def descriptor
        super.merge(type: :sequence, items: @sequence_codecs.map(&:descriptor))
    end

end

# Homogeneous array with length prefix
class CodecArray < CodecComposite
    def initialize(key:, item_key:, nb_item_max: nil, nb_bit: nil, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @item_key = item_key
        @counter_nb_bits = nb_bit || Math.log2(nb_item_max + 1).ceil
        @nb_item_max = 2**@counter_nb_bits - 1
    end

    def post_initialize(codecs)
        super(codecs)
        @item_codec = @codecs.key_2_codec(@item_key)
    end

    def serialize(bit_stream, value, is_last: true)
        nb_item = value.size
        bit_stream.write_bits(nb_item, @counter_nb_bits)
        last_item = value.last
        value.each do |item|
            @item_codec.serialize(bit_stream, item, is_last: item == last_item && is_last)
        end
        super(bit_stream, value, is_last: is_last)
    end

    def deserialize(bit_stream)
        nb_item = bit_stream.read_bits(@counter_nb_bits)
        nb_item.times.map { @item_codec.deserialize(bit_stream) }
    end
    
    def to_s
        "#{super} [#{@item_key}, ...] #{2**@counter_nb_bits -1} max items"
    end

    def descriptor
        super.merge(type: :array, item: @item_codec.descriptor, nb_item_max: @nb_item_max)
    end
end

# One-of choice between codecs, selected by a binary key prefix
class CodecXor < CodecComposite
    attr_reader :bkey_2_codec, :key_2_bkey

    def initialize(key:, statics: {}, comment: nil, nb_bit_binary_key: nil, binary_keys:, prefix_keys: [])
        super(key: key, statics: statics, comment: comment)
        @binary_keys = binary_keys
        @nb_bit_binary_key = nb_bit_binary_key || Math.log2(@binary_keys.size).ceil
        # Normalize: accept both {key:, except:} hashes (from parser) and plain strings (direct use)
        @prefix_keys_config = prefix_keys.map { |pk| pk.is_a?(Hash) ? pk : { key: pk, except: [] } }
        @max_type = 2 ** @nb_bit_binary_key
        @binary_keys.each do |k, bkey|
            raise "Binary key value #{bkey} exceeds maximum #{@max_type - 1}" if bkey >= @max_type
        end
        @option_keys = @binary_keys.keys
        @bkey_2_codec = {}
        @key_2_bkey = {}
    end

    def eol_nb_bit = @nb_bit_binary_key
        
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
        @prefix_codecs = @prefix_keys_config.map do |config|
            codec = codecs.key_2_codec(config[:key]) || raise("Codec #{config[:key]} not found for adding prefix key")
            raise("Prefix codec #{config[:key]} must be fix-length") unless codec.fix_length?
            { codec: codec, except: config[:except] }
        end
    end

    def serialize(bit_stream, value, is_last: true)
        raise "Expecting a Hash for value" unless value.is_a?(Hash)
        xor_key = value.keys.find { |k| @option_keys.include?(k) }
        raise "Expecting a key among #{@option_keys}" unless xor_key
        xor_bkey = @key_2_bkey[xor_key]
        raise "Unknown option key #{xor_key.inspect} for XOR serialization" if xor_bkey.nil?

        active_prefixes = @prefix_codecs.reject { |entry| entry[:except].include?(xor_bkey) }
        required_keys = active_prefixes.map { |entry| entry[:codec].key }
        raise "Expecting the following keys: #{required_keys.join(', ')}" unless required_keys.all? { |k| value.key?(k) }

        bit_stream.write_bits(xor_bkey, @nb_bit_binary_key)
        active_prefixes.each { |entry| entry[:codec].serialize(bit_stream, value[entry[:codec].key], is_last: false) }
        xor_codec = @codecs.key_2_codec(xor_key)
        xor_codec.serialize(bit_stream, value[xor_key], is_last: is_last)
    end

    def deserialize(bit_stream)
        xor_bkey = bit_stream.read_bits(@nb_bit_binary_key)
        xor_codec = @bkey_2_codec[xor_bkey]
        raise "Unknown binary key #{xor_bkey} during XOR deserialization" if xor_codec.nil?
        h = {}
        @prefix_codecs.each do |entry|
            next if entry[:except].include?(xor_bkey)
            h[entry[:codec].key] = entry[:codec].deserialize(bit_stream)
        end
        h[xor_codec.key] = xor_codec.deserialize(bit_stream)
        h
    end

    def to_s
        prefix_info = @prefix_keys_config.map do |pk|
            pk[:except].empty? ? pk[:key] : "#{pk[:key]}[except:#{pk[:except].map { |b| '0x%02x' % b }.join(';')}]"
        end
        "#{super} options=#{@option_keys.join(', ')} prefixes=#{prefix_info.join(', ')}"
    end

    def descriptor
        keys_to_descriptor = @bkey_2_codec.each_with_object({}) do |(bkey, codec), h|
            h[codec.key] = codec.descriptor.merge(bkey: bkey)
        end
        prefix_descriptors = @prefix_codecs.map { |entry| entry[:codec].descriptor.merge(except: entry[:except]) }
        super.merge(type: :xor, keys_to_descriptor:, prefix_descriptors:)
    end

    private

    def add_codec(codec:, binary_key:)
        @bkey_2_codec[binary_key] = codec
        @key_2_bkey[codec.key] = binary_key
    end

end

# Heterogeneous list using a XOR codec; uses 0x00 as end-of-list terminator
class CodecList < CodecComposite
    def initialize(key:, item_key:, statics: {}, comment: nil)
        super(key: key, statics: statics, comment: comment)
        @item_xor_key = item_key # an XOR key is expected
    end

    def post_initialize(codecs)
        super(codecs)
        @item_xor_codec = @codecs.key_2_codec(@item_xor_key)
        raise "Item codec #{@item_xor_key} not found for list #{@key}" if @item_xor_codec.nil?
        @item_xor_codec.safe_for_list?
        @eol_nb_bit = @item_xor_codec.eol_nb_bit
    end

    def serialize(bit_stream, item_values, is_last: true)
        raise "Expecting an array value for list #{@key}" unless item_values.is_a?(Array)
        last_index = item_values.size - 1
        item_values.each_with_index do |item_value, index|
            @item_xor_codec.serialize(bit_stream, item_value, is_last: index == last_index && is_last)
        end
        bit_stream.write_bits(0x0, @eol_nb_bit) unless is_last
        super(bit_stream, item_values, is_last: is_last)
    end

    def deserialize(bit_stream, result: [])
        return result if is_end_of_list?(bit_stream)
        result << @item_xor_codec.deserialize(bit_stream)
        deserialize(bit_stream, result: result)
    end

    def descriptor
        super.merge(type: :xor_list_item, item_descriptor: @item_xor_codec.descriptor)
    end

    private

    def is_end_of_list?(bit_stream)
        value = begin
            bit_stream.read_bits(@eol_nb_bit, dry_run: true)
        rescue Json2Bits::NoMoreBitsError
            return true  # No more bits, end of list
        end

        if value == 0x0
            bit_stream.read_bits(@eol_nb_bit)  # Consume the terminator
            true
        else
            false
        end
    end

end


class Codecs

    attr_reader :dictionnary

    # endian is only used for CodecInteger (and any subclasses) with more than 8 bits
    def initialize(globals: {})
        @dictionnary = {}
        @globals = {"endian" => "big"}.merge(globals)
    end

    def integer_encoding_little_endian? = @globals["endian"] == "little"

    def globals(key) = @globals[key]

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

    def key_2_codec(key) = @dictionnary[key]

    def descriptor(key) = key_2_codec(key).descriptor
    
    def descriptors = @dictionnary.transform_values(&:descriptor)

    def to_s
        s = @dictionnary.map do |key, codec|
            "\n- #{codec}"
        end.join(", ")
        "#{self.class} nb_codec=#{@dictionnary.size}#{s}"
    end

end

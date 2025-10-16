module Json2Bits
  class Serializer
    attr_reader :configuration

    def initialize(configuration)
      @configuration = configuration
    end

    NO_VALUE = Object.new.freeze

    def serialize(definition_or_data, value = NO_VALUE)
      if value.equal?(NO_VALUE)
        if definition_key?(definition_or_data)
          raise ArgumentError, "value is required when serializing a definition"
        end

        serialize_message(definition_or_data)
      else
        serialize_single(definition_or_data, value)
      end
    end

    def deserialize(definition_key_or_bytes, bytes = nil)
      if bytes.nil?
        deserialize_message(definition_key_or_bytes)
      else
        deserialize_single(definition_key_or_bytes, bytes)
      end
    end

    private

    def serialize_single(definition_key, value)
      definition = configuration.definition(definition_key)

      if value.is_a?(Hash) && (value.key?(definition.name) || value.key?(definition.name.to_sym))
        raise ArgumentError, "value for #{definition.name} should not include the definition key"
      end

      fragment = { definition.name => value }
      writer = BitWriter.new
      definition.encode_fragment(writer, fragment)
      [writer.to_bytes, writer.size]
    end

    def serialize_message(data)
      fragments = normalize_fragments(data)
      writer = BitWriter.new

      fragments.each do |fragment|
        definition = configuration.detect_definition(fragment)
        raise SerializationError, "Unable to infer definition for #{fragment.inspect}" unless definition

        writer.write_bits(definition.binary_key, configuration.key_bit_size)
        definition.encode_fragment(writer, fragment)
      end

      [writer.to_bytes, writer.size]
    end

    def deserialize_single(definition_key, bytes)
      definition = configuration.definition(definition_key)
      reader = BitReader.new(normalize_bytes(bytes))
      definition.decode_fragment(reader)
    end

    def deserialize_message(bytes)
      fragments = []
      reader = BitReader.new(normalize_bytes(bytes))

      while reader.remaining_bits >= configuration.key_bit_size
        binary_key = reader.read_bits(configuration.key_bit_size)
        definition = configuration.definition_for_binary_key(binary_key)

        break if definition.nil? && binary_key.zero?
        raise DeserializationError, format("Unknown binary key 0x%0X", binary_key) unless definition

        fragments << definition.decode_fragment(reader)
      end

      fragments
    end

    def normalize_bytes(bytes)
      case bytes
      when String
        bytes
      when Array
        bytes.pack("C*")
      else
        raise ArgumentError, "bytes must be String or Array, got #{bytes.inspect}"
      end
    end

    def normalize_fragments(data)
      case data
      when Array
        data
      when Hash
        [data]
      else
        raise SerializationError, "Message must be Array or Hash, got #{data.inspect}"
      end
    end

    def definition_key?(candidate)
      return false unless candidate.is_a?(String) || candidate.is_a?(Symbol)

      configuration.definition?(candidate)
    end
  end
end

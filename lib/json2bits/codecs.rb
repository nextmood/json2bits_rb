module Json2Bits
  module Codecs
    module Helpers
      module_function

      def ensure_hash_like(value)
        unless value.respond_to?(:[])
          raise SerializationError, "expected hash-like structure, got #{value.inspect}"
        end
      end

      def fetch_from_record(record, key)
        if record.respond_to?(:key?) && record.key?(key)
          record[key]
        elsif record.respond_to?(:key?) && record.key?(key.to_sym)
          record[key.to_sym]
        elsif record.respond_to?(:[])
          record[key] || record[key.to_sym]
        end
      end

      def normalize_symbol(value)
        case value
        when Symbol then value.to_s
        else value
        end
      end

      def message_token?(name)
        name.to_s == "message"
      end
    end

    module MessageSupport
      module_function

      def write_message(writer, value, configuration, terminate: true)
        fragments = normalize_fragments(value)
        message_writer = BitWriter.new

        fragments.each do |fragment|
          definition = configuration.detect_definition(fragment)
          raise SerializationError, "Unable to infer definition for nested message fragment #{fragment.inspect}" unless definition

          message_writer.write_bits(definition.binary_key, configuration.key_bit_size)
          definition.encode_fragment(message_writer, fragment)
        end

        writer.write_bitstring(message_writer.bits)

        if terminate && configuration.definition_for_binary_key(0).nil? && configuration.key_bit_size.positive?
          writer.write_bits(0, configuration.key_bit_size)
        end
      end

      def read_message(reader, configuration)
        fragments = []

        while reader.remaining_bits >= configuration.key_bit_size
          binary_key = reader.read_bits(configuration.key_bit_size)
          definition = configuration.definition_for_binary_key(binary_key)

          break if definition.nil? && binary_key.zero?
          raise DeserializationError, format("Unknown binary key 0x%0X in nested message", binary_key) unless definition

          fragments << definition.decode_fragment(reader)
        end

        fragments
      end

      def normalize_fragments(value)
        case value
        when Array then value
        when Hash then [value]
        else
          raise SerializationError, "message expects Array or Hash, got #{value.inspect}"
        end
      end
    end

    def self.build(ast, configuration, current_definition)
      type = ast.fetch(:type)
      args = ast.fetch(:args)

      case type
      when :static
        Static.new(args.first)
      when :boolean
        Boolean.new
      when :integer
        IntegerCodec.new(Integer(args.fetch(0)))
      when :float
        bit_length = Integer(args.fetch(0))
        min = Float(args.fetch(1))
        max = Float(args.fetch(2))
        FloatCodec.new(bit_length, min, max)
      when :bytes
        Bytes.new(Integer(args.fetch(0)))
      when :hexa
        Hexa.new(Integer(args.fetch(0)))
      when :symbol
        values = args.map { |value| Helpers.normalize_symbol(value).to_s }
        SymbolCodec.new(values)
      when :void
        Void.new
      when :sequence
        definition_names = args.map { |arg| arg.to_s }
        Sequence.new(definition_names, configuration)
      when :alias
        Alias.new(args.first.to_s, configuration)
      when :array
        bit_size = Integer(args.shift)
        definition_names = args.map { |arg| arg.to_s }
        ArrayCodec.new(bit_size, definition_names, configuration)
      when :xor
        if args.length == 1 && args.first.to_s == "*"
          definition_names = configuration.definitions.map(&:name).map(&:to_s)
          definition_names.reject! { |name| current_definition && name == current_definition.name }
          Xor.new(definition_names, configuration, allow_all: true)
        else
          definition_names = args.map { |arg| arg.to_s }
          Xor.new(definition_names, configuration)
        end
      else
        raise ConfigurationError, "Unknown codec type #{type.inspect}"
      end
    end

    class Base
      def write(_writer, _value, _configuration)
        raise NotImplementedError, "#{self.class} must implement #write"
      end

      def read(_reader, _configuration)
        raise NotImplementedError, "#{self.class} must implement #read"
      end
    end

    class Static < Base
      def initialize(value = true)
        @value = value.nil? ? true : value
      end

      def write(_writer, value, _configuration)
        unless value.nil? || value == @value
          raise SerializationError, "static codec expects #{@value.inspect}, got #{value.inspect}"
        end
      end

      def read(_reader, _configuration)
        @value
      end
    end

    class Boolean < Base
      def write(writer, value, _configuration)
        case value
        when true, 1 then writer.write_bool(true)
        when false, 0 then writer.write_bool(false)
        else
          raise SerializationError, "BOOLEAN expects true/false, got #{value.inspect}"
        end
      end

      def read(reader, _configuration)
        reader.read_bool
      end
    end

    class IntegerCodec < Base
      def initialize(bit_length)
        @bit_length = bit_length
        @max = (1 << bit_length) - 1
      end

      def write(writer, value, _configuration)
        integer = coerce_to_integer(value)
        unless (0..@max).cover?(integer)
          raise SerializationError, "INTEGER(#{@bit_length}) out of range: #{integer}"
        end

        writer.write_bits(integer, @bit_length)
      end

      def read(reader, _configuration)
        reader.read_bits(@bit_length)
      end

      private

      def coerce_to_integer(value)
        Integer(value)
      rescue ArgumentError, TypeError
        raise SerializationError, "INTEGER expects numeric value, got #{value.inspect}"
      end
    end

    class FloatCodec < Base
      def initialize(bit_length, min_value, max_value)
        raise ConfigurationError, "FLOAT max must be greater than min" if max_value <= min_value

        @bit_length = bit_length
        @min = min_value
        @max = max_value
        @max_int = (1 << bit_length) - 1
      end

      def write(writer, value, _configuration)
        numeric = Float(value)
        unless numeric >= @min && numeric <= @max
          raise SerializationError, "FLOAT(#{@bit_length};#{@min};#{@max}) out of range: #{numeric}"
        end

        ratio = (numeric - @min) / (@max - @min)
        encoded = (ratio * @max_int).round
        encoded = [[encoded, 0].max, @max_int].min
        writer.write_bits(encoded, @bit_length)
      rescue ArgumentError, TypeError
        raise SerializationError, "FLOAT expects numeric, got #{value.inspect}"
      end

      def read(reader, _configuration)
        encoded = reader.read_bits(@bit_length)
        ratio = encoded.to_f / @max_int
        (@min + ratio * (@max - @min))
      end
    end

    class Bytes < Base
      def initialize(byte_length)
        @byte_length = byte_length
      end

      def write(writer, value, _configuration)
        bytes = normalize(value)
        writer.write_bytes(bytes)
      end

      def read(reader, _configuration)
        Array.new(@byte_length) { reader.read_bits(8) }
      end

      private

      def normalize(value)
        case value
        when String
          string_to_bytes(value)
        when Array
          array_to_bytes(value)
        else
          raise SerializationError, "BYTES expects String or Array, got #{value.inspect}"
        end
      end

      def string_to_bytes(value)
        if value.start_with?("0x") || value.start_with?("0X")
          hex = value.delete_prefix("0x").delete_prefix("0X")
          raise SerializationError, "BYTES expects #{@byte_length} bytes, got #{hex.length / 2}" if hex.length != @byte_length * 2
          [hex].pack("H*")
        else
          raw = value.dup.force_encoding(Encoding::BINARY)
          raise SerializationError, "BYTES expects #{@byte_length} bytes, got #{raw.bytesize}" unless raw.bytesize == @byte_length
          raw
        end
      end

      def array_to_bytes(array)
        unless array.length == @byte_length
          raise SerializationError, "BYTES expects #{@byte_length} entries, got #{array.length}"
        end

        array.each do |byte|
          unless byte.is_a?(Integer) && byte >= 0 && byte <= 0xFF
            raise SerializationError, "BYTES entries must be integers 0..255, got #{byte.inspect}"
          end
        end

        array.pack("C*")
      end
    end

    class Hexa < Base
      def initialize(byte_length)
        @byte_length = byte_length
        @bytes_codec = Bytes.new(byte_length)
      end

      def write(writer, value, configuration)
        bytes = normalize(value)
        @bytes_codec.write(writer, bytes, configuration)
      end

      def read(reader, configuration)
        bytes = @bytes_codec.read(reader, configuration)
        format("0x%0#{@byte_length * 2}X", bytes.inject(0) { |acc, byte| (acc << 8) | byte })
      end

      private

      def normalize(value)
        case value
        when String
          if value.start_with?("0x") || value.start_with?("0X")
            hex = value.delete_prefix("0x").delete_prefix("0X")
            raise SerializationError, "HEXA expects #{@byte_length} bytes, got #{hex.length / 2}" unless hex.length == @byte_length * 2
            [hex].pack("H*")
          else
            raw = value.dup.force_encoding(Encoding::BINARY)
            raise SerializationError, "HEXA expects #{@byte_length} bytes, got #{raw.bytesize}" unless raw.bytesize == @byte_length
            raw
          end
        when Array
          unless value.length == @byte_length
            raise SerializationError, "HEXA expects #{@byte_length} bytes, got #{value.length}"
          end

          value.pack("C*")
        else
          raise SerializationError, "HEXA expects hex string or bytes, got #{value.inspect}"
        end
      end
    end

    class SymbolCodec < Base
      def initialize(values)
        raise ConfigurationError, "SYMBOL expects at least one value" if values.empty?

        @values = values.freeze
        @bits = if values.length <= 1
                  0
                else
                  Math.log2(values.length).ceil
                end
      end

      def write(writer, value, _configuration)
        normalized = Helpers.normalize_symbol(value).to_s
        index = @values.index(normalized)
        raise SerializationError, "value #{value.inspect} not part of SYMBOL #{@values.inspect}" unless index

        writer.write_bits(index, @bits) if @bits.positive?
      end

      def read(reader, _configuration)
        index = @bits.positive? ? reader.read_bits(@bits) : 0
        @values.fetch(index)
      end
    end

    class Void < Base
      def write(_writer, value, _configuration)
        unless value.nil? || value == true
          raise SerializationError, "VOID expects true or nil, got #{value.inspect}"
        end
      end

      def read(_reader, _configuration)
        true
      end
    end

    class Sequence < Base
      def initialize(definition_names, configuration)
        raise ConfigurationError, "SEQUENCE expects at least two definitions" if definition_names.length < 2

        @definition_names = definition_names
        @configuration = configuration
        if definition_names.count { |name| Helpers.message_token?(name) } > 1
          raise ConfigurationError, "SEQUENCE supports at most one message placeholder"
        end
        if definition_names.any? { |name| Helpers.message_token?(name) } && !Helpers.message_token?(definition_names.last)
          raise ConfigurationError, "message placeholder must be the last entry in SEQUENCE"
        end
      end

      def write(writer, value, configuration)
        @definition_names.each_with_index do |definition_name, index|
          component_value = extract_component(value, definition_name, index)
          if Helpers.message_token?(definition_name)
            MessageSupport.write_message(writer, component_value, configuration, terminate: false)
          else
            definition = configuration.definition(definition_name)
            definition.codec.write(writer, component_value, configuration)
          end
        end
      end

      def read(reader, configuration)
        result = {}
        @definition_names.each do |definition_name|
          if Helpers.message_token?(definition_name)
            result["message"] = MessageSupport.read_message(reader, configuration)
          else
            definition = configuration.definition(definition_name)
            result[definition_name] = definition.codec.read(reader, configuration)
          end
        end
        result
      end

      private

      def extract_component(record, name, index)
        case record
        when Hash
          fetch_component(record, name)
        when Array
          record.fetch(index)
        else
          Helpers.ensure_hash_like(record)
          fetch_component(record, name)
        end
      rescue KeyError
        raise SerializationError, "Missing value for #{name} in SEQUENCE"
      end

      def fetch_component(record, name)
        value = Helpers.fetch_from_record(record, name)
        return value unless value.nil?

        raise SerializationError, "Missing value for #{name}"
      end
    end

    class Alias < Base
      def initialize(definition_name, configuration)
        @definition_name = definition_name
        @configuration = configuration
      end

      def write(writer, value, configuration)
        definition.codec.write(writer, value, configuration)
      end

      def read(reader, configuration)
        definition.codec.read(reader, configuration)
      end

      private

      def definition
        @definition ||= @configuration.definition(@definition_name)
      end
    end

    class ArrayCodec < Base
      def initialize(length_bits, definition_names, configuration)
        raise ConfigurationError, "ARRAY expects at least one nested definition" if definition_names.empty?

        @length_bits = length_bits
        @definition_names = definition_names
        @configuration = configuration
        @max_length = (1 << length_bits) - 1
        if definition_names.count { |name| Helpers.message_token?(name) } > 1
          raise ConfigurationError, "ARRAY supports at most one message placeholder per element"
        end
        if definition_names.length > 1 && definition_names.any? { |name| Helpers.message_token?(name) } && !Helpers.message_token?(definition_names.last)
          raise ConfigurationError, "message placeholder must be the last entry in ARRAY element definition"
        end
      end

      def write(writer, value, configuration)
        array = value.is_a?(Array) ? value : raise(SerializationError, "ARRAY expects Array, got #{value.inspect}")
        raise SerializationError, "ARRAY length #{array.length} exceeds #{@max_length}" if array.length > @max_length

        writer.write_bits(array.length, @length_bits)
        array.each do |element|
          encode_element(writer, element, configuration)
        end
      end

      def read(reader, configuration)
        length = reader.read_bits(@length_bits)
        Array.new(length) do
          decode_element(reader, configuration)
        end
      end

      private

      def encode_element(writer, element, configuration)
        if @definition_names.length == 1 && Helpers.message_token?(@definition_names.first)
          MessageSupport.write_message(writer, element, configuration)
        elsif @definition_names.length == 1
          definition = configuration.definition(@definition_names.first)
          value = extract_single_value(element, definition.name)
          definition.codec.write(writer, value, configuration)
        else
          Helpers.ensure_hash_like(element)
          @definition_names.each do |definition_name|
            definition = configuration.definition(definition_name)
            value = Helpers.fetch_from_record(element, definition_name)
            raise SerializationError, "Missing #{definition_name} in ARRAY element" if value.nil?
            definition.codec.write(writer, value, configuration)
          end
        end
      end

      def decode_element(reader, configuration)
        if @definition_names.length == 1 && Helpers.message_token?(@definition_names.first)
          MessageSupport.read_message(reader, configuration)
        elsif @definition_names.length == 1
          definition = configuration.definition(@definition_names.first)
          definition.codec.read(reader, configuration)
        else
          @definition_names.each_with_object({}) do |definition_name, acc|
            if Helpers.message_token?(definition_name)
              acc["message"] = MessageSupport.read_message(reader, configuration)
            else
              definition = configuration.definition(definition_name)
              acc[definition_name] = definition.codec.read(reader, configuration)
            end
          end
        end
      end

      def extract_single_value(element, name)
        if element.is_a?(Hash)
          value = Helpers.fetch_from_record(element, name)
          return value unless value.nil?

          raise SerializationError, "ARRAY element missing #{name}"
        end

        element
      end
    end

    class Xor < Base
      def initialize(definition_names, configuration, allow_all: false)
        @definition_names = definition_names.map(&:to_s).uniq
        if @definition_names.empty?
          raise ConfigurationError, allow_all ? "XOR(*) requires at least one other definition" : "XOR expects at least one definition"
        end

        # Ensure referenced definitions exist; this also fails fast for typos.
        @definition_names.each do |name|
          next if Helpers.message_token?(name)
          configuration.definition(name)
        rescue ConfigurationError
          raise ConfigurationError, "Unknown definition #{name} referenced in XOR#{allow_all ? '(*)' : ''}"
        end

        @configuration = configuration
        @bits = if @definition_names.length <= 1
                  0
                else
                  Math.log2(@definition_names.length).ceil
                end
      end

      def write(writer, value, configuration)
        index, payload = resolve_selection(value)
        writer.write_bits(index, @bits) if @bits.positive?
        definition_name = @definition_names.fetch(index)
        if Helpers.message_token?(definition_name)
          MessageSupport.write_message(writer, payload, configuration, terminate: false)
        else
          definition = configuration.definition(definition_name)
          definition.codec.write(writer, payload, configuration)
        end
      end

      def read(reader, configuration)
        index = @bits.positive? ? reader.read_bits(@bits) : 0
        definition_name = @definition_names.fetch(index)
        if Helpers.message_token?(definition_name)
          { "message" => MessageSupport.read_message(reader, configuration) }
        else
          definition = configuration.definition(definition_name)
          { definition_name => definition.codec.read(reader, configuration) }
        end
      end

      private

      def resolve_selection(value)
        case value
        when Hash
          key = find_selected_key(value)
          index = @definition_names.index(key)
          raise SerializationError, "Invalid XOR option #{key}" unless index
          [index, Helpers.fetch_from_record(value, key)]
        when Array
          raise SerializationError, "XOR expects [name, value] pair" unless value.length == 2
          name = value.first.to_s
          index = @definition_names.index(name)
          raise SerializationError, "Invalid XOR option #{name}" unless index
          [index, value.last]
        else
          raise SerializationError, "XOR expects hash-like input, got #{value.inspect}"
        end
      end

      def find_selected_key(hash)
        keys = @definition_names.select do |name|
          !Helpers.fetch_from_record(hash, name).nil?
        end

        case keys.length
        when 1
          keys.first
        when 0
          raise SerializationError, "XOR requires exactly one key to be set"
        else
          raise SerializationError, "XOR expects one active key, got #{keys}"
        end
      end
    end
  end
end

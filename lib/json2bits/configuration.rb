module Json2Bits
  class Configuration
    DEFAULT_KEY_BIT_SIZE = 8

    attr_reader :key_bit_size

    def initialize(key_bit_size:, definitions:)
      @key_bit_size = key_bit_size
      @definitions = {}
      @definitions_by_binary = {}

      definitions.each do |definition|
        register_definition(definition)
      end

      @definitions.each_value do |definition|
        definition.finalize!(self)
      end
    end

    def self.parse(text)
      parser = Parser.new(text)
      data = parser.parse
      new(key_bit_size: data.fetch(:key_bit_size), definitions: data.fetch(:definitions))
    end

    def definition(name)
      @definitions.fetch(name.to_s) do
        raise ConfigurationError, "Unknown definition #{name}"
      end
    end

    def definition_by_binary_key(key)
      definition_for_binary_key(key) || raise(DeserializationError, format("Unknown binary key 0x%0X", key))
    end

    def definition_for_binary_key(key)
      @definitions_by_binary[key]
    end

    def definition?(name)
      @definitions.key?(name.to_s)
    end

    def detect_definition(fragment)
      return nil unless fragment.respond_to?(:keys)

      fragment.keys.each do |key|
        key_str = key.to_s
        next if !@definitions.key?(key_str) || fragment_value_nil?(fragment, key)

        return @definitions[key_str]
      end
      nil
    end

    def definitions
      @definitions.values
    end

    def size
      @definitions.size
    end

    private

    def register_definition(definition)
      name = definition.name
      binary = definition.binary_key
      max_binary = (1 << key_bit_size) - 1

      raise ConfigurationError, "Binary key #{format('0x%02X', binary)} exceeds #{key_bit_size} bits" if binary > max_binary
      raise ConfigurationError, "Duplicate definition #{name}" if @definitions.key?(name)
      if @definitions_by_binary.key?(binary)
        raise ConfigurationError, format("Binary key 0x%02X already used by %s", binary, @definitions_by_binary[binary].name)
      end

      @definitions[name] = definition
      @definitions_by_binary[binary] = definition
    end

    def fragment_value_nil?(fragment, key)
      if fragment.respond_to?(:key?) && fragment.key?(key)
        fragment[key].nil?
      elsif fragment.respond_to?(:key?) && fragment.key?(key.to_sym)
        fragment[key.to_sym].nil?
      else
        false
      end
    end

    class Parser
      def initialize(text)
        @lines = text.to_s.lines
        @definitions = []
        @key_bit_size = nil
      end

      def parse
        @lines.each_with_index do |line, index|
          body, comment = split_comment(line)
          next if body.nil? || body.empty?

          if global_assignment?(body)
            parse_global(body)
          else
            parse_definition(body, comment, index + 1)
          end
        end

        {
          key_bit_size: @key_bit_size || DEFAULT_KEY_BIT_SIZE,
          definitions: @definitions
        }
      end

      private

      def split_comment(line)
        raw_body, raw_comment = line.split("//", 2)
        body = raw_body&.strip
        comment = raw_comment&.strip
        [body, comment]
      end

      def global_assignment?(text)
        text =~ /\A[A-Za-z0-9_]+\s*=/
      end

      def parse_global(text)
        key, value = text.split("=", 2)
        return unless value

        case key.strip
        when "nb_bit_key_binary", "key_binary_size_in_bit"
          @key_bit_size = Integer(value.strip)
        end
      end

      def parse_definition(text, comment, line_number)
        tokens = tokenize(text)
        return if tokens.empty?

        binary_key, name, tokens = extract_binary_and_name(tokens, line_number)
        return unless name

        codec_token = tokens.shift
        unless codec_token
          raise ConfigurationError, "Missing codec on line #{line_number}"
        end

        codec_ast = parse_codec(codec_token, line_number)
        static_fields = parse_static(tokens)

        @definitions << Definition.new(
          name: name,
          binary_key: binary_key,
          codec_ast: codec_ast,
          static_fields: static_fields,
          comment: comment
        )
      end

      def tokenize(text)
        text.scan(/\S+\([^)]*\)|\S+/)
      end

      def extract_binary_and_name(tokens, line_number)
        first = tokens.shift
        raise ConfigurationError, "Malformed definition on line #{line_number}" unless first

        if binary_token?(first)
          binary = parse_binary(first)
          name = tokens.shift
        else
          name = first
          second = tokens.shift
          if second && binary_token?(second)
            binary = parse_binary(second)
          else
            raise ConfigurationError, "Missing binary key for #{name} on line #{line_number}"
          end
        end

        [binary, name, tokens]
      end

      def binary_token?(token)
        token =~ /\A0x[0-9a-fA-F]+\z/ || token =~ /\A\d+\z/
      end

      def parse_binary(token)
        if token.start_with?("0x") || token.start_with?("0X")
          token.to_i(16)
        else
          token.to_i
        end
      end

      def parse_codec(token, line_number)
        if token =~ /\A([A-Za-z_]+)\((.*)\)\z/
          name = Regexp.last_match(1)
          args = parse_arguments(Regexp.last_match(2))
        else
          name = token
          args = []
        end

        {
          type: normalize_codec_name(name, line_number),
          args: args
        }
      end

      def normalize_codec_name(name, line_number)
        case name.upcase
        when "STATIC" then :static
        when "BOOLEAN" then :boolean
        when "INTEGER", "NUMERIC" then :integer
        when "FLOAT" then :float
        when "BYTES" then :bytes
        when "HEXA" then :hexa
        when "SYMBOL" then :symbol
        when "VOID" then :void
        when "SEQUENCE" then :sequence
        when "ALIAS" then :alias
        when "ARRAY" then :array
        when "XOR" then :xor
        else
          raise ConfigurationError, "Unknown codec #{name} on line #{line_number}"
        end
      end

      def parse_arguments(arguments)
        return [] if arguments.nil? || arguments.empty?

        arguments.split(/[;,]/).map { |entry| entry.strip }.reject(&:empty?).map do |entry|
          convert_value(entry)
        end
      end

      def parse_static(tokens)
        tokens.each_with_object({}) do |token, static|
          next if token.nil? || token.empty?

          if token =~ /\ASTATIC\((.*)\)\z/i
            inner = Regexp.last_match(1)
            parse_static_entries(inner, static)
          else
            parse_static_entries(token, static)
          end
        end
      end

      def parse_static_entries(text, static)
        text.split(/[;,]/).each do |entry|
          cleaned = entry.strip
          next if cleaned.empty?

          key, value = cleaned.split("=", 2)
          key = key.strip
          value = value ? convert_value(value.strip) : true
          static[key] = value
        end
      end

      def convert_value(raw)
        return true if raw.casecmp("true").zero?
        return false if raw.casecmp("false").zero?

        if raw =~ /\A-?\d+\z/
          raw.to_i
        elsif raw =~ /\A-?\d*\.\d+\z/
          raw.to_f
        else
          raw
        end
      end
    end
  end
end

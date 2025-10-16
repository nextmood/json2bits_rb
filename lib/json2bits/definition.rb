module Json2Bits
  class Definition
    attr_reader :name, :binary_key, :static_fields, :comment, :codec

    def initialize(name:, binary_key:, codec_ast:, static_fields:, comment:)
      @name = name
      @binary_key = binary_key
      @codec_ast = codec_ast
      @static_fields = static_fields.transform_keys(&:to_s).freeze
      @comment = comment
      @codec = nil
      @configuration = nil
    end

    def finalize!(configuration)
      @configuration = configuration
      @codec = Codecs.build(@codec_ast, configuration, self)
    end

    def encode_fragment(bit_writer, fragment)
      ensure_configuration!
      ensure_static_fields!(fragment)
      value = extract_value(fragment)
      codec.write(bit_writer, value, @configuration)
    end

    def decode_fragment(bit_reader)
      ensure_configuration!
      value = codec.read(bit_reader, @configuration)
      build_fragment(value)
    end

    def build_fragment(value)
      fragment = { name => value }
      static_fields.each { |key, static_value| fragment[key] = static_value }
      fragment
    end

    private

    def ensure_configuration!
      raise ConfigurationError, "definition #{name} not bound to configuration" unless @configuration
    end

    def ensure_static_fields!(fragment)
      static_fields.each do |key, expected|
        actual = fetch_key(fragment, key)
        next if actual.nil? || actual == expected

        raise SerializationError, "Static field #{key} expected #{expected.inspect}, got #{actual.inspect}"
      end
    end

    def extract_value(fragment)
      value = fetch_key(fragment, name)
      return value unless value.nil?

      available = fragment.respond_to?(:keys) ? fragment.keys.map(&:to_s) : []
      raise SerializationError, "Missing key #{name} in fragment (available: #{available.join(', ')})"
    end

    def fetch_key(fragment, key)
      if fragment.respond_to?(:key?) && fragment.key?(key)
        fragment[key]
      elsif fragment.respond_to?(:key?) && fragment.key?(key.to_sym)
        fragment[key.to_sym]
      elsif fragment.respond_to?(:[])
        fragment[key] || fragment[key.to_sym]
      end
    end
  end
end

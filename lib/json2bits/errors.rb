module Json2Bits
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class SerializationError < Error; end
  class DeserializationError < Error; end
end

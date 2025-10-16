module Json2Bits
  class Error < StandardError; end
  class NoMoreBitsError < Error; end
  class ConfigurationError < Error; end
  class SerializationError < Error; end
  class DeserializationError < Error; end
end

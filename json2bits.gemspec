require_relative "lib/json2bits/version"

Gem::Specification.new do |spec|
  spec.name          = "json2bits"
  spec.version       = Json2Bits::VERSION
  spec.authors       = ["nextmood"]
  spec.summary       = "Binary serializer/deserializer for JSON fragments based on a declarative configuration"
  spec.description   = "Implements codecs and message packing rules defined in a configuration file to convert between JSON data fragments and compact bit streams."
  spec.license       = "MIT"

  spec.files         = Dir.glob("lib/**/*") + Dir.glob("test/**/*") + ["json2bits.gemspec", "Rakefile"]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = "https://example.com/json2bits"

  spec.add_development_dependency "minitest", ">= 5.0"
end

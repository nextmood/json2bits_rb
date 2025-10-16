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

  spec.metadata["source_code_uri"] = "https://github.com/nextmood/json2bits_rb"

  spec.add_dependency "treetop", ">= 1.6.11"
  spec.add_development_dependency "minitest", "~> 5.14", ">= 5.14.4"
  spec.add_development_dependency "rake", "~> 12.3", ">= 12.3.3"
  spec.add_development_dependency "ostruct", "~> 0.3"
end

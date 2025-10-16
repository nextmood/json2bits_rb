# json2bits

`json2bits` turns hashes, arrays, and scalars into tightly packed bit streams and back. It ships with a tiny DSL (parsed with Treetop) so you can describe payload layouts once and reuse them in Ruby without writing custom serializers.

## Why json2bits?

- **Bit-level control** – every field declares its width, making the resulting frame deterministic.
- **Composable codecs** – sequences, arrays, XOR branches, aliases, and lists let you model real-world protocols.
- **Readable configs** – the configuration format is close to how firmware teams describe frames.
- **Round-trippable** – codecs expose `serialize_to_bytes` and `deserialize_from_bytes` to keep examples simple.

## Installation

Add the gem to your project:

```ruby
gem "json2bits", git: "https://github.com/nextmood/json2bits_rb.git"
```

Then install dependencies:

```bash
bundle install
```

Working locally? Point Bundler to your checkout instead:

```ruby
gem "json2bits", path: "/path/to/json2bits"
```


You can also build and install the gem manually:

```bash
gem build json2bits.gemspec
gem install json2bits-0.1.0.gem
```



## Quick start

Define your payload layout in plain text, parse it with the bundled Treetop parser, and use the resulting codecs to serialize and deserialize:

```ruby
require "json2bits"

config = <<~CFG
  longitude FLOAT(7;2.0;5.0)
  latitude FLOAT(7;40.0;42.0)
  position SEQUENCE(longitude;latitude)
  battery_percent FLOAT(8;0.0;100.0)
  battery_status SYMBOL(3;ok;charging;low)
  device_index INTEGER(4)
  measurement XOR(3;0x01:position;0x02:battery_percent;0x03:battery_status;0x04:device_index)
  measurements LIST_XOR(measurement)
CFG

parser = ConfiguratorParser.new
ast = parser.parse(config) or raise Json2Bits::ConfigurationError, parser.failure_reason
codecs = ast.value

# Keys coming from the parser are strings
measurements = codecs.key_2_codec("measurements")

payload = [
  { "battery_percent" => 80.0 },
  { "position" => { "longitude" => 5.0, "latitude" => 40.0 } },
  { "device_index" => 13 },
  { "battery_status" => "charging" },
  { "device_index" => 0 }
]

bytes = measurements.serialize_to_bytes(payload)
decoded = measurements.deserialize_from_bytes(bytes)

raise "Error while encoding/decoding" unless decoded == payload # => true
```

`LIST` codecs automatically prepend the binary key (here `0x01`) for each entry and append a terminator when they are not the last element of a parent sequence.

## Configuration format

Each line of the configuration describes one codec:

```
<key> <CODEC>(parameters) [// comment]
```

- Keys are alphanumeric (underscores allowed) and become strings when parsed.
- Comments start with `//`.
- `XOR` and `LIST_XOR` use explicit binary keys (`0xNN:key`) written on `nb_bit_binary_key` bits; `0x00` is reserved as the list terminator.

### Codec reference

| Codec | Syntax | Description |
| --- | --- | --- |
| `BOOLEAN` | `BOOLEAN` | Single bit boolean. |
| `INTEGER` | `INTEGER(nb_bit)` | Unsigned integer on `nb_bit` bits (1–64). |
| `INTEGER_LONG` | Ruby-only class that selects the smallest segment able to hold the value (see `CodecIntegerLong`). |
| `FLOAT` | `FLOAT(nb_bit;min;max)` | Maps an integer range to the float interval `[min, max]`. |
| `HEXA` | `HEXA(nb_bytes)` | Hex string backed by `nb_bytes` of data. |
| `SYMBOL` | `SYMBOL(nb_bit;v1;v2;...)` | Encodes the index of the symbol list on `nb_bit` bits. |
| `VOID` | `VOID` | Emits no payload; useful as a marker. |
| `SEQUENCE` | `SEQUENCE(key1;key2;...)` | Concatenates several codecs in order. |
| `ALIAS` | `ALIAS(target_key)` | Reuses another codec under a different name. |
| `ARRAY` | `ARRAY(nb_bit;item_key)` | Writes the array length on `nb_bit` bits, then encodes each item with `item_key`. |
| `XOR` | `XOR(nb_bit_binary_key;0xNN:key1;0xNN:key2;...)` | One-of choice between the given codecs, selected on `nb_bit_binary_key` bits. |
| `LIST_XOR` | `LIST_XOR(key_xor)` | Heterogeneous list that reuses a named `XOR` definition and appends a `0x00` terminator when not last. |

### Working with codecs directly

You can also instantiate codecs in Ruby without the DSL:

```ruby
codecs = Codecs.new
speed = codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 5))
altitude = codecs.add_codec(CodecInteger.new(key: :altitude, nb_bit: 9))
flight = codecs.add_codec(CodecSequence.new(key: :flight, keys: [:speed, :altitude]))

bytes = flight.serialize_to_bytes({ speed: 13, altitude: 341 })
flight.deserialize_from_bytes(bytes) # => {speed: 13, altitude: 341}
```

## Development

Run the test suite with:

```bash
bundle exec rake
bundle exec rake test TEST=test/configurator_test.rb
```

The fixtures in `test/` cover codec round-trips, the configuration parser, and list terminators; extend them to suit your protocol.

## License

This project is released under the MIT License. See `json2bits.gemspec` for details.

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
  measurement XOR(3;[0x01:position;0x02:battery_percent;0x03:battery_status;0x04:device_index])
  measurements LIST(measurement)
CFG

parser = ConfiguratorParser.new
ast = parser.parse(config) or raise Json2Bits::ConfigurationError, parser.failure_reason
statics, codecs = ast.value.values_at(:statics, :codecs)

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

`LIST` codecs automatically prepend the binary key for each entry and append a `0x00` terminator when they are not the last element of a parent sequence.

## Configuration format

Each line of the configuration describes one codec:

```
<key> <CODEC>(parameters) [// comment]
```

- Keys are alphanumeric (underscores allowed) and become strings when parsed.
- Comments start with `//`.
- `XOR` uses explicit binary keys (`0xNN:key`) written on `nb_bit_binary_key` bits; `0x00` is reserved as the list terminator.

### Codec reference

| Codec | Syntax | Description |
| --- | --- | --- |
| `BOOLEAN` | `BOOLEAN` | Single bit boolean. |
| `INTEGER` | `INTEGER(nb_bit)` | Unsigned integer on `nb_bit` bits (1–64). |
| `INTEGER_LONG` | Ruby-only class that selects the smallest segment able to hold the value (see `CodecIntegerLong`). |
| `FLOAT` | `FLOAT(nb_bit;min;max)` | Maps an integer range to the float interval `[min, max]`. |
| `BYTES` | `BYTES(nb_bytes)` | Raw byte data of fixed length. |
| `HEXA` | `HEXA(nb_bytes)` | Hex string backed by `nb_bytes` of data. |
| `SYMBOL` | `SYMBOL(nb_bit;v1;v2;...)` | Encodes the index of the symbol list on `nb_bit` bits. |
| `DATETIME` | `DATETIME` | UTC timestamp encoded as a 48-bit little-endian unsigned integer of milliseconds since 2000-01-01 00:00:00 UTC. Accepts a Ruby `Time` object; deserializes to a UTC `Time` with millisecond precision. |
| `VOID` | `VOID` | Emits no payload; useful as a marker. |
| `SEQUENCE` | `SEQUENCE(key1;key2;...)` | Concatenates several codecs in order. |
| `ALIAS` | `ALIAS(target_key)` | Reuses another codec under a different name. |
| `ARRAY` | `ARRAY(nb_bit;item_key)` | Writes the array length on `nb_bit` bits, then encodes each item with `item_key`. |
| `XOR` | `XOR(nb_bit_binary_key;[0xNN:key1;0xNN:key2;...])` | One-of choice between the given codecs, selected on `nb_bit_binary_key` bits. |
| `LIST` | `LIST(xor_key)` | Heterogeneous list using a named `XOR` codec. Appends a `0x00` terminator when not the last element in a sequence. |

### DATETIME example

`DATETIME` encodes a Ruby `Time` as 6 little-endian bytes of milliseconds since 2000-01-01 00:00:00 UTC, making it compact and firmware-friendly.

```ruby
config = <<~CFG
  nid       INTEGER(16)
  timestamp DATETIME
  signal    SEQUENCE(nid;timestamp)
CFG

parser = ConfiguratorParser.new
codecs = parser.parse(config).value

signal = codecs.key_2_codec("signal")

payload = { "nid" => 42, "timestamp" => Time.utc(2026, 2, 10, 13, 42, 4, 743_000) }

bytes   = signal.serialize_to_bytes(payload)
# => [0x00, 0x2a, 0xc7, 0xfe, 0xf9, 0xdc, 0xbf, 0x00]
#     |nid=42|  timestamp = 2026-02-10 13:42:04.743 UTC (little-endian 48-bit ms)

decoded = signal.deserialize_from_bytes(bytes)
# => {"nid"=>42, "timestamp"=>2026-02-10 13:42:04.743000000 UTC}
```

Timestamps before 2000-01-01 UTC are not supported. Sub-millisecond precision is truncated (not rounded).

### Global configuration

A `STATIC(...)` clause at the very first line of a configuration file sets global options that apply to all codecs in that file.

#### Integer byte order (`endian`)

Controls the byte order used by `INTEGER` (and all subclasses: `FLOAT`, `SYMBOL`) when the field is **wider than 8 bits**. Fields of 8 bits or fewer are unaffected — a single byte has no byte order.

| Value | Meaning |
| --- | --- |
| `big` | Most-significant byte first (default) |
| `little` | Least-significant byte first |

```
STATIC(endian=little)
nid     INTEGER(16)   // serialized LSB first: 0x0042 → [0x42, 0x00]
offset  INTEGER(12)   // 8 low bits first, then 4 high bits
```

When using the Ruby API directly, pass the option to `Codecs.new`:

```ruby
codecs = Codecs.new(globals: {"endian" => "little"})
codec  = codecs.add_codec(CodecInteger.new(key: :nid, nb_bit: 16))
codec.serialize_to_bytes(0x1234) # => [0x34, 0x12]
```

Note: `DATETIME` is always little-endian by design and is not affected by this setting.

### Static metadata

You can attach arbitrary metadata to any codec using the `STATIC` clause:

```
temperature FLOAT(4;0.0;100.0) STATIC(unit=celsius;precision=2;readonly)
```

Static values can be:
- **Strings**: `unit=celsius`
- **Integers**: `precision=2`
- **Floats**: `threshold=0.5`
- **Hexadecimal**: `mask=0xFF`
- **Booleans**: `enabled=true` or `enabled=false`
- **Flags** (no value defaults to `true`): `readonly`

Access the metadata via the `statics` attribute:

```ruby
codec = codecs.key_2_codec("temperature")
codec.statics # => {"unit" => "celsius", "precision" => 2, "readonly" => true}
```

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

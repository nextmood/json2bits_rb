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
| `XOR` | `XOR(nb_bit_binary_key;[0xNN:key1;0xNN:key2;...][;prefix1[except:0xNN;...];...])` | One-of choice between the given codecs, selected on `nb_bit_binary_key` bits. Optional prefix fields are serialized after the binary key and before the payload; each prefix can carry an `[except:0xNN;...]` clause to suppress it for specific binary keys. |
| `LIST` | `LIST(xor_key)` | Heterogeneous list using a named `XOR` codec. Appends a `0x00` terminator when not the last element in a sequence. |

### XOR prefix fields and `[except:]`

A `XOR` codec can declare shared prefix fields that are serialized between the binary key and the payload. This is useful when most variants carry common header fields (e.g. a device ID and a timestamp), but some variants — like an acknowledgement — carry no user data at all and should skip those fields.

Each prefix key may carry an `[except:0xNN;...]` clause listing the binary keys for which that prefix is omitted:

```
nid       INTEGER(16)
timestamp DATETIME
ack       VOID

signal XOR(8;[
    0x01:add_child;
    0x02:lost_child;
    0x66:ack];
  nid[except:0x66];timestamp[except:0x66])
```

Binary layout depending on the variant:

| Variant | Layout |
| --- | --- |
| `add_child` (0x01) | `[8-bit key][16-bit nid][48-bit timestamp][16-bit payload]` |
| `ack` (0x66) | `[8-bit key]` — no nid, no timestamp |

The serialized hash must include only the prefix fields that are active for the chosen variant:

```ruby
# ack omits both prefix fields
signal_codec.serialize_to_bytes({"ack" => nil})

# add_child includes both
signal_codec.serialize_to_bytes({"nid" => 45, "timestamp" => Time.utc(2026, 1, 1), "add_child" => 12})
```

Deserialization mirrors this: the returned hash contains only the prefix keys that were actually present in the stream for the decoded variant.

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
- **Quoted strings**: `label="temp sensor"` — use double quotes when the value contains spaces or special characters
- **Bare identifiers** (unquoted): `unit=celsius` — alphanumeric/underscore words
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

### Codec descriptors

Every codec exposes a `descriptor` method that returns a plain symbol-keyed hash describing its structure. This is intended for external tools (e.g. an HTML/JS editor) that need to build a UI programmatically from the grammar, without depending on the Ruby class hierarchy.

```ruby
codecs = Codecs.new
codecs.add_codec(CodecFloat.new(key: :ratio, min_float: 0.0, max_float: 1.0, nb_bit: 8,
                                statics: { "unit" => "percent" }, comment: "battery level"))

codecs.descriptor(:ratio)
# => { key: :ratio, comment: "battery level", unit: "percent", type: :float, min: 0.0, max: 1.0 }
```

Composite codecs nest their children:

```ruby
codecs.add_codec(CodecInteger.new(key: :speed,    nb_bit: 5))
codecs.add_codec(CodecInteger.new(key: :altitude, nb_bit: 9))
codecs.add_codec(CodecSequence.new(key: :flight, keys: [:speed, :altitude]))

codecs.descriptor(:flight)
# => {
#      key: :flight, comment: nil, type: :sequence,
#      items: [
#        { key: :speed,    comment: nil, type: :integer, min: 0, max: 31 },
#        { key: :altitude, comment: nil, type: :integer, min: 0, max: 511 }
#      ]
#    }
```

To get descriptors for every codec in the registry at once:

```ruby
codecs.descriptors  # => { speed: { ... }, altitude: { ... }, flight: { ... } }
```

The `type` values map to codec kinds as follows:

| `type` value | Codec |
| --- | --- |
| `:boolean` | `BOOLEAN` |
| `:integer` | `INTEGER`, `INTEGER_LONG` |
| `:float` | `FLOAT` |
| `:bytes` | `BYTES` |
| `:hexa` | `HEXA` |
| `:symbol` | `SYMBOL` |
| `:datetime` | `DATETIME` |
| `:void` | `VOID` |
| `:sequence` | `SEQUENCE` — includes `items:` array |
| `:alias` | `ALIAS` — includes `item:` with the target's descriptor |
| `:array` | `ARRAY` — includes `item:` and `nb_item_max:` |
| `:xor` | `XOR` — includes `keys_to_descriptor:` hash keyed by codec key (each entry carries `bkey:`), and `prefix_descriptors:` array (each entry carries `except:` with the binary keys for which that prefix is skipped) |
| `:xor_list_item` | `LIST` — includes `item_descriptor:` with the XOR codec's descriptor |

Any `STATIC` metadata attached to the codec is merged into the descriptor with symbolized keys, so `STATIC(unit=celsius)` becomes `unit: "celsius"`.

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

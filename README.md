# json2bits

`json2bits` is a Ruby library that turns structured data (hashes, arrays, and scalars) into compact bit-level frames and back again. It was originally designed to encode Bluetooth payloads, and it works equally well for LoRa, proprietary RF links, or any protocol where every bit counts but you still want to express the payload as JSON in your application.

## Why json2bits?

- **Protocol-friendly** – describe your frame layout once in a configuration file and reuse it on both sides of the link.
- **Deterministic** – the serializers work at the bit level, so you control exactly how many bits are used for each field.
- **Extensible** – static metadata, composite codecs, nested messages, and XOR selectors make it easy to model real-world IoT payloads.
- **Readable configs** – the DSL stays close to the way firmware engineers describe frames.

Use this gem when you need a small binary representation for telemetry, command/control frames, or any situation where human-friendly JSON needs to become byte streams.

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

```ruby
require "json2bits"

config_text = File.read("config.txt")
configuration = Json2Bits::Configuration.parse(config_text)
codec = Json2Bits::Serializer.new(configuration)

# Serialize a single INTEGER fragment (5 bits)
bytes, nb_bits = codec.serialize("temperature", 18)
# bytes.bytes.first => 10010000 (the last 3 bits are useless)
codec.deserialize("temperature", bytes) # => { "temperature" => 18}

# Serialize a BOOLEAN flag fragment (1 bit)
bytes, nb_bits = codec.serialize("flag", true)
# bytes.bytes.first => 10000000, the last 7 bits are useless
codec.deserialize("flag", bytes) # => { "flag" => true}

# Serialize a FLOAT fragment (8 bits) ranging from 1.5 to 4.0
bytes, nb_bits = codec.serialize("battery_level", 3.33)
# bytes.bytes.first => 10111011
value = codec.deserialize("battery_level", bytes) # => 3.333333333333333
# watch out ! deserialisation for a float might not return exactly the same value

# Serialize an HEXA fragment (6 bytes)
bytes, nb_bits = codec.serialize("device_mac", "0xab123c453AB2")
codec.deserialize("device_mac", bytes) # => {"device_mac"=>"0xAB123C453AB2"}

# Serialize a BYTES fragment (3 bytes)
bytes, nb_bits = codec.serialize("payload", [0x12, 0xAB, 0x23])
codec.deserialize("payload", bytes) # => {"payload"=>[18, 171, 35]}

# Serialize a SYMBOL fragment (2 bits)
bytes, nb_bits = codec.serialize("accelerometer_kpi", "motion")
# bytes.bytes.first => 01000000, the last 6 bits are useless
codec.deserialize("accelerometer_kpi", bytes) # => {"accelerometer_kpi"=>"motion"}

# serialize a SEQUENCE fragment, 14 bits
bytes, nb_bits = codec.serialize("packet", { 
  "flag" => true,
  "temperature" => 18,
  "battery_level" => 3.33
  })
# encoded as 1100101011101100, the last 2 bits are useless
# 1 for flag
# 10010 for temperature
# 10111011 for battery_level
codec.deserialize("packet", bytes) # => {"packet"=>{"flag"=>true, "temperature"=>18, "battery_level"=>3.333333333333333}}

# serialize an ARRAY of temperatures
bytes, nb_bits = codec.serialize("temperatures", [12,14,9])
# uses 4 bits + 3 * 5 bits = 19 bits
codec.deserialize("temperatures", bytes) # => {"accelerometer_kpi"=>"motion"}

# serialize an ALIAS of battery level with a static value
bytes, nb_bits = codec.serialize("battery_level_backup", 3.33)
# use 8 bits as a battery_level
codec.deserialize("battery_level_backup", bytes) # => {"battery_level_backup"=>3.333333333333333, "mode"=>"backup"}

# serialize XOR a temperature or a battery level
bytes, nb_bits = codec.serialize("measure", { "temperature" => 18 })
# encoded as 01001000, the last 2 bits are useless
# 0 for selector i.e temperature or battery level
# 10010 for temperature
codec.deserialize("measure", bytes) # => {"measure"=>{"temperature"=>18}}

# Serialize a full message (an array of fragment)
message = [
  { "accelerometer_kpi" => "motion" },
  { "battery_level" => 3.33 },
  { "temperature" => 18 }
]
bytes, nb_bits = codec.serialize(message)
# encoded as 01100100111011101100011001000000, use 27 bits, the last 5 bits are useless
# 0110 for selector accelerometer_kpi (0x06), 01 for the value motion
# 0011 for selector battery_level (0x03), 10111011 for the value 3.33
# 0001 for selector temperature (0x01), 10010 for the value 18
decoded = codec.deserialize(bytes)
# => [{"accelerometer_kpi"=>"motion"}, {"battery_level"=>3.303921568627451}, {"temperature"=>18}]
```

## Configuration file

Configuration files are plain text. Each line sets a global parameter or defines a fragment:

```
<binary_key> <json_key> <codec> [STATIC(...)] [comment...]
```

Example:

```
nb_bit_key_binary=4 // 4 bits allow for 15 codes (0x00 is reserved)
0x01 temperature INTEGER(5) // an integer using 5 bits
0x02 flag BOOLEAN // a basic boolean value
0x03 battery_level FLOAT(8;1.5;4.0) // a float coded with 8 bits, value range from 1.5 to 4.0
0x04 device_mac HEXA(6) // Mac address
0x05 payload BYTES(3)
0x06 accelerometer_kpi SYMBOL(no_alarm;motion;free_fall) // use 2 bits
0x07 packet SEQUENCE(flag, temperature, battery_level)
0x08 temperatures ARRAY(4, temperature) // an array of 15 elements max, use 4 bits + serialization of temperatures
0x09 battery_level_backup ALIAS(battery_level) STATIC(mode=backup)
0x0A measure XOR(temperature, battery_level) // 1 bit + serialization of temperature or battery_level 

```

Notes:
- Binary keys are written in hex (`0xNN`) or decimal.
- `STATIC` attributes attach constant fields (defaulting to `true`) to the fragment.
- The reserved identifier `message` can be used in composite codecs to embed another message.
- `XOR(*)` automatically references every other definition, handy for multiplexed payloads.

## Codec reference

### Primary codecs

| Codec | Syntax | Description |
| --- | --- | --- |
| `STATIC` | `STATIC()` or `STATIC(value)` | Emits no bits; validates that the field equals the static value (defaults to `true`). |
| `BOOLEAN` | `BOOLEAN` | Single bit boolean. |
| `INTEGER` | `INTEGER(nb_bit)` | Unsigned integer encoded on `nb_bit` bits (1–64). |
| `FLOAT` | `FLOAT(nb_bit;min;max)` | Maps an integer range to a float interval. |
| `BYTES` | `BYTES(nb_byte)` | Fixed-length raw bytes. |
| `HEXA` | `HEXA(nb_byte)` | Hexadecimal string backed by `nb_byte` bytes. |
| `SYMBOL` | `SYMBOL(value1;value2;...)` | Encodes the index of a symbolic value (`ceil(log2(n))` bits). |
| `VOID` | `VOID` | No payload; presence implies the field is `true`. |

### Composite codecs

| Codec | Syntax | Description |
| --- | --- | --- |
| `SEQUENCE` | `SEQUENCE(def1;def2;...;message?)` | Concatenates several fragments under one key. The optional trailing `message` placeholder writes a nested message without appending an extra terminator. |
| `ALIAS` | `ALIAS(definition_key)` | Reuses another definition under a new name/binary key. |
| `ARRAY` | `ARRAY(nb_bit;definition_key[;...;message?])` | Length-prefixed array supporting scalar elements, composite tuples, or a terminal `message` placeholder (which keeps the `0x00` terminator so subsequent elements remain parseable). |
| `XOR` | `XOR(def1;def2;...;message?)` or `XOR(*)` | Selects exactly one branch. The wildcard version automatically includes every definition (except itself). A `message` branch embeds a nested message. |

## Nested messages

The `message` placeholder is interpreted using the same message protocol as top-level payloads. When it is the final element in a composite codec, the serializer skips the trailing `0x00` marker to save space. If additional data follow (e.g., other array entries) the marker is preserved. The deserializer accepts both forms for backward compatibility.

## Development

Run the test suite with:

```bash
bundle exec rake test
```

Feel free to extend the fixtures in `test/` to cover the shapes you rely on; the serializer reports bit lengths for every call, which makes it easy to assert binary sizes.

## License

This project is released under the MIT License. See `json2bits.gemspec` for details.

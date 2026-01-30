# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

json2bits is a Ruby gem that serializes/deserializes JSON data fragments into compact bit streams using a declarative configuration format. It's designed for binary protocol and firmware applications where bit-level control and deterministic serialization are required.

## Build and Test Commands

```bash
bundle install                                    # Install dependencies
bundle exec rake                                  # Run all tests (default task)
bundle exec rake test TEST=test/codecs_test.rb   # Run a specific test file
tt lib/json2bits/configurator.tt -f              # Regenerate parser after grammar changes
```

## Architecture

### Core Components

**BitStream** (`lib/json2bits/bit_stream.rb`) - Low-level bit manipulation for reading/writing bits across byte boundaries in MSB order.

**Codec Hierarchy** (`lib/json2bits/codecs.rb`) - All serialization codecs inherit from base `Codec` class:
- `CodecFixLength` - Fixed-size codecs: `CodecVoid`, `CodecInteger`, `CodecBoolean`, `CodecSymbol`, `CodecFloat`, `CodecBytes`, `CodecHexa`
- `CodecComposite` - Variable/composite codecs: `CodecAlias`, `CodecIntegerLong`, `CodecSequence`, `CodecArray`, `CodecXor`, `CodecList`

**Codecs Manager** (`lib/json2bits/codecs.rb`) - Registry that holds all codec instances and resolves references between them.

**Parser** (`lib/json2bits/configurator.tt`) - Treetop PEG grammar that parses the DSL configuration format into codec instances.

### Data Flow

1. Configuration text is parsed by `ConfiguratorParser` (generated from `configurator.tt`)
2. Parser produces a `Codecs` instance containing all defined codecs
3. A codec's `serialize_to_bytes(json)` converts JSON to byte array via `BitStream`
4. A codec's `deserialize_from_bytes(bytes)` reconstructs JSON from bytes

### Adding a New Codec Type

1. Add parsing rule to `lib/json2bits/configurator.tt`
2. Implement codec class in `lib/json2bits/codecs.rb` (inherit from `CodecFixLength` or `CodecComposite`)
3. Add test cases to `test/configurator_test.rb`
4. Regenerate parser: `tt lib/json2bits/configurator.tt -f`

## Configuration DSL Format

Line format: `<key> <CODEC>(parameters) [STATIC(metadata)] [// comment]`

Available codecs:
- `BOOLEAN` - Single bit
- `INTEGER(nb_bit)` - Unsigned integer (1-64 bits)
- `FLOAT(nb_bit;min;max)` - Maps integer range to float interval
- `BYTES(nb_bytes)` - Raw byte data of fixed length
- `HEXA(nb_bytes)` - Hexadecimal string
- `SYMBOL(nb_bit;v1;v2;...)` - Symbol enum
- `VOID` - No payload
- `SEQUENCE(k1;k2;...)` - Concatenate codecs
- `ALIAS(target_key)` - Reference another codec
- `ARRAY(nb_bit;item_key)` - Homogeneous list with length prefix
- `XOR(nb_bit;[0xNN:k1;...])` - One-of choice between codecs
- `LIST(xor_key)` - Heterogeneous list using a XOR codec (0x00 terminator when not last)

## Key Files

- `lib/json2bits/configurator.tt` - Grammar source (edit this for DSL changes)
- `lib/json2bits/configurator.rb` - Generated parser (never edit directly)
- `lib/json2bits/codecs.rb` - All codec implementations
- `test/configuration.txt` - Main test fixture with DSL examples

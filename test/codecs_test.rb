# == Schema Information
#

require "test_helper"

class CodecsTest < Minitest::Test
  def setup
    @codecs = Codecs.new
  end

  def test_integer_codec_round_trip_and_upper_bound
    codec = @codecs.add_codec(CodecInteger.new(key: :int, nb_bit: 4))

    bit_stream = BitStream.new
    assert_equal [0b11010000], codec.serialize(bit_stream, 13).bytes
    assert_equal 4, bit_stream.nb_bits_written

    assert_equal 12, round_trip(codec, 12)
    assert_raises(RuntimeError) { codec.serialize(BitStream.new, 16) }
  end

  def test_boolean_codec_round_trip
    codec = @codecs.add_codec(CodecBoolean.new(key: :flag))

    assert_equal true, round_trip(codec, true)
    assert_equal false, round_trip(codec, false)
  end

  def test_symbol_codec_round_trip
    codec = @codecs.add_codec(CodecSymbol.new(key: :state, symbols: [:idle, :active, :paused]))

    assert_equal :active, round_trip(codec, :active)
  end

  def test_float_codec_round_trip_and_range_validation
    codec = @codecs.add_codec(CodecFloat.new(
      key: :ratio,
      min_float: 0.0,
      max_float: 1.0,
      nb_bit: 12
    ))

    bytes = codec.serialize_to_bytes(0.375)
    assert_in_delta 0.375, codec.deserialize_from_bytes(bytes.dup), 0.001

    assert_raises(RuntimeError) { codec.serialize_to_bytes(1.1) }
  end



  # bytes are expected to be a string of given length
  def test_bytes_codec_round_trip_and_length_validation
    codec = @codecs.add_codec(CodecBytes.new(key: :payload, nb_bytes: 3))

    assert_equal "abc", round_trip(codec, "abc")
    assert_raises(RuntimeError) { codec.serialize_to_bytes("abcd") }
  end

  def test_hexa_codec_round_trip
    codec = @codecs.add_codec(CodecHexa.new(key: :hex, nb_bytes: 2))

    assert_equal "3f3a", round_trip(codec, "3f3a")
  end

  def test_integer_long_codec_segments
    codec = @codecs.add_codec(CodecIntegerLong.new(key: :long, bits_segment: [4, 10, 18]))

    assert_equal 11, round_trip(codec, 11)
    assert_equal 777, round_trip(codec, 777)
    assert_equal 65_535, round_trip(codec, 65_535)
    assert_raises(RuntimeError) { codec.serialize(BitStream.new, 300_000) }
  end

  def test_array_codec_round_trip
    item_codec = @codecs.add_codec(CodecInteger.new(key: :item, nb_bit: 6))
    codec = @codecs.add_codec(CodecArray.new(key: :items, item_key: :item, nb_item_max: 7))

    assert_equal [1, 2, 3], round_trip(codec, [1, 2, 3])

    writer = BitStream.new
    codec.serialize(writer, [1, 2, 3])
    assert_equal 3 + 3 * 6, writer.nb_bits_written

  end

  def test_sequence_codec_round_trip

    speed_codec = @codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 5))
    altitude_codec = @codecs.add_codec(CodecInteger.new(key: :altitude, nb_bit: 9))

    codec = @codecs.add_codec(CodecSequence.new(key: :flight, keys: [:speed, :altitude]))
    input = { speed: 23, altitude: 341 }
    assert_equal(input, round_trip(codec, input))

    writer = BitStream.new
    codec.serialize(writer, input)
    assert_equal 5 + 9, writer.nb_bits_written

  end

  def test_xor_codec_round_trip_for_multiple_variants

    short_codec = @codecs.add_codec(CodecInteger.new(key: :device_index_short, nb_bit: 5))
    long_codec = @codecs.add_codec(CodecInteger.new(key: :device_index_long, nb_bit: 11))

    codec = @codecs.add_codec(CodecXor.new(
      key: :device_index,
      nb_bit_binary_key: 4,
      binary_keys: { :device_index_short => 0x1, :device_index_long => 0x2 }
    ))

    assert_equal({:device_index_short => 11}, round_trip(codec, {:device_index_short => 11}))
    assert_equal({:device_index_long => 879}, round_trip(codec, {:device_index_long => 879}))
  end

  def test_list_codec_round_trip_no_terminator

    temperature_codec = @codecs.add_codec(CodecInteger.new(key: :temperature, nb_bit: 6))
    humidity_codec = @codecs.add_codec(CodecInteger.new(key: :humidity, nb_bit: 6))
    codec_xor = @codecs.add_codec(CodecXor.new(
      key: :item,
      nb_bit_binary_key: 4,
      binary_keys: { :temperature => 0x1, :humidity => 0x2 }
    ))

    codec = @codecs.add_codec(CodecList.new(key: :measurements, item_key: :item))

    input = [{:temperature => 45}, {:humidity => 39}]

    writer = BitStream.new
    codec.serialize(writer, input)
  
    assert_equal  (4 + 6) + (4 + 6), writer.nb_bits_written

    reader = BitStream.new(bytes: writer.bytes.dup)

    assert_equal input, codec.deserialize(reader)
  end

  def test_list_codec_round_trip_terminator

    speed_codec = @codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 5))
    temperature_codec = @codecs.add_codec(CodecInteger.new(key: :temperature, nb_bit: 6))
    humidity_codec = @codecs.add_codec(CodecInteger.new(key: :humidity, nb_bit: 6))
    measurement_codec = @codecs.add_codec(CodecXor.new(key: :measurement, nb_bit_binary_key: 4, binary_keys: { :temperature => 0x1, :humidity => 0x2 }))
    measurements_codec = @codecs.add_codec(CodecList.new(key: :measurements, item_key: :measurement))
    codec_sequence = @codecs.add_codec(CodecSequence.new(key: :data, keys: [:speed, :measurements]))

    input = {
      speed: 17,
      measurements: [{:temperature => 45}, {:humidity => 39}]
    }
    
    writer = BitStream.new
    codec_sequence.serialize(writer, input)
  
    assert_equal  5 + (4 + 6) + (4 + 6), writer.nb_bits_written

    reader = BitStream.new(bytes: writer.bytes.dup)

    assert_equal input, codec_sequence.deserialize(reader)

    # reader = BitStream.new(bytes: writer.bytes.dup)
    # assert_equal input, codec_sequence.deserialize_and_flatten(reader)

    codec_sequence_inverted = @codecs.add_codec(CodecSequence.new(key: :data, keys: [:measurements, :speed]))
    writer = BitStream.new
    codec_sequence_inverted.serialize(writer, input)

    assert_equal  (4 + 6) + (4 + 6) + 4 + 5, writer.nb_bits_written

    reader = BitStream.new(bytes: writer.bytes.dup)

    assert_equal input, codec_sequence_inverted.deserialize(reader)
    
  end

  def test_datetime_codec_serialize_known_bytes
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))

    # Y2K epoch = all zeros
    assert_equal [0x00,0x00,0x00,0x00,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 1, 0, 0, 0))
    # +1 ms  [2000-01-01|00:00:00.001]
    assert_equal [0x01,0x00,0x00,0x00,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 1, 0, 0, 0, 1_000))
    # +1 min  [2000-01-01|00:01:00.000]
    assert_equal [0x60,0xea,0x00,0x00,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 1, 0, 1, 0))
    # +1 hour  [2000-01-01|01:00:00.000]
    assert_equal [0x80,0xee,0x36,0x00,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 1, 1, 0, 0))
    # +1 day  [2000-01-02|00:00:00.000]
    assert_equal [0x00,0x5c,0x26,0x05,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 2, 0, 0, 0))
    # specific timestamp  [2026-02-10|13:42:04.743]
    assert_equal [0xc7,0xfe,0xf9,0xdc,0xbf,0x00], codec.serialize_to_bytes(Time.utc(2026, 2, 10, 13, 42, 4, 743_000))
  end

  def test_datetime_codec_round_trip
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))
    t = Time.utc(2026, 2, 10, 13, 42, 4, 743_000)
    result = round_trip(codec, t)
    # Round-trip is exact to the millisecond
    assert_equal t.to_i * 1000 + t.usec / 1000, result.to_i * 1000 + result.usec / 1000
    assert_equal 48, codec.serialize_to_bytes(t, compute_nb_bit: true)[1]
  end

  def test_datetime_codec_sub_ms_truncation
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))

    # 999 usec is less than 1ms and truncates to 0ms (not rounded up)
    assert_equal [0x00,0x00,0x00,0x00,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 1, 0, 0, 0, 999))
    # 1500 usec truncates to 1ms (not rounded to 2ms)
    assert_equal [0x01,0x00,0x00,0x00,0x00,0x00], codec.serialize_to_bytes(Time.utc(2000, 1, 1, 0, 0, 0, 1_500))
  end

  def test_datetime_codec_non_utc_input_produces_same_bytes
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))

    utc_time   = Time.utc(2026, 2, 10, 13, 42, 4, 743_000)
    local_time = utc_time.localtime

    # to_i is always UTC-based, so timezone wrapper must not affect the encoding
    assert_equal codec.serialize_to_bytes(utc_time), codec.serialize_to_bytes(local_time)
  end

  def test_datetime_codec_deserialize_returns_utc
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))

    result = round_trip(codec, Time.utc(2026, 2, 10, 13, 42, 4, 743_000))
    assert result.utc?, "deserialized Time should be UTC"
  end

  def test_datetime_codec_year_boundary
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))

    last_ms_of_2000  = Time.utc(2000, 12, 31, 23, 59, 59, 999_000)
    first_ms_of_2001 = Time.utc(2001,  1,  1,  0,  0,  0,   1_000)

    bytes_last  = codec.serialize_to_bytes(last_ms_of_2000)
    bytes_first = codec.serialize_to_bytes(first_ms_of_2001)

    # Year 2000 has 366 days (leap); last ms = 366*86400*1000 - 1 ms
    expected_last_ms = 366 * 86_400_000 - 1
    assert_equal expected_last_ms, bytes_last.each_with_index.sum { |b, i| b << (8 * i) }

    # first ms of 2001 = 366*86400*1000 + 1
    expected_first_ms = 366 * 86_400_000 + 1
    assert_equal expected_first_ms, bytes_first.each_with_index.sum { |b, i| b << (8 * i) }

    # Consecutive: first must be exactly 2ms after last
    assert_equal 2, bytes_first.each_with_index.sum { |b, i| b << (8 * i) } -
                    bytes_last.each_with_index.sum  { |b, i| b << (8 * i) }
  end

  def test_datetime_codec_serialize_string_input
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))

    # String input must produce the same bytes as the equivalent Time object
    assert_equal codec.serialize_to_bytes(Time.utc(2026, 2, 10, 13, 42, 4)),
                 codec.serialize_to_bytes("2026-02-10T13:42:04Z")
  end

  def test_integer_encoding_default_is_big_endian
    assert_equal false, @codecs.integer_encoding_little_endian?
  end

  def test_integer_big_endian_byte_order
    codec = @codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 16))
    assert_equal [0x12, 0x34], codec.serialize_to_bytes(0x1234)
  end

  def test_integer_little_endian_byte_order
    codecs = Codecs.new(globals: {"endian" => "little"})
    codec = codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 16))
    assert_equal [0x34, 0x12], codec.serialize_to_bytes(0x1234)
  end

  def test_integer_little_endian_round_trip_16bit
    codecs = Codecs.new(globals: {"endian" => "little"})
    codec = codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 16))
    assert_equal 0xABCD, round_trip(codec, 0xABCD)
  end

  def test_integer_little_endian_round_trip_24bit
    codecs = Codecs.new(globals: {"endian" => "little"})
    codec = codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 24))
    assert_equal 0x123456, round_trip(codec, 0x123456)
  end

  def test_integer_little_endian_non_multiple_of_8
    # INTEGER(12): low byte (8 bits) first, then high nibble (4 bits)
    # 0xABC = 0b1010_1011_1100 → first byte 0xBC, then nibble 0xA
    codecs = Codecs.new(globals: {"endian" => "little"})
    codec = codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 12))
    bytes = codec.serialize_to_bytes(0xABC)
    assert_equal 0xBC, bytes[0]
    assert_equal 0xA0, bytes[1] & 0xF0  # high nibble of second byte
    assert_equal 0xABC, round_trip(codec, 0xABC)
  end

  def test_integer_little_endian_8bit_unaffected
    # <= 8 bits: endianness does not apply, behaviour identical to big-endian
    codecs = Codecs.new(globals: {"endian" => "little"})
    codec = codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 8))
    assert_equal [0xAB], codec.serialize_to_bytes(0xAB)
  end

  # --- descriptor ---

  def test_integer_descriptor
    codec = @codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 8))
    d = codec.descriptor
    assert_equal :speed,   d[:key]
    assert_equal :integer, d[:type]
    assert_equal 0,        d[:min]
    assert_equal 255,      d[:max]
    assert_nil             d[:comment]
  end

  def test_boolean_descriptor_has_no_min_max
    codec = @codecs.add_codec(CodecBoolean.new(key: :flag))
    d = codec.descriptor
    assert_equal :boolean, d[:type]
    assert_nil d[:min]
    assert_nil d[:max]
  end

  def test_symbol_descriptor
    codec = @codecs.add_codec(CodecSymbol.new(key: :state, symbols: [:idle, :active, :paused]))
    d = codec.descriptor
    assert_equal :symbol,               d[:type]
    assert_equal [:idle, :active, :paused], d[:symbols]
  end

  def test_float_descriptor
    codec = @codecs.add_codec(CodecFloat.new(key: :ratio, min_float: 0.0, max_float: 1.0, nb_bit: 8))
    d = codec.descriptor
    assert_equal :float, d[:type]
    assert_equal 0.0,   d[:min]
    assert_equal 1.0,   d[:max]
  end

  def test_bytes_descriptor
    codec = @codecs.add_codec(CodecBytes.new(key: :payload, nb_bytes: 4))
    d = codec.descriptor
    assert_equal :bytes, d[:type]
    assert_equal 4,      d[:nb_bytes]
  end

  def test_hexa_descriptor
    codec = @codecs.add_codec(CodecHexa.new(key: :hex, nb_bytes: 2))
    d = codec.descriptor
    assert_equal :hexa, d[:type]
    assert_equal 2,     d[:nb_bytes]
  end

  def test_datetime_descriptor
    codec = @codecs.add_codec(CodexDateTime.new(key: :ts))
    assert_equal :datetime, codec.descriptor[:type]
  end

  def test_void_descriptor
    codec = @codecs.add_codec(CodecVoid.new(key: :marker))
    assert_equal :void, codec.descriptor[:type]
  end

  def test_sequence_descriptor
    @codecs.add_codec(CodecInteger.new(key: :speed,    nb_bit: 5))
    @codecs.add_codec(CodecInteger.new(key: :altitude, nb_bit: 9))
    codec = @codecs.add_codec(CodecSequence.new(key: :flight, keys: [:speed, :altitude]))
    d = codec.descriptor
    assert_equal :sequence, d[:type]
    assert_equal 2,         d[:items].size
    assert_equal :speed,    d[:items][0][:key]
    assert_equal :integer,  d[:items][0][:type]
    assert_equal :altitude, d[:items][1][:key]
  end

  def test_array_descriptor
    @codecs.add_codec(CodecInteger.new(key: :item, nb_bit: 6))
    codec = @codecs.add_codec(CodecArray.new(key: :items, item_key: :item, nb_item_max: 7))
    d = codec.descriptor
    assert_equal :array,   d[:type]
    assert_equal 7,        d[:nb_item_max]
    assert_equal :integer, d[:item][:type]
    assert_equal :item,    d[:item][:key]
  end

  def test_xor_descriptor
    @codecs.add_codec(CodecInteger.new(key: :short, nb_bit: 5))
    @codecs.add_codec(CodecInteger.new(key: :long,  nb_bit: 11))
    codec = @codecs.add_codec(CodecXor.new(
      key: :choice,
      nb_bit_binary_key: 4,
      binary_keys: { short: 0x1, long: 0x2 }
    ))
    d = codec.descriptor
    assert_equal :xor, d[:type]
    assert d[:keys_to_descriptor].key?(:short)
    assert d[:keys_to_descriptor].key?(:long)
    assert_equal 0x1, d[:keys_to_descriptor][:short][:bkey]
    assert_equal 0x2, d[:keys_to_descriptor][:long][:bkey]
  end

  def test_list_descriptor
    @codecs.add_codec(CodecInteger.new(key: :temp, nb_bit: 6))
    @codecs.add_codec(CodecXor.new(key: :item, nb_bit_binary_key: 4, binary_keys: { temp: 0x1 }))
    codec = @codecs.add_codec(CodecList.new(key: :measurements, item_key: :item))
    d = codec.descriptor
    assert_equal :xor_list_item, d[:type]
    assert_equal :xor,           d[:item_descriptor][:type]
  end

  def test_alias_descriptor
    @codecs.add_codec(CodecInteger.new(key: :original, nb_bit: 8))
    codec = @codecs.add_codec(CodecAlias.new(key: :aliased, target_key: :original))
    d = codec.descriptor
    assert_equal :alias,   d[:type]
    assert_equal :integer, d[:item][:type]
    assert_equal :original, d[:item][:key]
  end

  def test_descriptor_includes_comment
    codec = @codecs.add_codec(CodecInteger.new(key: :val, nb_bit: 8, comment: "sensor value"))
    assert_equal "sensor value", codec.descriptor[:comment]
  end

  def test_descriptor_includes_statics_as_symbol_keys
    codec = @codecs.add_codec(CodecInteger.new(
      key: :temp, nb_bit: 8,
      statics: { "unit" => "celsius", "readonly" => true }
    ))
    d = codec.descriptor
    assert_equal "celsius", d[:unit]
    assert_equal true,      d[:readonly]
  end

  def test_codecs_descriptor_by_key
    @codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 5))
    d = @codecs.descriptor(:speed)
    assert_equal :integer, d[:type]
    assert_equal :speed,   d[:key]
  end

  def test_codecs_descriptors_all
    @codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 5))
    @codecs.add_codec(CodecBoolean.new(key: :flag))
    all = @codecs.descriptors
    assert_equal 2,        all.size
    assert_equal :integer, all[:speed][:type]
    assert_equal :boolean, all[:flag][:type]
  end

  def test_integer_little_endian_parser_integration
    config = "STATIC(endian=little)\nnid INTEGER(16)\n"
    parsed = ConfiguratorParser.new.parse(config)
    assert parsed, "config should parse"
    codecs = parsed.value
    assert codecs.integer_encoding_little_endian?
    codec = codecs.key_2_codec("nid")
    assert_equal [0x34, 0x12], codec.serialize_to_bytes(0x1234)
  end

  def test_extract_unit_from_format
    # "%dms" -> "ms"
    assert_equal "ms", Codec.send(:extract_unit_from_format, "%dms")
    # "%.2f°C" -> "°C"
    assert_equal "°C", Codec.send(:extract_unit_from_format, "%.2f°C")
    # "%d" -> no unit
    assert_nil Codec.send(:extract_unit_from_format, "%d")
    # "%.1f%%" -> "%"
    assert_equal "%", Codec.send(:extract_unit_from_format, "%.1f%%")
    # nil input -> nil
    assert_nil Codec.send(:extract_unit_from_format, nil)
    # non-string input -> nil
    assert_nil Codec.send(:extract_unit_from_format, 42)
  end

  private

  def round_trip(codec, value)
    bytes = codec.serialize_to_bytes(value)
    codec.deserialize_from_bytes(bytes.dup)
  end

end

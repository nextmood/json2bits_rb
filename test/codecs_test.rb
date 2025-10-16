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
    codec = @codecs.add_codec(CodecIntegerLong.new(key: :long, bits_segement: [4, 10, 18]))

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

  def test_list_codec_round_trip_with_no_terminator

    temperature_codec = @codecs.add_codec(CodecInteger.new(key: :temperature, nb_bit: 6))
    humidity_codec = @codecs.add_codec(CodecInteger.new(key: :humidity, nb_bit: 6))
    codec_xor = @codecs.add_codec(CodecXor.new(
      key: :item,
      nb_bit_binary_key: 4,
      binary_keys: { :temperature => 0x1, :humidity => 0x2 }
    ))

    codec = @codecs.add_codec(CodecListXor.new(key: :measurements, key_xor: :item))

    input = [{:temperature => 45}, {:humidity => 39}]

    writer = BitStream.new
    codec.serialize(writer, input)
  
    assert_equal  (4 + 6) + (4 + 6), writer.nb_bits_written

    reader = BitStream.new(bytes: writer.bytes.dup)

    assert_equal input, codec.deserialize(reader)
  end

  def test_list_codec_round_trip_with_terminator

    speed_codec = @codecs.add_codec(CodecInteger.new(key: :speed, nb_bit: 5))
    temperature_codec = @codecs.add_codec(CodecInteger.new(key: :temperature, nb_bit: 6))
    humidity_codec = @codecs.add_codec(CodecInteger.new(key: :humidity, nb_bit: 6))
    measurement_codec = @codecs.add_codec(CodecXor.new(key: :measurement, nb_bit_binary_key: 4, binary_keys: { :temperature => 0x1, :humidity => 0x2 }))
    measurements_codec = @codecs.add_codec(CodecListXor.new(key: :measurements, key_xor: :measurement))
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

  private

  def round_trip(codec, value)
    bytes = codec.serialize_to_bytes(value)
    codec.deserialize_from_bytes(bytes.dup)
  end
end

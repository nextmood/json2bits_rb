

require "test_helper"
#require "#{Rails.root}/app/grammars/binary_serializer.rb"

class ConfiguratorTest < Minitest::Test
  # called before every single test
  def setup 
    @parser = ::ConfiguratorParser.new
  end

  def test_parsing_a_non_compliant_input
    assert_nil @parser.parse("whatever truc n")
  end

  def test_it_should_parse_data_fragment_definitions
    assert parsed = @parser.parse("device_index INTEGER(4)\n")
    assert parsed.value
    assert parsed = @parser.parse("device_index INTEGER(4) // either 4, 8, 12 or 16 bits depending on the configuration\n")
    assert parsed.value
    assert parsed = @parser.parse("mac_address HEXA(6)\n")
    assert parsed.value
    assert parsed = @parser.parse("child_added SEQUENCE(device_index;mac_address)\n")
    assert parsed.value
    assert parsed = @parser.parse("child_added SEQUENCE(device_index;mac_address)\n")
    assert parsed.value
    assert parsed = @parser.parse("device_death VOID\n")
    assert parsed.value
    assert parsed = @parser.parse("alarm SYMBOL(4;too_many_reboot;too_many_resync;battery_low;battery_critical;too_many_accelerometer_wake_up;accelerometer_has_detected_motion;accelerometer_has_detected_freefall)\n")
    assert parsed.value
    assert parsed = @parser.parse("temperature FLOAT(4;5.0;200.0)\n")
    assert parsed.value
    assert parsed = @parser.parse("alarm_type SYMBOL(4;too_many_reboot;too_many_resync;battery_low;battery_critical;too_many_accelerometer_wake_up;accelerometer_has_detected_motion;accelerometer_has_detected_freefall)\n")
    assert parsed.value
    assert parsed = @parser.parse("temperature_value FLOAT(4;5.0;200.0)\n")
    assert parsed.value
    assert parsed = @parser.parse("battery_level_value FLOAT(4;0.0;100.0) \n")
    assert parsed.value
    assert parsed = @parser.parse("device_index INTEGER(4)\ndevice_index_origin ALIAS(device_index)\n")
    assert parsed.value
    assert parsed = @parser.parse("child_added SEQUENCE(device_index_origin;device_index;mac_address)\n")
    assert parsed.value
    assert parsed = @parser.parse("device_index INTEGER(4)\ndevice_death ALIAS(device_index)\n")
    assert parsed.value
    assert parsed = @parser.parse("device_index_origin INTEGER(4)\nalarm_type SYMBOL(4;too_many_reboot;too_many_resync)\nalarm SEQUENCE(device_index_origin;alarm_type)\n")
    assert parsed.value
    assert parsed = @parser.parse("temperature FLOAT(4;5.0;200.0)\ndevice_index INTEGER(4)\nmeasurement XOR(2;[0x01:device_index;0x02:temperature])\n")
    assert parsed.value
  end

  def test_it_should_parse_a_composite_sequence
    assert parsed = @parser.parse(
      "speed INTEGER(7)
       altitude INTEGER(15)
       position SEQUENCE(speed;altitude)\n")
    codecs = parsed.value
    codec_sequence = codecs.key_2_codec("position")
    assert codec_sequence.is_a?(CodecSequence)
    
    assert_equal [0b00011010, 0b00000000, 0b01001000], codec_sequence.serialize_to_bytes({"speed" => 13, "altitude" => 18})

  end

  def test_it_should_parse_a_composite_xor
    assert parsed = @parser.parse(
      "device_index_short INTEGER(7)
       device_index_long INTEGER(15)
       device_index XOR(1;[0x00:device_index_short;0x01:device_index_long])\n")

    codecs = parsed.value
    codec_xor = codecs.key_2_codec("device_index")
    assert codec_xor.is_a?(CodecXor)

    assert_equal [0b00001101], codec_xor.serialize_to_bytes({"device_index_short" => 13})

    assert_equal [0b10000000, 0b11111111], codec_xor.serialize_to_bytes({"device_index_long" => 255})

  end

  def test_it_should_parse_a_list
    assert parsed = @parser.parse(
      "device_index INTEGER(4)
       temperature FLOAT(4;0.0;100.0)
       measurement XOR(2;[0x01:device_index;0x02:temperature])
       measurements LIST(measurement)\n")

    codecs = parsed.value
    codec_list = codecs.key_2_codec("measurements")
    assert codec_list.is_a?(CodecList)

    payload = [
      { "device_index" => 5 },
      { "temperature" => 100.0 },
      { "device_index" => 10 }
    ]

    bytes = codec_list.serialize_to_bytes(payload)

    decoded = codec_list.deserialize_from_bytes(bytes)
    assert_equal payload, decoded
  end

  def test_it_should_parse_and_compile_the_configuration_file
    configuration = File.read("test/configuration.txt")
    assert parsed = @parser.parse(configuration)
    codecs = parsed.value
    assert codecs.is_a?(Codecs)
    assert_equal 12, codecs.dictionnary.size
    assert_equal ["nid", "timestamp", "too_many_reboot_alarm", "too_many_resync_alarm", "battery_indicator_alarm", "too_many_accelerometer_wake_up_alarm", "accelerometer_alarm", "add_child_nid", "lost_child_nid", "new_parent_nid", "signal", "signals"], codecs.dictionnary.keys

    codec_signal = codecs.key_2_codec("signal")
    assert codec_signal.is_a?(CodecXor)

    codec_signals = codecs.key_2_codec("signals")
    assert codec_signals.is_a?(CodecList)

    # testing statics
    codec_too_many_reboot_alarm = codecs.key_2_codec("too_many_reboot_alarm")
    assert codec_too_many_reboot_alarm.statics["ack_required"]

    # serialize and deserialize a simple list of signals
    input_ori = [{"nid" => 45, "timestamp" => "\xF9\xFA\xFB\xFC\xFD\xFE".b, "add_child_nid" => 12}]
    writer = BitStream.new
    codec_signals.serialize(writer, input_ori)

    assert_equal  (8 + 16 + 48) + (16), writer.nb_bits_written
    assert_equal writer.bytes, [0x01, 0x00, 0x2d, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0x00, 0x0C]

    reader = BitStream.new(bytes: writer.bytes.dup)
    input_bis = codec_signals.deserialize(reader)
    assert_equal input_ori, input_bis
  end


  def test_it_should_parse_statics
    assert parsed = @parser.parse("temperature FLOAT(4;0.0;100.0) STATIC(unit=celsius;precision=2;readonly)\n")
    codecs = parsed.value
    codec = codecs.key_2_codec("temperature")

    assert_equal({ "unit" => "celsius", "precision" => 2, "readonly" => true }, codec.statics)
  end

  def test_it_should_parse_readme_example
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
    assert ast
    codecs = ast.value

    # Keys coming from the parser are strings
    measurements = codecs.key_2_codec("measurements")
    assert measurements.is_a?(CodecList)

    payload = [
      { "battery_percent" => 80.0 },
      { "position" => { "longitude" => 5.0, "latitude" => 40.0 } },
      { "device_index" => 13 },
      { "battery_status" => "charging" },
      { "device_index" => 5 }
    ]

    bytes = measurements.serialize_to_bytes(payload)
    assert_equal [0b01011001, 0b10000111, 0b11111000, 0b00001001, 0b10101100, 0b11000101], bytes

    decoded = measurements.deserialize_from_bytes(bytes)
    assert_equal payload, decoded

  end

end

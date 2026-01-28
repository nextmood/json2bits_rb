

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
    assert parsed = @parser.parse("device_index_origin ALIAS(device_index)\n")
    assert parsed.value
    assert parsed = @parser.parse("child_added SEQUENCE(device_index_origin;device_index;mac_address)\n")
    assert parsed.value
    assert parsed = @parser.parse("device_death ALIAS(device_index)\n")
    assert parsed.value
    assert parsed = @parser.parse("alarm SEQUENCE(device_index_origin;alarm_type)\n")
    assert parsed.value
    assert parsed = @parser.parse("temperature SEQUENCE(device_index_origin;temperature_value)\n")
    assert parsed.value
    assert parsed = @parser.parse("battery_level SEQUENCE(device_index_origin;battery_level_value)\n")
    assert parsed.value
    assert parsed = @parser.parse("temperature FLOAT(4;5.0;200.0)\ndevice_index INTEGER(4)\n")
    assert parsed.value    
    assert parsed = @parser.parse("temperature FLOAT(4;5.0;200.0)\ndevice_index INTEGER(4)\nmeasurement XOR(2;0x01:device_index;0x02:temperature)\n")
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
       device_index XOR(1;0x00:device_index_short;0x01:device_index_long)\n")

    codecs = parsed.value
    codec_xor = codecs.key_2_codec("device_index")
    assert codec_xor.is_a?(CodecXor)

    assert_equal [0b00001101], codec_xor.serialize_to_bytes({"device_index_short" => 13})

    assert_equal [0b10000000, 0b11111111], codec_xor.serialize_to_bytes({"device_index_long" => 255})

  end

  def test_it_should_parse_a_list_xor
    assert parsed = @parser.parse(
      "device_index INTEGER(4)
       temperature FLOAT(4;0.0;100.0)
       measurement XOR(2;0x01:device_index;0x02:temperature)
       measurements LIST_XOR(measurement)\n")

    codecs = parsed.value
    codec_list_xor = codecs.key_2_codec("measurements")
    assert codec_list_xor.is_a?(CodecListXor)

    payload = [
      { "device_index" => 5 },
      { "temperature" => 100.0 },
      { "device_index" => 10 }
    ]

    bytes = codec_list_xor.serialize_to_bytes(payload)
    decoded = codec_list_xor.deserialize_from_bytes(bytes)
    assert_equal payload, decoded
  end

  def test_it_should_parse_a_list_xor_with_prefix
    assert parsed = @parser.parse(
      "sensor_id INTEGER(4)
       device_index INTEGER(4)
       temperature FLOAT(4;0.0;100.0)
       measurement XOR(2;0x01:device_index;0x02:temperature)
       measurements LIST_XOR(sensor_id;measurement)\n")

    codecs = parsed.value
    codec_list_xor = codecs.key_2_codec("measurements")
    assert codec_list_xor.is_a?(CodecListXorWithPrefix)

    payload = [
      { "sensor_id" => 1, "device_index" => 5 },
      { "sensor_id" => 2, "temperature" => 100.0 },
      { "sensor_id" => 3, "device_index" => 10 }
    ]

    bytes = codec_list_xor.serialize_to_bytes(payload)
    decoded = codec_list_xor.deserialize_from_bytes(bytes)
    assert_equal payload, decoded
  end

  def test_it_should_parse_and_compile_the_configuration_file
    configuration = File.read("test/configuration.txt")
    assert parsed = @parser.parse(configuration)
    codecs = parsed.value
    assert codecs.is_a?(Codecs)
    assert_equal 7, codecs.dictionnary.size
    assert_equal ["network_id", "add_child", "lost_child", "alarm", "temperature", "server_fragment", "server_signals"], codecs.dictionnary.keys

    codec_server_signals = codecs.key_2_codec("server_signals")
    
    payload_as_bytes = [0x00, 0x01, 0x01, 0x00, 0x05]
    decoded = codec_server_signals.deserialize_from_bytes(payload_as_bytes)
    assert_equal([{"network_id" => 1, "add_child" => 5}], decoded)

    payload_as_bytes = [0x00, 0x01, 0x02, 0x00, 0x05]
    decoded = codec_server_signals.deserialize_from_bytes(payload_as_bytes)
    assert_equal([{"network_id" => 1, "lost_child" => 5}], decoded)

    payload_as_bytes = [0x00, 0x01, 0x03, 0x00]
    decoded = codec_server_signals.deserialize_from_bytes(payload_as_bytes)
    assert_equal([{"network_id" => 1, "alarm" => "too_many_reboot"}], decoded)

    payload_as_bytes = [0x00, 0x01, 0x04, 0xFF]
    decoded = codec_server_signals.deserialize_from_bytes(payload_as_bytes)
    assert_equal([{"network_id" => 1, "temperature" => 200.0}], decoded)

    payload_as_bytes = [0x00, 0x01, 0x01, 0x00, 0x05, 0x00, 0x01, 0x02, 0x00, 0x05, 0x00, 0x01, 0x03, 0x00, 0x00, 0x01, 0x04, 0xFF]
    decoded = codec_server_signals.deserialize_from_bytes(payload_as_bytes)
    assert_equal([{"network_id" => 1, "add_child" => 5},{"network_id" => 1, "lost_child" => 5},{"network_id" => 1, "alarm" => "too_many_reboot"},{"network_id" => 1, "temperature" => 200.0}], decoded)

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
          measurement XOR(3;0x01:position;0x02:battery_percent;0x03:battery_status;0x04:device_index)
          measurements LIST_XOR(measurement)
      CFG

    parser = ConfiguratorParser.new
    ast = parser.parse(config) or raise Json2Bits::ConfigurationError, parser.failure_reason
    assert ast
    codecs = ast.value

    # Keys coming from the parser are strings
    measurements = codecs.key_2_codec("measurements")
    assert measurements.is_a?(CodecListXor)

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

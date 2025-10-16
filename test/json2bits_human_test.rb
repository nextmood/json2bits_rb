require "test_helper"

class Json2BitsHumanTest < Minitest::Test
  SAMPLE_CONFIG = <<~CFG
    nb_bit_key_binary=6
    0x01 accelerometer_kpi SYMBOL(no_alarm;motion;free_fall;unknown)
    0x02 battery_level FLOAT(8;1.5;4.0) // a float coded with 8 bits, value range from 1.5 to 4.0
    0x03 resync_kpi INTEGER(4)
    0x04 reboot_kpi INTEGER(4) alarm=12
    0x05 stability_kpi SEQUENCE(resync_kpi;reboot_kpi)
    0x06 module_code HEXA(2)
    0x07 modules ARRAY(3;module_code)
    0x08 device_mac HEXA(6) // a mac adress coded with 6 bytes
    0x09 adding_child ALIAS(device_mac) signal
    0x0A alert VOID signal
    0x0B log_category SYMBOL(info;warn;error;debug)
    0x0C log_level SYMBOL(low;medium;high)
    0x0D logs ARRAY(2;log_category;log_level)
    0x0E index_short INTEGER(4)
    0x0F index_long INTEGER(9)
    0x10 device_index XOR(index_short;index_long)
    0x11 constant STATIC(true)
    0x12 raw_payload BYTES(4)
    0x13 flag BOOLEAN
    0x14 wildcard XOR(*)
    0x1C sequence_with_message SEQUENCE(resync_kpi;message)
    0x1D array_with_message ARRAY(3;message)
    0x1E xor_with_message XOR(message;module_code)
    0x1F index_ultra_short INTEGER(3)
  CFG

  def setup
    @configuration = Json2Bits::Configuration.parse(SAMPLE_CONFIG)
    @serializer = Json2Bits::Serializer.new(@configuration)
  end

  # 0x13 flag BOOLEAN
  def test_boolean_codec
    bytes, bit_length = @serializer.serialize("flag", true)
    assert_equal [0b10000000], bytes.bytes
    assert_equal 1, bit_length

    bytes, bit_length = @serializer.serialize("flag", false)
    assert_equal [0b00000000], bytes.bytes
    assert_equal 1, bit_length

    fragment = @serializer.deserialize("flag", bytes)
    assert_equal({ "flag" => false }, fragment)
  end

  # 0x03 resync_kpi INTEGER(4)
  def test_integer_codec
    bytes, bit_length = @serializer.serialize("resync_kpi", 12)
    assert_equal [0b11000000], bytes.bytes
    assert_equal 4, bit_length

    fragment = @serializer.deserialize("resync_kpi", bytes)
    assert_equal({ "resync_kpi" => 12 }, fragment)
    
  end

  # 0x0F index_long INTEGER(9)
  def test_integer_codec_bis
    bytes, bit_length = @serializer.serialize("index_long", 363)
    assert_equal [0b10110101, 0b10000000], bytes.bytes
    assert_equal 9, bit_length

    fragment = @serializer.deserialize("index_long", bytes)
    assert_equal({ "index_long" => 363 }, fragment)
    
  end

  # 0x02 battery_level FLOAT(8;1.5;4.0)
  def test_float_codec
    bytes, bit_length = @serializer.serialize("battery_level", 1.5)
    assert_equal [0], bytes.bytes
    assert_equal 8, bit_length

    bytes, bit_length = @serializer.serialize("battery_level", 4.0)
    assert_equal [255], bytes.bytes
    assert_equal 8, bit_length

    bytes, bit_length = @serializer.serialize("battery_level", 3.3)
    assert_equal [184], bytes.bytes
    assert_equal 8, bit_length

    fragment = @serializer.deserialize("battery_level", bytes)
    assert_equal({ "battery_level" => 3.303921568627451 }, fragment)
  end

  # 0x12 raw_payload BYTES(4)
  def test_fix_nb_bytes_codec
    bytes, bit_length = @serializer.serialize("raw_payload", [11, 23, 252, 15])
    assert_equal [11, 23, 252, 15], bytes.bytes
    assert_equal 32, bit_length

    fragment = @serializer.deserialize("raw_payload", bytes)
    assert_equal({ "raw_payload" => [11, 23, 252, 15] }, fragment)
  end

  # 0x06 module_code HEXA(2)
  def test_hexa_codec
    bytes, bit_length = @serializer.serialize("module_code", "0x1234")
    assert_equal [0x12, 0x34], bytes.bytes
    assert_equal 16, bit_length

    fragment = @serializer.deserialize("module_code", bytes)
    assert_equal({ "module_code" => "0x1234" }, fragment)
  end

  
  # 0x04 reboot_kpi INTEGER(4) alarm=12
  def test_static_codec
    bytes, bit_length = @serializer.serialize("reboot_kpi", 9)
    # Static fields are appended automatically; no duplicate keys required.
    assert_equal 4, bit_length

    fragment = @serializer.deserialize("reboot_kpi", bytes)
    assert_equal({ "reboot_kpi" => 9, "alarm" => 12 }, fragment)
  end

  # 0x01 accelerometer_kpi SYMBOL(no_alarm;motion;free_fall;unknown)
  def test_symbol_codec
    bytes, bit_length = @serializer.serialize("accelerometer_kpi", "no_alarm")
    assert_equal [0b00000000], bytes.bytes
    assert_equal 2, bit_length

    bytes, bit_length = @serializer.serialize("accelerometer_kpi", "motion")
    assert_equal [0b01000000], bytes.bytes
    assert_equal 2, bit_length

    bytes, bit_length = @serializer.serialize("accelerometer_kpi", "free_fall")
    assert_equal [0b10000000], bytes.bytes
    assert_equal 2, bit_length

    bytes, bit_length = @serializer.serialize("accelerometer_kpi", "unknown")
    assert_equal [0b11000000], bytes.bytes
    assert_equal 2, bit_length

    fragment = @serializer.deserialize("accelerometer_kpi", bytes)
    assert_equal({ "accelerometer_kpi" => "unknown" }, fragment)
  end

  # 0x05 stability_kpi SEQUENCE(resync_kpi;reboot_kpi)
  # 0x03 resync_kpi INTEGER(4)
  # 0x04 reboot_kpi INTEGER(4) alarm=12
  def test_sequence_codec

    fragment = { "stability_kpi" => {
        "resync_kpi" => 3,
        "reboot_kpi" => 2
        } 
    }

    bytes, bit_length = @serializer.serialize("stability_kpi", fragment["stability_kpi"])
    assert_equal bytes.size, 1
    assert_equal bit_length, 8
    decoded = @serializer.deserialize("stability_kpi", bytes)

    assert_equal fragment, decoded
    assert_equal 8, bit_length
  end

  # 0x07 modules ARRAY(3;module_code)
  # 0x06 module_code HEXA(2)
  def test_array_codec
    fragment = {
      "modules" => ["0x1234", "0x5678", "0xAA78"]
    }

    bytes, bit_length = @serializer.serialize("modules", fragment["modules"])
    nb_bit = 3 + fragment["modules"].size * 16
    assert_equal nb_bit, bit_length
    assert_equal bytes.size, (nb_bit / 8.0).ceil
    #assert_equal 0b01000010, bytes.bytes[0]  #& 0b11111111 # the first 3 bits match 2 modules
    assert_equal 0b01100010, bytes.bytes[0]     #& 0b11111000 # the first 3 bits match 3 modules
    decoded = @serializer.deserialize("modules", bytes)
    assert_equal fragment, decoded
  end

  # 0x0D logs ARRAY(2;log_category;log_level)
  # 0x0B log_category SYMBOL(info;warn;error;debug)
  # 0x0C log_level SYMBOL(low;medium;high)
  def test_array_with_composite_elements
    fragment = {
      "logs" => [
        { "log_category" => "info", "log_level" => "high" },
        { "log_category" => "warn", "log_level" => "medium" }
      ]
    }

    bytes, bit_length = @serializer.serialize("logs", fragment["logs"])
    nb_bit = 2 + fragment["logs"].size * (2+2)
    assert_equal nb_bit, bit_length
    decoded = @serializer.deserialize("logs", bytes)
    assert_equal fragment, decoded
  end

  # 0x10 device_index XOR(index_short;index_long)
  # 0x0E index_short INTEGER(4)
  # 0x1B index_long INTEGER(9)
  def test_xor_codec_with_long_index
    fragment = { "device_index" => { "index_long" => 300 } }
    bytes, bit_length = @serializer.serialize("device_index", fragment["device_index"])
    assert_equal 1 + 9, bit_length

    decoded = @serializer.deserialize("device_index", bytes)
    assert_equal fragment, decoded
  end

  # 0x10 device_index XOR(index_short;index_long)
  # 0x0E index_short INTEGER(4)
  # 0x1B index_long INTEGER(9)
  def test_xor_codec_with_short_index
    fragment = { "device_index" => { "index_short" => 7 } }
    bytes, bit_length = @serializer.serialize("device_index", fragment["device_index"])
    decoded = @serializer.deserialize("device_index", bytes)
    assert_equal 1 + 4, bit_length
    assert_equal fragment, decoded
  end

  # 0x02 battery_level FLOAT(8;1.5;4.0)
  # 0x14 wildcard XOR(*)
  # 0x03 resync_kpi INTEGER(4)
  def test_xor_wildcard_codec
    options = @configuration.definitions.map(&:name) - ["wildcard"]
    selector_bits = options.length <= 1 ? 0 : Math.log2(options.length).ceil

    value = { "battery_level" => 3.0 }
    bytes, bit_length = @serializer.serialize("wildcard", value)
    decoded = @serializer.deserialize("wildcard", bytes)

    assert_in_delta 3.0, decoded["wildcard"]["battery_level"], 0.01
    assert_equal selector_bits + 8, bit_length

    second_value = { "resync_kpi" => 5 }
    second_bytes, second_bits = @serializer.serialize("wildcard", second_value)
    second_decoded = @serializer.deserialize("wildcard", second_bytes)

    assert_equal second_value, second_decoded["wildcard"]
    assert_equal selector_bits + 4, second_bits
  end

  # 0x1C sequence_with_message SEQUENCE(resync_kpi;message)
  # 0x03 resync_kpi INTEGER(4)
  # 0x0A alert VOID signal
  # 0x1F index_ultra_short INTEGER(3)

  def test_sequence_with_message_reserved_keyword
    payload = {
      "resync_kpi" => 5,
      "message" => [
        { "index_ultra_short" => 6 },
        { "alert" => true, "signal" => true }
      ]
    }
    # 4 bits resync_kpi
    # 6 bits message selector => index_ultra_short 0x1F
    # 3 bits index_ultra_short
    # 6 bits message selector => alert 0x0A
    # 0 bits payload
    _, resync_bits = @serializer.serialize("resync_kpi", payload["resync_kpi"])
    _, message_bits = @serializer.serialize(payload["message"])
    nb_bit = resync_bits + message_bits
    assert_equal nb_bit, 4 + 6 + 3 + 6 + 0
    bytes, bit_length = @serializer.serialize("sequence_with_message", payload)

    assert_equal nb_bit, bit_length
    decoded = @serializer.deserialize("sequence_with_message", bytes)

    decoded_value = decoded["sequence_with_message"]
    assert_equal 5, decoded_value["resync_kpi"]
    assert_equal 6, decoded_value["message"].first["index_ultra_short"]
    assert_equal true, decoded_value["message"][1]["alert"]

    bit_string = bytes.unpack1("B*")[0, bit_length]
    refute_equal "0" * @configuration.key_bit_size, bit_string[-@configuration.key_bit_size, @configuration.key_bit_size]
  end

  # 0x1D array_with_message ARRAY(3;message)
  # 0x02 battery_level FLOAT(8;1.5;4.0)
  # 0x03 resync_kpi INTEGER(4)
  # 0x04 reboot_kpi INTEGER(4) alarm=12
  def test_array_with_message_reserved_keyword
    value = [
      [{ "battery_level" => 2.0 }],
      [{ "resync_kpi" => 4 }, { "reboot_kpi" => 1 }]
    ]

    bytes, bit_length = @serializer.serialize("array_with_message", value)
    decoded = @serializer.deserialize("array_with_message", bytes)

    decoded_array = decoded["array_with_message"]
    assert_in_delta 2.0, decoded_array.first.first["battery_level"], 0.01
    assert_equal 4, decoded_array.last.first["resync_kpi"]
    array_codec = @configuration.definition("array_with_message").codec
    length_bits = array_codec.instance_variable_get(:@length_bits)
    terminator_bits = @configuration.key_bit_size
    expected_bits = length_bits + value.sum do |message|
      _, message_bits = @serializer.serialize(message)
      message_bits + terminator_bits
    end
    assert_equal expected_bits, bit_length
  end

  # 0x1E xor_with_message XOR(message;module_code)
  def test_xor_with_message_reserved_keyword
    message_branch = { "message" => [{ "battery_level" => 2.4 }] }
    bytes, bit_length = @serializer.serialize("xor_with_message", message_branch)
    decoded = @serializer.deserialize("xor_with_message", bytes)

    decoded_message = decoded["xor_with_message"]
    assert_in_delta 2.4, decoded_message["message"].first["battery_level"], 0.01
    xor_codec = @configuration.definition("xor_with_message").codec
    selector_bits = xor_codec.instance_variable_get(:@bits)
    _, message_bits = @serializer.serialize(message_branch["message"])
    assert_equal selector_bits + message_bits, bit_length

    alt_branch = { "module_code" => "0xAABB" }
    alt_bytes, alt_bits = @serializer.serialize("xor_with_message", alt_branch)
    alt_decoded = @serializer.deserialize("xor_with_message", alt_bytes)

    assert_equal alt_branch, alt_decoded["xor_with_message"]
    _, module_bits = @serializer.serialize("module_code", alt_branch["module_code"])
    assert_equal selector_bits + module_bits, alt_bits
  end

  # 0x11 constant STATIC(true)
  def test_static_codec_roundtrip
    bytes, bit_length = @serializer.serialize("constant", true)
    decoded = @serializer.deserialize("constant", bytes)

    assert_equal({ "constant" => true }, decoded)
    assert_equal 0, bit_length
  end

  # 0x12 raw_payload BYTES(4)
  def test_bytes_codec_roundtrip
    fragment = { "raw_payload" => [0xDE, 0xAD, 0xBE, 0xEF] }

    bytes, bit_length = @serializer.serialize("raw_payload", fragment["raw_payload"])
    decoded = @serializer.deserialize("raw_payload", bytes)

    assert_equal fragment, decoded
    assert_equal 32, bit_length
  end

  # 0x01 accelerometer_kpi SYMBOL(no_alarm;motion;free_fall;unknown)

  def test_message_serialization_roundtrip
    message = [
      { "accelerometer_kpi" => "free_fall" },
      { "battery_level" => 2.25 },
      { "adding_child" => "0xA1B2C3D4E5F6", "signal" => true },
      { "alert" => true, "signal" => true }
    ]

    bytes, bit_length = @serializer.serialize(message)
    decoded = @serializer.deserialize(bytes)

    assert_equal message.length, decoded.length
    assert_equal message[0], decoded[0]
    assert_in_delta message[1]["battery_level"], decoded[1]["battery_level"], 0.01
    assert_equal message[2], decoded[2]
    assert_equal message[3], decoded[3]
    assert_equal 82, bit_length
  rescue Json2Bits::SerializationError => e
    flunk "serialization failed: #{e.message}"
  end

  def test_static_field_validation
    fragment = { "adding_child" => "0xA1B2C3D4E5F6", "signal" => false }
    assert_raises(Json2Bits::SerializationError) do
      @serializer.serialize([fragment])
    end
  end

  def test_unknown_definition_detection
    assert_raises(Json2Bits::SerializationError) do
      @serializer.serialize({ "unknown" => 1 })
    end
  end
end

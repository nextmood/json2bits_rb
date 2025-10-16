require "test_helper"

class Json2BitsTest < Minitest::Test
  SAMPLE_CONFIG = <<~CFG
    nb_bit_key_binary=8
    0x01 accelerometer_kpi SYMBOL(no_alarm;motion;free_fall)
    0x02 battery_level FLOAT(8;1.5;4.0)
    0x03 resync_kpi INTEGER(4)
    0x04 reboot_kpi INTEGER(4)
    0x05 stability_kpi SEQUENCE(resync_kpi;reboot_kpi)
    0x06 module_code HEXA(2)
    0x07 modules ARRAY(3;module_code)
    0x08 device_mac HEXA(6)
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
    0x13 wildcard_fragment XOR(*)
    0x1C bundle_with_message SEQUENCE(log_category;message)
    0x1D message_array ARRAY(4;message)
    0x1E message_choice XOR(message;module_code)
  CFG

  def setup
    @configuration = Json2Bits::Configuration.parse(SAMPLE_CONFIG)
    @serializer = Json2Bits::Serializer.new(@configuration)
  end

  def test_configuration_parsing
    definition = @configuration.definition("adding_child")
    assert_equal 0x09, definition.binary_key
    assert_equal({ "signal" => true }, definition.static_fields)

    xor = @configuration.definition("device_index")
    assert_instance_of Json2Bits::Codecs::Xor, xor.codec

    wildcard = @configuration.definition("wildcard_fragment")
    assert_instance_of Json2Bits::Codecs::Xor, wildcard.codec
  end

  def test_symbol_codec_roundtrip
    bytes, bit_length = @serializer.serialize("accelerometer_kpi", "motion")
    assert_equal [0x40], bytes.bytes
    assert_equal 2, bit_length

    fragment = @serializer.deserialize("accelerometer_kpi", bytes)
    assert_equal({ "accelerometer_kpi" => "motion" }, fragment)
  end

  def test_serialize_requires_value
    error = assert_raises(ArgumentError) do
      @serializer.serialize("accelerometer_kpi")
    end
    assert_match(/value is required/, error.message)

    wrapped_error = assert_raises(ArgumentError) do
      @serializer.serialize("accelerometer_kpi", { "accelerometer_kpi" => "motion" })
    end
    assert_match(/should not include the definition key/, wrapped_error.message)
  end

  def test_sequence_codec_roundtrip
    fragment = {
      "stability_kpi" => {
        "resync_kpi" => 3,
        "reboot_kpi" => 2
      }
    }

    bytes, bit_length = @serializer.serialize("stability_kpi", {
      "resync_kpi" => 3,
      "reboot_kpi" => 2
    })
    decoded = @serializer.deserialize("stability_kpi", bytes)

    assert_equal fragment, decoded
    assert_equal 8, bit_length
  end

  def test_array_codec_roundtrip
    fragment = {
      "modules" => ["0x1234", "0x5678", "0x9ABC"]
    }

    bytes, bit_length = @serializer.serialize("modules", fragment["modules"])
    decoded = @serializer.deserialize("modules", bytes)

    assert_equal fragment, decoded
    assert_equal 51, bit_length
  end

  def test_array_with_composite_elements
    fragment = {
      "logs" => [
        { "log_category" => "info", "log_level" => "high" },
        { "log_category" => "warn", "log_level" => "medium" }
      ]
    }

    bytes, bit_length = @serializer.serialize("logs", fragment["logs"])
    decoded = @serializer.deserialize("logs", bytes)

    assert_equal fragment, decoded
    assert_equal 10, bit_length
  end

  def test_xor_codec_roundtrip_with_long_index
    fragment = { "device_index" => { "index_long" => 300 } }
    bytes, bit_length = @serializer.serialize("device_index", fragment["device_index"])
    decoded = @serializer.deserialize("device_index", bytes)

    assert_equal fragment, decoded
    assert_equal 10, bit_length
  end

  def test_xor_codec_roundtrip_with_short_index
    fragment = { "device_index" => { "index_short" => 7 } }
    bytes, bit_length = @serializer.serialize("device_index", fragment["device_index"])
    decoded = @serializer.deserialize("device_index", bytes)

    assert_equal fragment, decoded
    assert_equal 5, bit_length
  end

  def test_xor_wildcard_roundtrip
    options = @configuration.definitions.map(&:name).map(&:to_s) - ["wildcard_fragment"]
    selector_bits = options.length <= 1 ? 0 : Math.log2(options.length).ceil

    value = { "battery_level" => 2.5 }
    bytes, bit_length = @serializer.serialize("wildcard_fragment", value)
    decoded = @serializer.deserialize("wildcard_fragment", bytes)

    assert_in_delta 2.5, decoded["wildcard_fragment"]["battery_level"], 0.01
    assert_equal selector_bits + 8, bit_length

    alt_value = { "resync_kpi" => 7 }
    alt_bytes, alt_bits = @serializer.serialize("wildcard_fragment", alt_value)
    alt_decoded = @serializer.deserialize("wildcard_fragment", alt_bytes)

    assert_equal alt_value, alt_decoded["wildcard_fragment"]
    assert_equal selector_bits + 4, alt_bits
  end

  def test_sequence_with_message_placeholder
    message_value = [
      { "battery_level" => 2.75 },
      { "alert" => true, "signal" => true }
    ]
    payload = {
      "log_category" => "info",
      "message" => message_value
    }

    bytes, bit_length = @serializer.serialize("bundle_with_message", payload)
    decoded = @serializer.deserialize("bundle_with_message", bytes)

    decoded_value = decoded["bundle_with_message"]

    assert_equal "info", decoded_value["log_category"]
    assert_equal true, decoded_value["message"][1]["alert"]
    assert_in_delta 2.75, decoded_value["message"].first["battery_level"], 0.01
    _, log_bits = @serializer.serialize("log_category", payload["log_category"])
    _, message_bits = @serializer.serialize(payload["message"])
    assert_equal log_bits + message_bits, bit_length

    bit_string = bytes.unpack1("B*")[0, bit_length]
    refute_equal "0" * @configuration.key_bit_size, bit_string[-@configuration.key_bit_size, @configuration.key_bit_size]
  end

  def test_array_of_messages
    value = [
      [{ "battery_level" => 2.0 }],
      [{ "resync_kpi" => 3 }, { "reboot_kpi" => 1 }]
    ]

    bytes, bit_length = @serializer.serialize("message_array", value)
    decoded = @serializer.deserialize("message_array", bytes)

    assert_equal value, decoded["message_array"]
    array_codec = @configuration.definition("message_array").codec
    length_bits = array_codec.instance_variable_get(:@length_bits)
    terminator_bits = @configuration.key_bit_size
    expected_bits = length_bits + value.sum do |message|
      _, message_bits = @serializer.serialize(message)
      message_bits + terminator_bits
    end
    assert_equal expected_bits, bit_length
  end

  def test_xor_with_message_option
    message_branch = { "message" => [{ "battery_level" => 2.3 }] }
    bytes, bit_length = @serializer.serialize("message_choice", message_branch)
    decoded = @serializer.deserialize("message_choice", bytes)

    decoded_message = decoded["message_choice"]
    assert_in_delta 2.3, decoded_message["message"].first["battery_level"], 0.01
    selector_bits = @configuration.definition("message_choice").codec.instance_variable_get(:@bits)
    _, message_bits = @serializer.serialize(message_branch["message"])
    assert_equal selector_bits + message_bits, bit_length

    alt_branch = { "module_code" => "0xAABB" }
    alt_bytes, alt_bits = @serializer.serialize("message_choice", alt_branch)
    alt_decoded = @serializer.deserialize("message_choice", alt_bytes)

    assert_equal alt_branch, alt_decoded["message_choice"]
    _, module_bits = @serializer.serialize("module_code", alt_branch["module_code"])
    assert_equal selector_bits + module_bits, alt_bits
  end

  def test_static_codec_roundtrip
    bytes, bit_length = @serializer.serialize("constant", true)
    decoded = @serializer.deserialize("constant", bytes)

    assert_equal({ "constant" => true }, decoded)
    assert_equal 0, bit_length
  end

  def test_bytes_codec_roundtrip
    fragment = { "raw_payload" => [0xDE, 0xAD, 0xBE, 0xEF] }

    bytes, bit_length = @serializer.serialize("raw_payload", [0xDE, 0xAD, 0xBE, 0xEF])
    decoded = @serializer.deserialize("raw_payload", bytes)

    assert_equal fragment, decoded
    assert_equal 32, bit_length
  end

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
    assert_equal 90, bit_length
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

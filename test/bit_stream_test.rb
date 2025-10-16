# == Schema Information
#

require "test_helper"

class BitStreamTest < Minitest::Test
  def test_read_bits_consumes_bits_in_msb_order
    stream = BitStream.new(bytes: [0b11001010, 0b01101100])

    assert_equal 0b1100, stream.read_bits(4)
    assert_equal 0b101, stream.read_bits(3)
    assert_equal 0b001, stream.read_bits(3)
    assert_equal 0b101100, stream.read_bits(6)
  end

  
  def test_read_bits_raises_when_request_exceeds_available
    stream = BitStream.new(bytes: [0b11110000])
    stream.read_bits(8)

    assert_raises(Json2Bits::NoMoreBitsError) { stream.read_bits(1) }
  end

  def test_write_bits_packs_bits_across_byte_boundaries
    stream = BitStream.new
    stream.write_bits(0b101, 3)
    stream.write_bits(0b001101, 6)
    stream.write_bits(0b1110000, 7)

    bytes = stream.instance_variable_get(:@bytes)
    assert_equal [0b10100110, 0b11110000], bytes

    readable = BitStream.new(bytes: bytes)
    assert_equal 0b101, readable.read_bits(3)
    assert_equal 0b001101, readable.read_bits(6)
    assert_equal 0b1110000, readable.read_bits(7)
  end
end

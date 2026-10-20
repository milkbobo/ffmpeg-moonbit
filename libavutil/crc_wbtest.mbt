///|
/// Whitebox tests for the `crc` port.
///
/// Expected values are the raw `av_crc` outputs recorded in
/// `tests/ref/fate/crc`, produced by `libavutil/tests/crc.c` over a buffer with
/// `buf[i] = i + i*i`. The table prefixes are taken from the hardcoded tables in
/// `libavutil/crc.c` and validate the table generator directly.

///|
/// `tests/ref/fate/crc`: `av_crc(table, 0, buf, 1999)`. */
test "av_crc matches fate/crc reference" {
  let buf : FixedArray[Byte] = FixedArray::make(1999, b'\x00')
  for i = 0; i < 1999; i = i + 1 {
    buf[i] = (i + i * i).reinterpret_as_uint().to_byte()
  }
  let data = Bytes::from_array(buf[:])
  let cases : Array[(AVCRCId, UInt32)] = [
    (AVCRCId::Crc32IeeeLe, 0x3D5CDD04),
    (AVCRCId::Crc32Ieee, 0xE0BAF5C0),
    (AVCRCId::Crc24Ieee, 0x326039),
    (AVCRCId::Crc16AnsiLe, 0xBFD8),
    (AVCRCId::Crc16Ansi, 0xBB1F),
    (AVCRCId::Crc8Atm, 0xE3),
    (AVCRCId::Crc8Ebu, 0xD6),
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let (id, expected) = cases[i]
    let table = av_crc_get_table(id).unwrap()
    assert_eq(av_crc(table, 0, data), expected)
  }
}

///|
/// Compare generated tables against the hardcoded tables in libavutil/crc.c. */
test "generated tables match the hardcoded crc.c tables" {
  let crc8_atm : Array[UInt32] = [
    0x00, 0x07, 0x0E, 0x09, 0x1C, 0x1B, 0x12, 0x15,
  ]
  let crc16_ansi_le : Array[UInt32] = [
    0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241,
  ]
  let crc16_ccitt : Array[UInt32] = [
    0x0000, 0x2110, 0x4220, 0x6330, 0x8440, 0xA550, 0xC660, 0xE770,
  ]
  let crc24_ieee : Array[UInt32] = [
    0x000000, 0xFB4C86, 0x0DD58A, 0xF6990C, 0xE1E693, 0x1AAA15, 0xEC3319, 0x177F9F,
  ]
  let crc8_ebu : Array[UInt32] = [
    0x00, 0x1D, 0x3A, 0x27, 0x74, 0x69, 0x4E, 0x53,
  ]
  let crc32_ieee : Array[UInt32] = [
    0x00000000, 0xB71DC104, 0x6E3B8209, 0xD926430D, 0xDC760413, 0x6B6BC517, 0xB24D861A,
    0x0550471E,
  ]
  let crc32_ieee_le : Array[UInt32] = [
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535,
    0x9E6495A3,
  ]
  let checks : Array[(AVCRCId, Array[UInt32])] = [
    (AVCRCId::Crc8Atm, crc8_atm),
    (AVCRCId::Crc8Ebu, crc8_ebu),
    (AVCRCId::Crc16AnsiLe, crc16_ansi_le),
    (AVCRCId::Crc16Ccitt, crc16_ccitt),
    (AVCRCId::Crc24Ieee, crc24_ieee),
    (AVCRCId::Crc32Ieee, crc32_ieee),
    (AVCRCId::Crc32IeeeLe, crc32_ieee_le),
  ]
  for i = 0; i < checks.length(); i = i + 1 {
    let (id, expected) = checks[i]
    let table = av_crc_get_table(id).unwrap()
    for k = 0; k < expected.length(); k = k + 1 {
      assert_eq(table[k], expected[k])
    }
    // The 257-entry table carries the same `1` sentinel as the C hardcoded tables.
    assert_eq(table[256], 1)
  }
}

///|
/// `av_crc_init` rejects parameters outside `bits in [8, 32]`. */
test "av_crc_init rejects invalid parameters" {
  assert_true(av_crc_init(false, 7, 0x07) is Err(_))
  assert_true(av_crc_init(false, 33, 0x07) is Err(_))
  assert_true(av_crc_init(false, 8, 0x100) is Err(_))
  assert_true(av_crc_init(true, 16, 0xA001) is Ok(_))
}

///|
/// Incremental CRC over two chunks equals the one-shot CRC over the join. */
test "av_crc is incremental" {
  let table = av_crc_get_table(AVCRCId::Crc32IeeeLe).unwrap()
  let whole = b"123456789"
  let split = av_crc(table, av_crc(table, 0, b"1234"), b"56789")
  assert_eq(split, av_crc(table, 0, whole))
}

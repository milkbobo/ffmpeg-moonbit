///|
/// White-box tests for the `get_bits.h`/`golomb.h` port.
///
/// Exp-Golomb expectations are the code table from ITU-T H.264 / ISO/IEC
/// 14496-10 Table 9-1 (and the identical H.265 Table 9-1): `1`, `010`,
/// `011`, `00100`, ... enumerate 0, 1, 2, 3, ...; the signed form maps
/// 1, 2, 3, 4... to 0, 1, -1, 2... . Bit-position and overread checks follow
/// `get_bits.h`'s documented `get_bits_left` semantics.
test "bitstream: get_bits MSB-first and position accounting" {
  let b = b"\xB5\x00\xA0" // 1011 0101 0000 0000 1010 0000
  let gb = BitReader::new(b)
  assert_eq(gb.read(1), 1U)
  assert_eq(gb.read(3), 0b011U)
  assert_eq(gb.read(4), 0x5U)
  assert_eq(gb.count(), 8)
  assert_eq(gb.read(8), 0U)
  assert_eq(gb.read(4), 0xAU)
  assert_eq(gb.bits_left(), 4)
  assert_eq(gb.bytesize(true), 3)
}

///|
test "bitstream: show/peek does not consume, skip and align do" {
  let gb = BitReader::new(b"\x12\x34\x56")
  assert_eq(gb.show(4), 0x1U)
  assert_eq(gb.count(), 0)
  gb.skip(5)
  assert_eq(gb.show(3), 0b010U) // bits 5..7 of 0001 0010
  gb.align()
  assert_eq(gb.count(), 8)
  assert_eq(gb.read(8), 0x34U)
}

///|
test "bitstream: reads past the end return zero and go negative" {
  let gb = BitReader::with_size(b"\x80", 8)
  assert_eq(gb.read(8), 0x80U)
  assert_eq(gb.bits_left(), 0)
  assert_eq(gb.read(4), 0U)
  assert_eq(gb.count(), 12)
  assert_eq(gb.bits_left(), -4)
}

///|
test "bitstream: unsigned Exp-Golomb H.264 Table 9-1" {
  // 1 010 011 00100 00101 00110 00111 0001000
  // = 1010 0110 0100 0010 1001 1000 1110 0010 00
  let gb = BitReader::new(b"\xA6\x42\x98\xE2")
  assert_eq(gb.read_ue(), 0) // 1
  assert_eq(gb.read_ue(), 1) // 010
  assert_eq(gb.read_ue(), 2) // 011
  assert_eq(gb.read_ue(), 3) // 00100
  assert_eq(gb.read_ue(), 4) // 00101
  assert_eq(gb.read_ue(), 5) // 00110
  assert_eq(gb.read_ue(), 6) // 00111
  assert_eq(gb.read_ue(), 7) // 0001000
}

///|
test "bitstream: signed Exp-Golomb H.264 Table 9-1" {
  // se mapping: ue 0→0, 1→1, 2→-1, 3→2, 4→-2, 5→3
  // 1 010 011 00100 00101 00110 = 1010 0110 0100 0010 1001 10
  let gb = BitReader::new(b"\xA6\x42\x98")
  assert_eq(gb.read_se(), 0)
  assert_eq(gb.read_se(), 1)
  assert_eq(gb.read_se(), -1)
  assert_eq(gb.read_se(), 2)
  assert_eq(gb.read_se(), -2)
  assert_eq(gb.read_se(), 3)
}

///|
test "bitstream: ue long handles values beyond 31 and the zero window" {
  // ue(32) = 00000100001 (5 leading zeros, 6-bit suffix 100001=33)
  // followed by ue(0) = 1: 000001000011
  let gb = BitReader::new(b"\x04\x30")
  assert_eq(gb.read_ue_long(), 32UL)
  assert_eq(gb.read_ue_long(), 0UL)
  // Force the all-zero 32-bit window: 32 zeros, C's log becomes 31.
  // C: log = 31 - av_log2(0) = 31; skip 31, then read 32 bits starting at
  // bit 31 (0 followed by the 1 at bit 32): 0x40000000 - 1.
  let z = BitReader::new(b"\x00\x00\x00\x00\x80")
  assert_eq(z.read_ue_long(), 0x3FFFFFFFUL)
}

///|
test "bitstream: ue overread is invalid" {
  let gb = BitReader::new(b"\x00\x00\x00\x00")
  // AVERROR_INVALIDDATA's role: outside 0..8190 and propagated by read_se.
  assert_eq(gb.read_ue(), -2147483648)
  let gb2 = BitReader::new(b"\x00\x00\x00\x00")
  assert_eq(gb2.read_se(), -2147483648)
}

///|
test "bitstream: ctz8" {
  assert_eq(ctz8(1), 0)
  assert_eq(ctz8(2), 1)
  assert_eq(ctz8(0x80), 7)
  assert_eq(ctz8(0x18), 3)
}

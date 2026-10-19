///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/crc.c` / `crc.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2006
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// The 1024-entry (4-way) table used by the C fast path is a pure speed
/// optimisation and is omitted here: the 257-entry table plus the byte-at-a-time
/// loop yields identical CRC values. `av_crc_init` therefore always produces a
/// 257-entry table whose element 256 carries the same `1` sentinel that the C
/// hardcoded tables contain.

///| CRC ids, same numeric order as `AVCRCId` in libavutil/crc.h. */
pub enum AVCRCId {
  Crc8Atm
  Crc16Ansi
  Crc16Ccitt
  Crc32Ieee
  Crc32IeeeLe
  Crc16AnsiLe
  Crc24Ieee
  Crc8Ebu
}

///| Number of standard CRC ids (the `AV_CRC_MAX` equivalent). */
pub let av_crc_max : Int = 8

///| All standard CRC ids, in the `AVCRCId` order used by libavutil/crc.h. */
pub fn av_crc_ids() -> Array[AVCRCId] {
  [Crc8Atm, Crc16Ansi, Crc16Ccitt, Crc32Ieee, Crc32IeeeLe, Crc16AnsiLe, Crc24Ieee, Crc8Ebu]
}

///| `av_bswap32`: byte-swap a 32-bit value. */
fn crc_bswap32(x : UInt) -> UInt {
  (x >> 24) | ((x >> 8) & 0xFF00) | ((x << 8) & 0xFF0000) | (x << 24)
}

///|
/// `av_crc_init`: build a 257-entry CRC lookup table.
/// Returns `Err` for out-of-range parameters, mirroring `AVERROR(EINVAL)`.
pub fn av_crc_init(le : Bool, bits : Int, poly : UInt) -> Result[FixedArray[UInt], String] {
  let one : UInt64 = 1
  if bits < 8 || bits > 32 || poly.to_uint64() >= (one << bits) {
    return Err("EINVAL")
  }
  let ctx : FixedArray[UInt] = FixedArray::make(257, 0)
  for i = 0; i < 256; i = i + 1 {
    if le {
      let mut c : UInt = i.reinterpret_as_uint()
      for j = 0; j < 8; j = j + 1 {
        let mask : UInt = if (c & 1) != 0 { 0xFFFFFFFF } else { 0 }
        c = (c >> 1) ^ (poly & mask)
      }
      ctx[i] = c
    } else {
      let mut c : UInt = i.reinterpret_as_uint() << 24
      for j = 0; j < 8; j = j + 1 {
        let mask : UInt = if c.reinterpret_as_int() < 0 { 0xFFFFFFFF } else { 0 }
        c = (c << 1) ^ ((poly << (32 - bits)) & mask)
      }
      ctx[i] = crc_bswap32(c)
    }
  }
  ctx[256] = 1
  Ok(ctx)
}

///|
/// `av_crc_get_table`: return the standard table for a CRC id.
/// Equivalent to `av_crc_get_table` in libavutil/crc.c, which lazily
/// initialises the table described by the `DECLARE_CRC_INIT_TABLE_ONCE` rows.
pub fn av_crc_get_table(crc_id : AVCRCId) -> Result[FixedArray[UInt], String] {
  let spec : (Bool, Int, UInt) = match crc_id {
    Crc8Atm => (false, 8, 0x07)
    Crc8Ebu => (false, 8, 0x1D)
    Crc16Ansi => (false, 16, 0x8005)
    Crc16Ccitt => (false, 16, 0x1021)
    Crc24Ieee => (false, 24, 0x864CFB)
    Crc32Ieee => (false, 32, 0x04C11DB7)
    Crc32IeeeLe => (true, 32, 0xEDB88320)
    Crc16AnsiLe => (true, 16, 0xA001)
  }
  let (le, bits, poly) = spec
  av_crc_init(le, bits, poly)
}

///|
/// `av_crc`: update `crc` with `buffer`, byte at a time.
pub fn av_crc(ctx : FixedArray[UInt], crc : UInt, buffer : Bytes) -> UInt {
  let mut crc = crc
  for i = 0; i < buffer.length(); i = i + 1 {
    let idx = (crc ^ buffer[i].to_uint()) & 0xFF
    crc = ctx[idx.reinterpret_as_int()] ^ (crc >> 8)
  }
  crc
}

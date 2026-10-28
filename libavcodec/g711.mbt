///|
/// G.711 A-law / µ-law decoders, ported from the `alaw2linear` /
/// `ulaw2linear` helpers in FFmpeg's `libavcodec/pcm_tablegen.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `alaw2linear`: A-law byte to signed 16-bit PCM.
fn g711_alaw_to_linear(byte : Int32) -> Int32 {
  let a = byte ^ 0x55
  let quant = a & 0x0F
  let seg = (a & 0x70) >> 4
  let t = if seg != 0 {
    (quant + quant + 1 + 32) << (seg + 2)
  } else {
    (quant + quant + 1) << 3
  }
  if (a & 0x80) != 0 {
    t
  } else {
    -t
  }
}

///|
/// Convert a byte of A-law to signed 16-bit PCM.
pub fn pcm_alaw_decode(data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  for byte in data {
    out.push(g711_alaw_to_linear(byte.to_int()))
  }
  out
}

///|
/// `ulaw2linear`: µ-law byte to signed 16-bit PCM.
fn g711_ulaw_to_linear(byte : Int32) -> Int32 {
  let u = (byte ^ 0xFF) & 0xFF
  let mut t = ((u & 0x0F) << 3) + 0x84
  t = t << ((u & 0x70) >> 4)
  if (u & 0x80) != 0 {
    0x84 - t
  } else {
    t - 0x84
  }
}

///|
/// Convert a byte of µ-law to signed 16-bit PCM.
pub fn pcm_mulaw_decode(data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  for byte in data {
    out.push(g711_ulaw_to_linear(byte.to_int()))
  }
  out
}

///|
/// `build_xlaw_table`: FFmpeg's 16384-entry linear→A/µ-law conversion table.
fn g711_build_xlaw_table(mask : Int32, alaw : Bool) -> FixedArray[Byte] {
  let table = FixedArray::make(16384, b'\x00')
  let mut j = 1
  table[8192] = mask.to_byte()
  for i = 0; i < 127; i = i + 1 {
    let v1 = if alaw {
      g711_alaw_to_linear(i ^ mask)
    } else {
      g711_ulaw_to_linear(i ^ mask)
    }
    let v2 = if alaw {
      g711_alaw_to_linear((i + 1) ^ mask)
    } else {
      g711_ulaw_to_linear((i + 1) ^ mask)
    }
    let v = (v1 + v2 + 4) >> 3
    while j < v {
      table[8192 - j] = (i ^ (mask ^ 0x80)).to_byte()
      table[8192 + j] = (i ^ mask).to_byte()
      j = j + 1
    }
  }
  while j < 8192 {
    table[8192 - j] = (127 ^ (mask ^ 0x80)).to_byte()
    table[8192 + j] = (127 ^ mask).to_byte()
    j = j + 1
  }
  table[0] = table[1]
  table
}

///|
/// Encode signed 16-bit samples to A-law (`linear_to_alaw`).
pub fn pcm_alaw_encode(samples : ArrayView[Int32]) -> Bytes {
  let table = g711_build_xlaw_table(0xd5, true)
  let out : Array[Byte] = []
  for sample in samples {
    let v = if sample < -32768 {
      -32768
    } else if sample > 32767 {
      32767
    } else {
      sample
    }
    out.push(table[(v + 32768) >> 2])
  }
  Bytes::from_array(out)
}

///|
/// Encode signed 16-bit samples to µ-law (`linear_to_ulaw`).
pub fn pcm_mulaw_encode(samples : ArrayView[Int32]) -> Bytes {
  let table = g711_build_xlaw_table(0xff, false)
  let out : Array[Byte] = []
  for sample in samples {
    let v = if sample < -32768 {
      -32768
    } else if sample > 32767 {
      32767
    } else {
      sample
    }
    out.push(table[(v + 32768) >> 2])
  }
  Bytes::from_array(out)
}

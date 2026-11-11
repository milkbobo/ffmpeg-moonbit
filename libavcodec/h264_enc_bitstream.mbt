///|
/// H.264 RBSP bit writer: the encode-side twin of `bitstream.mbt`'s
/// `BitReader`. MSB-first bits (the same `put_bits` order FFmpeg's writer
/// uses), unsigned/signed Exp-Golomb (`ue`/`se`), `rbsp_trailing_bits` and
/// emulation-prevention escaping on output. Built on the shared
/// `libavcodec.BitWriter` (huffman.mbt).

///|
priv struct H264Rbsp {
  bw : BitWriter
}

///|
fn H264Rbsp::new() -> H264Rbsp {
  { bw: BitWriter::new(), }
}

///|
/// Append the low `n` bits of `value`, most significant bit first. */
fn H264Rbsp::put(self : H264Rbsp, value : Int32, n : Int32) -> Unit {
  if n > 0 {
    self.bw.put(value.reinterpret_as_uint(), n)
  }
}

///|
/// Append one bit. */
fn H264Rbsp::put_bit(self : H264Rbsp, b : Int32) -> Unit {
  self.bw.put_bit(b)
}

///|
/// `ue(v)`: unsigned Exp-Golomb. */
fn H264Rbsp::put_ue(self : H264Rbsp, v : Int32) -> Unit {
  // x = v + 1 has bit length m + 1; emit m zeros, the stop bit, then the
  // m info bits x - 2^m.
  let x = v + 1
  let mut m = 0
  while x >= 1 << (m + 1) {
    m = m + 1
    if m > 30 {
      abort("ue(v) out of range")
    }
  }
  for k = 0; k < m; k = k + 1 {
    self.put_bit(0)
  }
  self.put_bit(1)
  if m > 0 {
    self.put(x - (1 << m), m)
  }
}

///|
/// `se(v)`: signed Exp-Golomb (`ue` of the interleaved mapping). */
fn H264Rbsp::put_se(self : H264Rbsp, v : Int32) -> Unit {
  let code = 2 * (if v > 0 { v } else { -v }) - (if v > 0 { 1 } else { 0 })
  self.put_ue(code)
}

///|
/// Zero bits until byte aligned (`pcm_alignment_zero_bits`). */
fn H264Rbsp::align_zero(self : H264Rbsp) -> Unit {
  while self.bw.nbits != 0 {
    self.put_bit(0)
  }
}

///|
/// `rbsp_trailing_bits`: a stop bit `1` then zero padding to the byte. */
fn H264Rbsp::trailing_bits(self : H264Rbsp) -> Unit {
  self.put_bit(1)
  while self.bw.nbits != 0 {
    self.put_bit(0)
  }
}

///|
/// Finish without emulation prevention: the raw RBSP bytes (what a parser
/// consumes after unescaping; the round-trip tests read these back). */
fn H264Rbsp::finish_raw_of(self : H264Rbsp) -> Bytes {
  self.bw.finish()
}

///|
/// Apply emulation prevention: `00 00 0x` with `x <= 3` becomes
/// `00 00 03 x`. */
fn h264_enc_escape(raw : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut zeros = 0
  for i = 0; i < raw.length(); i = i + 1 {
    let b = raw[i].to_int() & 0xFF
    if zeros >= 2 && b <= 3 {
      out.push(b'\x03')
      zeros = 0
    }
    out.push(raw[i])
    if b == 0 {
      zeros = zeros + 1
    } else {
      zeros = 0
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Finish the RBSP: raw bytes plus emulation prevention. */
fn H264Rbsp::finish(self : H264Rbsp) -> Bytes {
  h264_enc_escape(self.bw.finish())
}

///|
/// Wrap a finished RBSP in a NAL unit (forbidden_zero 0, `nal_ref_idc`,
/// `nal_unit_type`) with a 4-byte Annex B start code prefix. */
fn h264_enc_nal(rbsp : H264Rbsp, ref_idc : Int32, unit_type : Int32) -> Bytes {
  let payload = rbsp.finish()
  let out : Array[Byte] = [
    b'\x00',
    b'\x00',
    b'\x00',
    b'\x01',
    ((ref_idc << 5) | unit_type).to_byte(),
  ]
  for i = 0; i < payload.length(); i = i + 1 {
    out.push(payload[i])
  }
  Bytes::from_array(out[:])
}

///|
/// Access unit delimiter: primary_pic_type 0 (I) or 1 (I/P), followed
/// by rbsp_stop_one_bit. nal_ref_idc is zero (H.264 7.4.1).
fn h264_enc_aud(intra : Bool) -> Bytes {
  if intra {
    b"\x00\x00\x00\x01\x09\x10"
  } else {
    b"\x00\x00\x00\x01\x09\x30"
  }
}

///|
/// FLAC decoder, ported from FFmpeg 9.0.2 `libavcodec/flacdec.c`,
/// `libavcodec/flac.c` (frame header) and `libavcodec/flacdsp.c` /
/// `flacdsp_template.c` (fixed/LPC prediction, wasted bits and channel
/// decorrelation).
///
/// Decodes a complete native FLAC file (`fLaC` + metadata blocks + frames)
/// into interleaved samples in FFmpeg's default output format: S16 for
/// streams up to 16 bits per sample, S32 (left-justified) for wider streams.
///
/// Scope: 8/16/20/24-bit, 1-8 channels, independent/left-side/right-side/
/// mid-side stereo, constant/verbatim/fixed/LPC subframes, Rice partitions
/// with escape codes, wasted bits. 32-bit (33 bps) subframes, foreign metadata
/// and CRC verification are not handled.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Decoded FLAC audio. `samples` is interleaved and already shifted like
/// FFmpeg's default `S16`/`S32` output.
pub struct FlacAudio {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  samples : Array[Int32]
}

///|
/// `ff_flac_sample_rate_table[16]`.
let flac_sample_rates : FixedArray[Int32] = [
  0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000,
  0, 0, 0, 0,
]

///|
/// `ff_flac_blocksize_table[16]`.
let flac_blocksizes : FixedArray[Int32] = [
  0, 192, 576, 1152, 2304, 4608, 0, 0, 256, 512, 1024, 2048, 4096, 8192, 16384,
  32768,
]

///|
/// `sample_size_table[8]`.
let flac_sample_sizes : FixedArray[Int32] = [0, 8, 12, 0, 16, 20, 24, 32]

///|
/// `get_sbits`: signed MSB-first read of `n` <= 32 bits.
fn flac_sbits(gb : BitReader, n : Int32) -> Int32 {
  if n <= 0 {
    return 0
  }
  let v = gb.read(n).reinterpret_as_int()
  if n >= 32 {
    return v
  }
  let sign = 1 << (n - 1)
  if v >= sign {
    v - (sign << 1)
  } else {
    v
  }
}

///|
/// `av_log2` for positive integers.
fn flac_log2(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `get_utf8`: FLAC's UTF-8-coded frame/sample number.
fn flac_utf8(gb : BitReader) -> Result[Int64, String] {
  let b0 = gb.read(8).reinterpret_as_int()
  let mut ones = 0
  let mut mask = 0x80
  while ones < 8 && (b0 & mask) != 0 {
    ones = ones + 1
    mask = mask >> 1
  }
  if ones == 0 {
    return Ok((b0 & 0x7F).to_int64())
  }
  if ones == 1 || ones == 8 {
    return Err("flac: invalid UTF-8 number")
  }
  let mut val = (b0 & ((1 << (7 - ones)) - 1)).to_int64()
  for k = 1; k < ones; k = k + 1 {
    let b = gb.read(8).reinterpret_as_int()
    if (b & 0xC0) != 0x80 {
      return Err("flac: invalid UTF-8 continuation")
    }
    val = (val << 6) | (b & 0x3F).to_int64()
  }
  Ok(val)
}

///|
/// Unary code counting zero bits until a one (`get_unary(gb, 1, len)`).
fn flac_unary(gb : BitReader) -> Int32 {
  let mut n = 0
  while gb.bits_left() > 0 && gb.read1() == 0 {
    n = n + 1
  }
  n
}

///|
/// Unsigned Rice code (`get_ur_golomb_jpegls` with a very large limit),
/// returned as the zig-zag-decoded signed residual.
fn flac_rice(gb : BitReader, k : Int32) -> Result[Int32, String] {
  let mut q = 0
  while gb.bits_left() > 0 && gb.read1() == 0 {
    q = q + 1
    if q > 1 << 24 {
      return Err("flac: invalid residual")
    }
  }
  if gb.bits_left() <= 0 {
    return Err("flac: residual overread")
  }
  let r = if k > 0 { gb.read(k).reinterpret_as_int() } else { 0 }
  let v = (q << k) + r
  Ok((v >> 1) ^ -(v & 1))
}

///|
/// `decode_residuals`: Rice-coded partitioned residuals.
fn flac_decode_residuals(
  gb : BitReader,
  decoded : Array[Int32],
  pred_order : Int32,
  blocksize : Int32,
) -> Result[Unit, String] {
  let method_type = gb.read(2).reinterpret_as_int()
  let rice_order = gb.read(4).reinterpret_as_int()
  if method_type > 1 {
    return Err("flac: illegal residual coding method")
  }
  let samples = blocksize >> rice_order
  if (samples << rice_order) != blocksize {
    return Err("flac: invalid rice order")
  }
  if pred_order > samples {
    return Err("flac: predictor order exceeds partition size")
  }
  let rice_bits = 4 + method_type
  let rice_esc = (1 << rice_bits) - 1
  let mut wi = pred_order
  for partition = 0; partition < (1 << rice_order); partition = partition + 1 {
    let count = if partition == 0 { samples - pred_order } else { samples }
    let param = gb.read(rice_bits).reinterpret_as_int()
    if param == rice_esc {
      let n = gb.read(5).reinterpret_as_int()
      for k = 0; k < count; k = k + 1 {
        decoded[wi] = flac_sbits(gb, n)
        wi = wi + 1
      }
    } else {
      for k = 0; k < count; k = k + 1 {
        decoded[wi] = match flac_rice(gb, param) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        wi = wi + 1
      }
    }
  }
  Ok(())
}

///|
/// `decode_subframe_fixed` (the non-wide path).
fn flac_decode_subframe_fixed(
  gb : BitReader,
  decoded : Array[Int32],
  pred_order : Int32,
  bps : Int32,
  blocksize : Int32,
) -> Result[Unit, String] {
  for i = 0; i < pred_order; i = i + 1 {
    decoded[i] = flac_sbits(gb, bps)
  }
  match flac_decode_residuals(gb, decoded, pred_order, blocksize) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let mut a : UInt32 = 0
  let mut b : UInt32 = 0
  let mut c : UInt32 = 0
  let mut d : UInt32 = 0
  if pred_order > 0 {
    a = decoded[pred_order - 1].reinterpret_as_uint()
  }
  if pred_order > 1 {
    b = a - decoded[pred_order - 2].reinterpret_as_uint()
  }
  if pred_order > 2 {
    c = b - decoded[pred_order - 2].reinterpret_as_uint() +
      decoded[pred_order - 3].reinterpret_as_uint()
  }
  if pred_order > 3 {
    d = c - decoded[pred_order - 2].reinterpret_as_uint() +
      2 * decoded[pred_order - 3].reinterpret_as_uint() -
      decoded[pred_order - 4].reinterpret_as_uint()
  }
  if pred_order > 4 {
    return Err("flac: illegal fixed order")
  }
  for i = pred_order; i < blocksize; i = i + 1 {
    let r = decoded[i].reinterpret_as_uint()
    if pred_order == 1 {
      a = a + r
      decoded[i] = a.reinterpret_as_int()
    } else if pred_order == 2 {
      b = b + r
      a = a + b
      decoded[i] = a.reinterpret_as_int()
    } else if pred_order == 3 {
      c = c + r
      b = b + c
      a = a + b
      decoded[i] = a.reinterpret_as_int()
    } else if pred_order == 4 {
      d = d + r
      c = c + d
      b = b + c
      a = a + b
      decoded[i] = a.reinterpret_as_int()
    } else {
      decoded[i] = r.reinterpret_as_int()
    }
  }
  Ok(())
}

///|
/// `lpc16` / `lpc32` predictor reconstruction.
fn flac_lpc_predict(
  decoded : Array[Int32],
  coeffs : Array[Int32],
  pred_order : Int32,
  qlevel : Int32,
  blocksize : Int32,
  use16 : Bool,
) -> Unit {
  if use16 {
    // C's `int s0` accumulator: the products wrap as 32 bits and the shift is
    // arithmetic (`s0 >> qlevel`), unlike the unsigned intermediate types.
    for i = pred_order; i < blocksize; i = i + 1 {
      let mut sum : Int32 = 0
      for j = 0; j < pred_order; j = j + 1 {
        sum = sum + coeffs[j] * decoded[i - pred_order + j]
      }
      decoded[i] = decoded[i] + (sum >> qlevel)
    }
  } else {
    for i = pred_order; i < blocksize; i = i + 1 {
      let mut sum : Int64 = 0L
      for j = 0; j < pred_order; j = j + 1 {
        sum = sum +
          coeffs[j].to_int64() * decoded[i - pred_order + j].to_int64()
      }
      decoded[i] = (decoded[i].to_int64() + (sum >> qlevel)).to_int()
    }
  }
}

///|
/// `decode_subframe_lpc`.
fn flac_decode_subframe_lpc(
  gb : BitReader,
  decoded : Array[Int32],
  pred_order : Int32,
  bps : Int32,
  blocksize : Int32,
) -> Result[Unit, String] {
  for i = 0; i < pred_order; i = i + 1 {
    decoded[i] = flac_sbits(gb, bps)
  }
  let coeff_prec = gb.read(4).reinterpret_as_int() + 1
  if coeff_prec == 16 {
    return Err("flac: invalid coefficient precision")
  }
  let qlevel = flac_sbits(gb, 5)
  if qlevel < 0 {
    return Err("flac: negative qlevel")
  }
  let coeffs : Array[Int32] = Array::make(32, 0)
  for i = 0; i < pred_order; i = i + 1 {
    coeffs[pred_order - i - 1] = flac_sbits(gb, coeff_prec)
  }
  match flac_decode_residuals(gb, decoded, pred_order, blocksize) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let use16 = bps <= 16 && bps + coeff_prec + flac_log2(pred_order) <= 32
  flac_lpc_predict(decoded, coeffs, pred_order, qlevel, blocksize, use16)
  Ok(())
}

///|
/// `decode_subframe` for one channel; returns the (possibly reduced) bps
/// through `bps_out` after wasted bits.
fn flac_decode_subframe(
  gb : BitReader,
  decoded : Array[Int32],
  channel : Int32,
  ch_mode : Int32,
  stream_bps : Int32,
  blocksize : Int32,
) -> Result[Unit, String] {
  let mut bps = stream_bps
  if channel == 0 && ch_mode == 2 {
    bps = bps + 1
  } else if channel != 0 && (ch_mode == 1 || ch_mode == 3) {
    bps = bps + 1
  }
  if gb.read1() != 0 {
    return Err("flac: invalid subframe padding")
  }
  let stype = gb.read(6).reinterpret_as_int()
  let mut wasted = 0
  if gb.read1() != 0 {
    wasted = 1 + flac_unary(gb)
    if wasted >= bps {
      return Err("flac: invalid wasted bits")
    }
    bps = bps - wasted
  }
  if stype == 0 {
    let tmp = flac_sbits(gb, bps)
    for i = 0; i < blocksize; i = i + 1 {
      decoded[i] = tmp
    }
  } else if stype == 1 {
    for i = 0; i < blocksize; i = i + 1 {
      decoded[i] = flac_sbits(gb, bps)
    }
  } else if stype >= 8 && stype <= 12 {
    let order = stype & 7
    if bps + order > 32 {
      return Err("flac: wide fixed predictor not supported")
    }
    match flac_decode_subframe_fixed(gb, decoded, order, bps, blocksize) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else if stype >= 32 {
    let order = (stype & 31) + 1
    match flac_decode_subframe_lpc(gb, decoded, order, bps, blocksize) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    return Err("flac: invalid subframe type")
  }
  if wasted > 0 {
    if wasted >= 32 {
      return Err("flac: excessive wasted bits")
    }
    for i = 0; i < blocksize; i = i + 1 {
      decoded[i] = (decoded[i].reinterpret_as_uint() << wasted).reinterpret_as_int()
    }
  }
  Ok(())
}

///|
/// One parsed FLAC frame header.
priv struct FlacFrame {
  blocksize : Int32
  channels : Int32
  ch_mode : Int32
  bps : Int32
}

///|
/// `ff_flac_decode_frame_header`, minus CRC verification. The reader is left
/// at the start of the first subframe.
fn flac_frame_header(gb : BitReader, stream_bps : Int32) -> Result[FlacFrame, String] {
  if (gb.read(15) & 0x7FFF) != 0x7FFC {
    return Err("flac: invalid frame sync")
  }
  let _ = gb.read1() // blocking strategy
  let bs_code = gb.read(4).reinterpret_as_int()
  let sr_code = gb.read(4).reinterpret_as_int()
  let ch_raw = gb.read(4).reinterpret_as_int()
  let mut channels = 0
  let mut ch_mode = 0
  if ch_raw < 8 {
    channels = ch_raw + 1
  } else if ch_raw < 11 {
    channels = 2
    ch_mode = ch_raw - 7
  } else {
    return Err("flac: invalid channel mode")
  }
  let bps_code = gb.read(3).reinterpret_as_int()
  if bps_code == 3 {
    return Err("flac: invalid sample size code")
  }
  let mut bps = flac_sample_sizes[bps_code]
  if gb.read1() != 0 {
    return Err("flac: invalid header padding")
  }
  let number = match flac_utf8(gb) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if number < 0L || number > 0x7FFFFFFF {
    return Err("flac: frame number out of range")
  }
  let mut blocksize = 0
  if bs_code == 0 {
    return Err("flac: reserved blocksize code")
  } else if bs_code == 6 {
    blocksize = gb.read(8).reinterpret_as_int() + 1
  } else if bs_code == 7 {
    blocksize = gb.read(16).reinterpret_as_int() + 1
  } else {
    blocksize = flac_blocksizes[bs_code]
  }
  let mut _sample_rate = 0
  if sr_code < 12 {
    _sample_rate = flac_sample_rates[sr_code]
  } else if sr_code == 12 {
    _sample_rate = gb.read(8).reinterpret_as_int() * 1000
  } else if sr_code == 13 {
    _sample_rate = gb.read(16).reinterpret_as_int()
  } else if sr_code == 14 {
    _sample_rate = gb.read(16).reinterpret_as_int() * 10
  } else {
    return Err("flac: illegal sample rate code")
  }
  gb.skip(8) // header CRC-8
  if bps == 0 {
    bps = stream_bps
  } else if stream_bps != 0 && bps != stream_bps {
    return Err("flac: bit depth changes mid-stream")
  }
  Ok({ blocksize, channels, ch_mode, bps })
}

///|
/// Parse the STREAMINFO payload and return `(sample_rate, channels, bps,
/// total_samples, max_blocksize)`.
fn flac_streaminfo(
  gb : BitReader,
) -> Result[(Int32, Int32, Int32, Int64, Int32), String] {
  let _ = gb.read(16) // min blocksize
  let max_blocksize = gb.read(16).reinterpret_as_int()
  let _ = gb.read(24) // min framesize
  let _ = gb.read(24) // max framesize
  let sample_rate = gb.read(20).reinterpret_as_int()
  let channels = gb.read(3).reinterpret_as_int() + 1
  let bps = gb.read(5).reinterpret_as_int() + 1
  let total = (gb.read(32).reinterpret_as_int().to_int64() << 4) |
    gb.read(4).to_int64()
  gb.skip(128) // MD5
  Ok((sample_rate, channels, bps, total, max_blocksize))
}

///|
/// Decode a native FLAC file into interleaved PCM.
pub fn ff_flac_decode(data : Bytes) -> Result[FlacAudio, String] {
  if data.length() < 8 ||
    data[0] != b'f' ||
    data[1] != b'L' ||
    data[2] != b'a' ||
    data[3] != b'C' {
    return Err("flac: missing fLaC marker")
  }
  let gb = BitReader::new(data)
  gb.skip(32)
  let mut stream_rate = 0
  let mut stream_channels = 0
  let mut stream_bps = 0
  let mut total_samples = 0L
  let mut max_blocksize = 0
  let mut got_streaminfo = false
  let mut more_metadata = true
  while more_metadata {
    if gb.bits_left() < 32 {
      return Err("flac: truncated metadata")
    }
    let last = gb.read1() != 0
    let mtype = gb.read(7).reinterpret_as_int()
    let mlen = gb.read(24).reinterpret_as_int()
    if mtype == 0 {
      if mlen < 34 {
        return Err("flac: short STREAMINFO")
      }
      let info = match flac_streaminfo(gb) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      stream_rate = info.0
      stream_channels = info.1
      stream_bps = info.2
      total_samples = info.3
      max_blocksize = info.4
      got_streaminfo = true
      if mlen > 34 {
        gb.skip((mlen - 34) * 8)
      }
    } else {
      gb.skip(mlen * 8)
    }
    more_metadata = !last
  }
  if !got_streaminfo || stream_bps <= 0 || stream_bps > 24 || stream_channels <= 0 {
    return Err("flac: unsupported stream parameters")
  }
  let _ = max_blocksize
  let shift = if stream_bps <= 16 {
    16 - stream_bps
  } else {
    32 - stream_bps
  }
  let samples : Array[Int32] = []
  let mut decoded_total = 0L
  while true {
    if total_samples > 0L && decoded_total >= total_samples {
      break
    }
    if gb.bits_left() < 64 {
      break
    }
    let frame = match flac_frame_header(gb, stream_bps) {
      Ok(v) => v
      Err(e) => {
        if total_samples > 0L && decoded_total >= total_samples {
          break
        }
        return Err(e)
      }
    }
    if frame.channels != stream_channels || frame.bps != stream_bps {
      return Err("flac: frame parameters differ from STREAMINFO")
    }
    let decoded0 : Array[Int32] = Array::make(frame.blocksize, 0)
    let decoded1 : Array[Int32] = Array::make(frame.blocksize, 0)
    match
      flac_decode_subframe(
        gb, decoded0, 0, frame.ch_mode, frame.bps, frame.blocksize,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if frame.channels == 2 {
      match
        flac_decode_subframe(
          gb, decoded1, 1, frame.ch_mode, frame.bps, frame.blocksize,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
    gb.align()
    gb.skip(16) // frame CRC-16
    for i = 0; i < frame.blocksize; i = i + 1 {
      if frame.channels == 1 {
        samples.push((decoded0[i].reinterpret_as_uint() << shift).reinterpret_as_int())
      } else {
        let a = decoded0[i].reinterpret_as_uint()
        let b = decoded1[i].reinterpret_as_uint()
        let (l, r) = if frame.ch_mode == 1 {
          (a, a - b)
        } else if frame.ch_mode == 2 {
          (a + b, b)
        } else if frame.ch_mode == 3 {
          let mid = a - (decoded1[i] >> 1).reinterpret_as_uint()
          (mid + b, mid)
        } else {
          (a, b)
        }
        samples.push((l << shift).reinterpret_as_int())
        samples.push((r << shift).reinterpret_as_int())
      }
    }
    decoded_total = decoded_total + frame.blocksize.to_int64()
  }
  Ok({
    sample_rate: stream_rate,
    channels: stream_channels,
    bits: stream_bps,
    samples,
  })
}

///|
/// Interleaved PCM bytes matching FFmpeg's default FLAC output format:
/// 2 bytes per sample for <= 16-bit streams, 4 bytes for wider ones.
pub fn FlacAudio::pcm_bytes(self : FlacAudio) -> Bytes {
  let out : Array[Byte] = []
  let wide = self.bits > 16
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    if wide {
      out.push(((v >> 8) & 0xFF).to_byte())
      out.push(((v >> 16) & 0xFF).to_byte())
      out.push(((v >> 24) & 0xFF).to_byte())
    } else {
      out.push(((v >> 8) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(out)
}

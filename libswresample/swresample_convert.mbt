///|
/// libswresample port, slice 1: same-rate sample format and channel-layout
/// conversion for the paths with no resampler filter involved. The
/// float->s16 conversion reproduces `audioconvert.c`'s
/// `av_clip_int16(lrintf(x * 32768))` exactly, including lrintf's
/// round-half-to-even (the default FP rounding mode), which is where
/// naive truncation loses a LSB.

///|
/// `lrintf` under the default rounding mode: round half to even. `x` is
/// already scaled to the s16 range by the caller.
fn swr_lrintf(x : Double) -> Int32 {
  let f = x.floor()
  let frac = x - f
  if frac > 0.5 {
    (f + 1.0).to_int()
  } else if frac < 0.5 {
    f.to_int()
  } else if f.to_int() % 2 == 0 {
    f.to_int()
  } else {
    (f + 1.0).to_int()
  }
}

///|
/// `av_clip_int16`.
fn swr_clip_int16(v : Int32) -> Int32 {
  if v < -32768 {
    -32768
  } else if v > 32767 {
    32767
  } else {
    v
  }
}

///|
/// One float sample to s16, FFmpeg's exact semantics.
pub fn swr_flt_to_s16(x : Double) -> Int32 {
  swr_clip_int16(swr_lrintf(x * 32768.0))
}

///|
/// Interleave a planar float frame set (`planar[ch][i]`) into packed s16
/// bytes, channel count unchanged - the swr path with no resampling and
/// no rematrix.
pub fn Swr::flt_planar_to_s16_packed(
  _self : Swr,
  planar : Array[Array[Double]],
  channels : Int32,
) -> Bytes raise {
  let samples = swr_flt_planar_to_s16(planar, channels)
  let out : Array[Byte] = []
  for v in samples {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Convert planar floating-point channels to interleaved signed 16-bit samples.
pub fn swr_flt_planar_to_s16(
  planar : Array[Array[Double]],
  channels : Int32,
) -> Array[Int32] raise {
  if channels <= 0 || planar.length() < channels {
    fail("swresample: planar buffers do not cover the channel count")
  }
  let nb = planar[0].length()
  for ch = 1; ch < channels; ch = ch + 1 {
    if planar[ch].length() != nb {
      fail("swresample: unequal plane lengths")
    }
  }
  swr_interleave_s16(planar, channels, nb)
}

///|
#cfg(any(target="wasm", target="wasm-gc"))
fn swr_interleave_s16(
  planar : Array[Array[Double]],
  channels : Int32,
  nb : Int32,
) -> Array[Int32] {
  let out = Array::make(nb * channels, 0)
  swr_flt_planar_to_s16_packed_v128(planar, channels, nb, out)
  out
}

///|
#cfg(not(any(target="wasm", target="wasm-gc")))
fn swr_interleave_s16(
  planar : Array[Array[Double]],
  channels : Int32,
  nb : Int32,
) -> Array[Int32] {
  Array::makei(nb * channels, i => {
    swr_flt_to_s16(planar[i % channels][i / channels])
  })
}

///|
/// Mono planar float to packed stereo s16 - swr's mono->stereo rematrix
/// duplicates the single channel into L and R.
pub fn Swr::mono_to_stereo_s16_packed(
  _self : Swr,
  mono : Array[Double],
) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < mono.length(); i = i + 1 {
    let v = swr_flt_to_s16(mono[i])
    for _ch = 0; _ch < 2; _ch = _ch + 1 {
      out.push((v & 0xFF).to_byte())
      out.push(((v >> 8) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Handle type for the swresample port (slice 1 carries no state; later
/// slices add resampler/soxr configuration here).
pub struct Swr {
  priv _unit : Unit
}

///|
/// Create a converter handle.
pub fn Swr::new() -> Swr {
  { _unit: (), }
}

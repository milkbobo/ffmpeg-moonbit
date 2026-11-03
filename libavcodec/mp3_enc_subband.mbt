/// MoonBit port of shine 3.1.1 `l3subband.c`: the 32-band polyphase analysis
/// filter bank. Multiplications are the shine `mul` family (see
/// `mp3_encode.mbt`); the per-call state is the per-channel 512-entry window
/// buffer `subband_x` with the 480-sample wrap-around offset.

///|
/// `mul(a, b)`: the shine noarch 64-bit product shifted right by 32.
fn mp3enc_mul(a : Int32, b : Int32) -> Int32 {
  ((a.to_int64() * b.to_int64()) >> 32).to_int()
}

///|
/// `mulr(a, b)`: the rounding variant used by the quantiser.
fn mp3enc_mulr(a : Int32, b : Int32) -> Int32 {
  ((a.to_int64() * b.to_int64() + 0x80000000L) >> 32).to_int()
}

///|
/// `mulsr(a, b)`: the `>>31` rounding variant used for `xrsq`.
fn mp3enc_mulsr(a : Int32, b : Int32) -> Int32 {
  ((a.to_int64() * b.to_int64() + 0x40000000L) >> 31).to_int()
}

///|
/// `shine_window_filter_subband`: window 32 new PCM samples into `y[64]`,
/// then filter into 32 subband samples written at `out[out_off .. out_off+31]`.
/// The per-channel input cursor advances by 32 samples.
fn Mp3Encoder::window_filter_subband(
  self : Mp3Encoder,
  ch : Int32,
  out : Array[Int32],
  out_off : Int32,
) -> Unit {
  let x = self.subband_x[ch]
  let off = self.subband_off[ch]
  let stride = self.channels
  let inp = self.cur_input
  let mut p = self.in_pos[ch]
  // replace 32 oldest samples with 32 new samples; the C loop is
  // `for (i = 32; i--;)`, so the FIRST sample lands at `x[off+31]` — the
  // buffer is filled in reverse. `off` is always a multiple of 32 and
  // <= 480, so `off + i` never exceeds HAN_SIZE-1 (the C code relies on
  // this invariant and does not mask here).
  for i in 0..<32 {
    x[off + 31 - i] = inp[p] << 16
    p += stride
  }
  self.in_pos[ch] = p
  // 512-tap window: eight 64-sample segments
  let y = self.sb_y
  let enwindow = mp3enc_enwindow
  for i in 0..<64 {
    let o = (off + i) & (mp3enc_han_size - 1)
    let mut acc : Int32 = mp3enc_mul(x[o], enwindow[i])
    acc += mp3enc_mul(x[(o + 64) & (mp3enc_han_size - 1)], enwindow[i + 64])
    acc += mp3enc_mul(x[(o + 128) & (mp3enc_han_size - 1)], enwindow[i + 128])
    acc += mp3enc_mul(x[(o + 192) & (mp3enc_han_size - 1)], enwindow[i + 192])
    acc += mp3enc_mul(x[(o + 256) & (mp3enc_han_size - 1)], enwindow[i + 256])
    acc += mp3enc_mul(x[(o + 320) & (mp3enc_han_size - 1)], enwindow[i + 320])
    acc += mp3enc_mul(x[(o + 384) & (mp3enc_han_size - 1)], enwindow[i + 384])
    acc += mp3enc_mul(x[(o + 448) & (mp3enc_han_size - 1)], enwindow[i + 448])
    y[i] = acc
  }
  self.subband_off[ch] = (off + 480) & (mp3enc_han_size - 1)
  // filter with the 32x64 matrix (dot product per subband)
  let fl = mp3enc_subband_fl
  for i in 0..<mp3enc_sblimit {
    let base = i * 64
    let mut acc : Int32 = mp3enc_mul(fl[base + 63], y[63])
    for j in 0..<63 {
      acc += mp3enc_mul(fl[base + j], y[j])
    }
    out[out_off + i] = acc
  }
}

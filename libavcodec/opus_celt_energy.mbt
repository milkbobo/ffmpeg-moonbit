///|
/// CELT frame setup through fine-energy decoding, ported from FFmpeg 9.0.2
/// opus/dec_celt.c. Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2016 Rostislav Pehlivanov. LGPL-2.1-or-later.
/// This is intermediate pre-PVQ state, not PCM
/// or finalized energy history. The caller commits history after full decoding.
pub struct OpusCeltSetup {
  channels : Int32
  size : Int32
  start_band : Int32
  end_band : Int32
  framebits : Int32
  silence : Bool
  transient : Bool
  blocks : Int32
  postfilter_period : Int32
  postfilter_gains : Array[Float]
  /// Two channel-major 21-band rows; inactive second-channel history is kept.
  energy : Array[Float]
  tf_change : Array[Int32]
  allocation : OpusCeltAllocation
}

///|
let opus_celt_alpha : FixedArray[Float] = [
  29440.0 / 32768.0,
  26112.0 / 32768.0,
  21248.0 / 32768.0,
  16384.0 / 32768.0,
]

///|
let opus_celt_beta : FixedArray[Float] = [
  1.0 - 30147.0 / 32768.0,
  1.0 - 22282.0 / 32768.0,
  1.0 - 12124.0 / 32768.0,
  1.0 - 6554.0 / 32768.0,
]

///|
let opus_celt_postfilter_taps : FixedArray[Float] = [
  0.306640625, 0.2170410156, 0.1296386719, 0.4638671875, 0.2680664062, 0.0, 0.7998046875,
  0.1000976562, 0.0,
]

///|
fn opus_celt_coarse_energy(
  rc : OpusRangeDecoder,
  energy : Array[Float],
  channels : Int32,
  size : Int32,
  start : Int32,
  end : Int32,
  framebits : Int32,
) -> Result[Unit, String] {
  let intra = if rc.tell() + 3 <= framebits {
    match rc.decode_log(3) {
      Ok(v) => v != 0
      Err(e) => return Err(e)
    }
  } else {
    false
  }
  let alpha : Float = if intra { 0.0 } else { opus_celt_alpha[size] }
  let beta : Float = if intra {
    1.0 - 4915.0 / 32768.0
  } else {
    opus_celt_beta[size]
  }
  let model = (size * 2 + (if intra { 1 } else { 0 })) * 42
  let prev : Array[Float] = [0.0, 0.0]
  for band in 0..<21 {
    for channel in 0..<channels {
      let index = channel * 21 + band
      if band < start || band >= end {
        energy[index] = 0.0
        continue
      }
      let available = framebits - rc.tell()
      let value : Float = if available >= 15 {
        let k = model + 2 * band
        match
          rc.decode_laplace(
            opus_celt_coarse_energy_dist[k] << 7,
            opus_celt_coarse_energy_dist[k + 1] << 6,
          ) {
          Ok(v) => Float::from_int(v)
          Err(e) => return Err(e)
        }
      } else if available >= 2 {
        let x = match rc.decode_cdf(opus_celt_model_tapset[:]) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        Float::from_int((x >> 1) ^ -(x & 1))
      } else if available >= 1 {
        match rc.decode_log(1) {
          Ok(v) => -Float::from_int(v)
          Err(e) => return Err(e)
        }
      } else {
        -1.0
      }
      energy[index] = energy[index].max(-9.0) * alpha + prev[channel] + value
      prev[channel] += beta * value
    }
  }
  Ok(())
}

///|
fn opus_celt_tf_changes(
  rc : OpusRangeDecoder,
  size : Int32,
  start : Int32,
  end : Int32,
  framebits : Int32,
  transient : Bool,
) -> Result[Array[Int32], String] {
  let mut bits = if transient { 2 } else { 4 }
  let mut consumed = rc.tell()
  let select_bit = if size != 0 && consumed + bits + 1 <= framebits {
    1
  } else {
    0
  }
  let changes = Array::make(21, 0)
  let mut diff = 0
  let mut changed = 0
  for i in start..<end {
    if consumed + bits + select_bit <= framebits {
      diff = diff ^
        (match rc.decode_log(bits) {
          Ok(v) => v
          Err(e) => return Err(e)
        })
      consumed = rc.tell()
      changed = changed | diff
    }
    changes[i] = diff
    bits = if transient { 4 } else { 5 }
  }
  let table = (size * 2 + (if transient { 1 } else { 0 })) * 4
  let select = if select_bit != 0 &&
    opus_celt_tf_select[table + changed] !=
    opus_celt_tf_select[table + 2 + changed] {
    match rc.decode_log(1) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  } else {
    0
  }
  for i in start..<end {
    changes[i] = opus_celt_tf_select[table + select * 2 + changes[i]]
  }
  Ok(changes)
}

///|
fn opus_celt_fine_energy(
  rc : OpusRangeDecoder,
  energy : Array[Float],
  channels : Int32,
  start : Int32,
  end : Int32,
  allocation : OpusCeltAllocation,
) -> Result[Unit, String] {
  for band in start..<end {
    let bits = allocation.fine_bits[band]
    if bits == 0 {
      continue
    }
    for channel in 0..<channels {
      let raw = match rc.get_raw(bits) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let offset : Float = (Float::from_uint(raw) + 0.5) *
        Float::from_int(1 << (14 - bits)) /
        16384.0 -
        0.5
      energy[channel * 21 + band] += offset
    }
  }
  Ok(())
}

///|
/// Decode CELT setup on the frame's shared range decoder: silence,
/// postfilter parameters, transient, coarse energy, TF changes, bit allocation
/// and fine energy. Leaves the decoder positioned at PVQ band syntax.
/// `frame_size` is 120/240/480/960 samples. Optional `previous_energy` contains
/// two channel-major 21-band rows; omitted history is zero (FFmpeg flush state).
/// A mono frame merges both previous channel rows before temporal prediction.
/// Only parameter validation is transactional; malformed frame errors can
/// consume entropy, and callers must discard that frame's range decoder.
/// This does not apply the postfilter or produce decoded audio samples.
///
/// ```mbt check
/// test {
///   let rc = @libavcodec.opus_rc_init(b"\xff\xfe").unwrap()
///   let setup = rc.decode_celt_setup(1, 120, 0, 13).unwrap()
///   assert_eq(setup.energy.length(), 42)
///   assert_eq(setup.tf_change.length(), 21)
/// }
/// ```
pub fn OpusRangeDecoder::decode_celt_setup(
  self : OpusRangeDecoder,
  channels : Int32,
  frame_size : Int32,
  start : Int32,
  end : Int32,
  previous_energy~ : ArrayView[Float] = [],
) -> Result[OpusCeltSetup, String] {
  let size = match frame_size {
    120 => 0
    240 => 1
    480 => 2
    960 => 3
    _ => return Err("opus: invalid CELT frame size")
  }
  let framebits = self.data.length() * 8
  if opus_celt_validate(self, channels, size, start, end, framebits) is Some(e) {
    return Err(e)
  }
  if previous_energy.length() != 0 && previous_energy.length() != 42 {
    return Err("opus: CELT energy history must have 42 bands")
  }
  for value in previous_energy {
    if value.is_nan() || value.is_inf() {
      return Err("opus: nonfinite CELT energy history")
    }
  }
  let energy : Array[Float] = if previous_energy.length() == 0 {
    Array::make(42, 0.0)
  } else {
    previous_energy.to_owned()
  }
  let mut consumed = self.tell()
  let silence = if consumed >= framebits {
    true
  } else if consumed == 1 {
    match self.decode_log(15) {
      Ok(v) => v != 0
      Err(e) => return Err(e)
    }
  } else {
    false
  }
  if silence {
    consumed = framebits
    self.total_bits += (framebits - self.tell()).reinterpret_as_uint()
  }
  let gains : Array[Float] = [0.0, 0.0, 0.0]
  let mut period = 0
  if start == 0 && consumed + 16 <= framebits {
    let has_filter = match self.decode_log(1) {
      Ok(v) => v != 0
      Err(e) => return Err(e)
    }
    if has_filter {
      let octave = match self.decode_uint(6U) {
        Ok(v) => v.reinterpret_as_int()
        Err(e) => return Err(e)
      }
      let raw_period = match self.get_raw(4 + octave) {
        Ok(v) => v.reinterpret_as_int()
        Err(e) => return Err(e)
      }
      period = ((16 << octave) + raw_period - 1).max(15)
      let raw_gain = match self.get_raw(3) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let gain : Float = 0.09375 * Float::from_uint(raw_gain + 1U)
      let tapset = if self.tell() + 2 <= framebits {
        match self.decode_cdf(opus_celt_model_tapset[:]) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
      } else {
        0
      }
      for i in 0..<3 {
        gains[i] = gain * opus_celt_postfilter_taps[tapset * 3 + i]
      }
    }
    consumed = self.tell()
  }
  let transient = if size != 0 && consumed + 3 <= framebits {
    match self.decode_log(3) {
      Ok(v) => v != 0
      Err(e) => return Err(e)
    }
  } else {
    false
  }
  if channels == 1 {
    for i in 0..<21 {
      energy[i] = energy[i].max(energy[21 + i])
    }
  }
  match
    opus_celt_coarse_energy(self, energy, channels, size, start, end, framebits) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let tf_change = match
    opus_celt_tf_changes(self, size, start, end, framebits, transient) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let allocation = match
    self.decode_celt_allocation(
      channels, size, start, end, framebits, transient,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match opus_celt_fine_energy(self, energy, channels, start, end, allocation) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  Ok({
    channels,
    size,
    start_band: start,
    end_band: end,
    framebits,
    silence,
    transient,
    blocks: if transient {
      1 << size
    } else {
      1
    },
    postfilter_period: period,
    postfilter_gains: gains,
    energy,
    tf_change,
    allocation,
  })
}

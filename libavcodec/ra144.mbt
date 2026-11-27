///|
/// RealAudio 1.0 (14.4 kb/s), ported from FFmpeg ra144dec.c and ra144.c
/// (LGPL-2.1-or-later). Filter products use wrapping 32-bit arithmetic.
struct Ra144Decoder {
  mut lpc : FixedArray[Int32]
  mut previous_lpc : FixedArray[Int32]
  mut previous_rms : UInt32
  mut previous_energy : UInt32
  adaptive : FixedArray[Int32]
  synthesis : FixedArray[Int32]
}

///|
pub fn Ra144Decoder::new() -> Ra144Decoder {
  {
    lpc: FixedArray::make(10, 0),
    previous_lpc: FixedArray::make(10, 0),
    previous_rms: 0,
    previous_energy: 0,
    adaptive: FixedArray::make(148, 0),
    synthesis: FixedArray::make(50, 0),
  }
}

///|
let ra144_refl_tables : FixedArray[FixedArray[Int32]] = [
  ra144_lpc_refl_cb1, ra144_lpc_refl_cb2, ra144_lpc_refl_cb3, ra144_lpc_refl_cb4,
  ra144_lpc_refl_cb5, ra144_lpc_refl_cb6, ra144_lpc_refl_cb7, ra144_lpc_refl_cb8,
  ra144_lpc_refl_cb9, ra144_lpc_refl_cb10,
]

///|
fn ra144_scaled_sqrt(value : UInt32) -> UInt32 {
  for x = value, shift = 2; x > 0xfff; x = x >> 2, shift = shift + 1 {

  } nobreak {
    opus_rc_isqrt(x << 20) << shift
  }
}

///|
fn ra144_refl_rms(refl : FixedArray[Int32]) -> UInt32 {
  let mut result = 0x10000U
  let mut shift = 10
  for coef in refl {
    result = (((0x1000000 - coef * coef) >> 12).reinterpret_as_uint() * result) >>
      12
    if result == 0 {
      return 0
    }
    while result <= 0x3fff {
      shift += 1
      result = result << 2
    }
  }
  ra144_scaled_sqrt(result) >> shift
}

///|
fn ra144_eval_lpc(lpc : FixedArray[Int32], refl : FixedArray[Int32]) -> Unit {
  let mut current = lpc
  let mut next = FixedArray::make(10, 0)
  for i = 0; i < 10; i = i + 1 {
    next[i] = refl[i] * 16
    for j = 0; j < i; j = j + 1 {
      next[j] = ((refl[i] * current[i - j - 1]) >> 12) + current[j]
    }
    let old = current
    current = next
    next = old
  }
  for i = 0; i < 10; i = i + 1 {
    lpc[i] = current[i] >> 4
  }
}

///|
fn ra144_eval_refl(lpc : FixedArray[Int32]) -> FixedArray[Int32]? {
  let refl = FixedArray::make(10, 0)
  let mut current = FixedArray::makei(10, i => lpc[i])
  let mut next = FixedArray::make(10, 0)
  if current[9] < -4096 || current[9] > 4095 {
    return None
  }
  refl[9] = current[9]
  for i = 8; i >= 0; i = i - 1 {
    let divisor = 4096 - ((current[i + 1] * current[i + 1]) >> 12)
    let factor = 0x1000000 / (if divisor == 0 { -2 } else { divisor })
    for j = 0; j <= i; j = j + 1 {
      let reflected = (refl[i + 1] * current[i - j]) >> 12
      next[j] = ((current[j] - reflected) * factor) >> 12
    }
    if next[i] < -4096 || next[i] > 4095 {
      return None
    }
    refl[i] = next[i]
    let old = current
    current = next
    next = old
  }
  Some(refl)
}

///|
fn Ra144Decoder::interpolate(
  self : Ra144Decoder,
  weight : Int32,
  use_previous : Bool,
  rms : UInt32,
  energy : UInt32,
) -> (FixedArray[Int32], Int32) {
  let coefs = FixedArray::makei(10, i => {
    let mixed = (weight * self.lpc[i] + (4 - weight) * self.previous_lpc[i]) >>
      2
    mixed << 16 >> 16
  })
  let block_rms = match ra144_eval_refl(coefs) {
    Some(refl) => ra144_refl_rms(refl)
    None => {
      let fallback = if use_previous { self.previous_lpc } else { self.lpc }
      for i = 0; i < 10; i = i + 1 {
        coefs[i] = fallback[i] << 16 >> 16
      }
      if use_previous {
        self.previous_rms
      } else {
        rms
      }
    }
  }
  (coefs, ((block_rms * energy) >> 10).reinterpret_as_int())
}

///|
fn Ra144Decoder::decode_subblock(
  self : Ra144Decoder,
  bits : BitReader,
  lpc : FixedArray[Int32],
  rms : Int32,
  out : Array[Int32],
) -> Unit {
  let adaptive_index = bits.read(7).reinterpret_as_int()
  let gain = bits.read(8).reinterpret_as_int()
  let cb1 = bits.read(7).reinterpret_as_int()
  let cb2 = bits.read(7).reinterpret_as_int()
  let old = FixedArray::make(40, 0)
  let mut adaptive_gain = 0
  if adaptive_index != 0 {
    let delay = adaptive_index + 19
    let mut sum = 0U
    for i = 0; i < 40; i = i + 1 {
      let sample = self.adaptive[148 - delay + i % delay]
      old[i] = sample
      sum += (sample * sample).reinterpret_as_uint()
    }
    if sum != 0 {
      let inv_rms = 0x20000000U / (ra144_scaled_sqrt(sum) >> 8)
      adaptive_gain = ((inv_rms * rms.reinterpret_as_uint()) >> 12).reinterpret_as_int()
    }
  }
  let shift = ra144_gain_exp_tab[gain]
  let v0 = ((ra144_gain_val_tab[gain * 3] * adaptive_gain).reinterpret_as_uint() >>
  shift).reinterpret_as_int()
  let v1 = ((ra144_gain_val_tab[gain * 3 + 1] *
  ((ra144_cb1_base[cb1] * rms) >> 8)).reinterpret_as_uint() >>
  shift).reinterpret_as_int()
  let v2 = ((ra144_gain_val_tab[gain * 3 + 2] *
  ((ra144_cb2_base[cb2] * rms) >> 8)).reinterpret_as_uint() >>
  shift).reinterpret_as_int()
  for i = 0; i < 108; i = i + 1 {
    self.adaptive[i] = self.adaptive[i + 40]
  }
  for i = 0; i < 40; i = i + 1 {
    let value = (
        old[i] * v0 +
        ra144_cb1_vects[cb1 * 40 + i] * v1 +
        ra144_cb2_vects[cb2 * 40 + i] * v2
      ) >>
      12
    self.adaptive[108 + i] = value << 16 >> 16
  }
  for i = 0; i < 10; i = i + 1 {
    self.synthesis[i] = self.synthesis[40 + i]
  }
  for i = 0; i < 40; i = i + 1 {
    let mut sum = 0xfff
    for j = 0; j < 10; j = j + 1 {
      sum -= lpc[j] * self.synthesis[9 + i - j]
    }
    let value = (sum >> 12) + self.adaptive[108 + i]
    if value < -32768 || value > 32767 {
      for j = 0; j < 50; j = j + 1 {
        self.synthesis[j] = 0
      }
      break
    }
    self.synthesis[10 + i] = value
  }
  for i = 0; i < 40; i = i + 1 {
    out.push((4 * self.synthesis[10 + i]).clamp(min=-32768, max=32767))
  }
}

///|
/// Decode one or more 20-byte frames into signed 16-bit mono samples.
pub fn Ra144Decoder::decode_packet(
  self : Ra144Decoder,
  packet : Bytes,
) -> Result[Array[Int32], String] {
  if packet.length() == 0 || packet.length() % 20 != 0 {
    return Err("RealAudio 14.4 packet must contain complete 20-byte frames")
  }
  let widths : FixedArray[Int32] = [6, 5, 5, 4, 4, 3, 3, 3, 3, 2]
  let bits = BitReader::new(packet)
  let out = []
  for frame = 0; frame < packet.length() / 20; frame = frame + 1 {
    let refl = FixedArray::makei(10, i => {
      ra144_refl_tables[i][bits.read(widths[i]).reinterpret_as_int()]
    })
    ra144_eval_lpc(self.lpc, refl)
    let rms = ra144_refl_rms(refl)
    let energy = ra144_energy_tab[bits.read(5).reinterpret_as_int()].reinterpret_as_uint()
    let (lpc0, rms0) = self.interpolate(1, true, rms, self.previous_energy)
    let middle = ra144_scaled_sqrt(energy * self.previous_energy) >> 12
    let (lpc1, rms1) = self.interpolate(
      2,
      energy <= self.previous_energy,
      rms,
      middle,
    )
    let (lpc2, rms2) = self.interpolate(3, false, rms, energy)
    let lpc3 = FixedArray::makei(10, i => self.lpc[i] << 16 >> 16)
    self.decode_subblock(bits, lpc0, rms0, out)
    self.decode_subblock(bits, lpc1, rms1, out)
    self.decode_subblock(bits, lpc2, rms2, out)
    self.decode_subblock(
      bits,
      lpc3,
      ((rms * energy) >> 10).reinterpret_as_int(),
      out,
    )
    bits.skip(1)
    self.previous_energy = energy
    self.previous_rms = rms
    let previous = self.previous_lpc
    self.previous_lpc = self.lpc
    self.lpc = previous
  }
  Ok(out)
}

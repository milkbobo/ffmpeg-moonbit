///|
/// GSM 06.10 synthesis, ported from FFmpeg's gsmdec_template.c and
/// msgsmdec.c (copyright 2010 Reimar Döffinger, LGPL-2.1-or-later).
/// Handles the 13 kb/s mode in native GSM and 65-byte WAV49 packing.
pub struct GsmDecoder {
  reference : FixedArray[Int32]
  previous_lar : FixedArray[Int32]
  lattice : FixedArray[Int32]
  mut deemphasis : Int32
}

///|
/// Create a decoder with zeroed GSM predictor history.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.gsm_decoder_new().decode_packet(b"") is Err(_))
/// }
/// ```
pub fn gsm_decoder_new() -> GsmDecoder {
  {
    reference: FixedArray::make(280, 0),
    previous_lar: FixedArray::make(8, 0),
    lattice: FixedArray::make(9, 0),
    deemphasis: 0,
  }
}

///|
let gsm_lar_parameters : FixedArray[(Int32, Int32, Int32)] = [
  (6, 13107, 32768),
  (6, 13107, 32768),
  (5, 13107, 20480),
  (5, 13107, 11264),
  (4, 19223, 8380),
  (4, 17476, 4608),
  (3, 31454, 3414),
  (3, 29708, 1808),
]

///|
let gsm_long_term_gains : FixedArray[Int32] = [3277, 11469, 21299, 32767]

///|
let gsm_apcm_factors : FixedArray[Int32] = [
  18431, 20479, 22527, 24575, 26623, 28671, 30719, 32767,
]

///|
fn gsm_mult(a : Int32, b : Int32) -> Int32 {
  (a * b + 16384) >> 15
}

///|
/// Reconstruct one row of ff_gsm_dequant_tab from the APCM exponent and
/// mantissa. The two roundings also reproduce asymmetric high-amplitude rows.
fn gsm_apcm_scale(maximum : Int32) -> (Int32, Int32) {
  let mut exp = if maximum > 15 { (maximum >> 3) - 1 } else { 0 }
  let mut mantissa = maximum - (exp << 3)
  if mantissa == 0 {
    exp = -4
    mantissa = 7
  } else {
    while mantissa <= 7 {
      mantissa = (mantissa << 1) | 1
      exp -= 1
    }
    mantissa -= 8
  }
  (6 - exp, mantissa)
}

///|
fn gsm_apcm_row(maximum : Int32) -> FixedArray[Int32] {
  let (shift, mantissa) = gsm_apcm_scale(maximum)
  let rounding = if shift > 0 { 1 << (shift - 1) } else { 0 }
  FixedArray::makei(8, code => {
    let pulse = (code * 2 - 7) << 12
    (gsm_mult(gsm_apcm_factors[mantissa], pulse) + rounding) >> shift
  })
}

///|
let gsm_apcm_rows : FixedArray[FixedArray[Int32]] = FixedArray::makei(
  64, gsm_apcm_row,
)

///|
fn gsm_reflection_coefficient(lar : Int32) -> Int32 {
  let magnitude = lar.abs()
  let coefficient = if magnitude < 11059 {
    magnitude << 1
  } else if magnitude < 20070 {
    magnitude + 11059
  } else {
    (magnitude >> 2) + 26112
  }
  if lar < 0 {
    -coefficient
  } else {
    coefficient
  }
}

///|
fn gsm_lar_decode(index : Int32, code : Int32) -> Int32 {
  let (_, factor, offset) = gsm_lar_parameters[index]
  gsm_mult((code << 10) - offset, factor) * 2
}

///|
let gsm_lar_boundaries : FixedArray[Int32] = [0, 13, 27, 40, 160]

///|
fn gsm_lar_interpolate(
  previous : Int32,
  current : Int32,
  segment : Int32,
) -> Int32 {
  match segment {
    0 => (previous >> 2) + (previous >> 1) + (current >> 2)
    1 => (previous >> 1) + (current >> 1)
    2 => (previous >> 2) + (current >> 1) + (current >> 2)
    _ => current
  }
}

///|
fn GsmDecoder::synthesize(
  self : GsmDecoder,
  lar : FixedArray[Int32],
  samples : Array[Int32],
) -> Unit {
  for segment in 0..<4 {
    let coefficients = FixedArray::makei(8, i => {
      gsm_reflection_coefficient(
        gsm_lar_interpolate(self.previous_lar[i], lar[i], segment),
      )
    })
    for i in gsm_lar_boundaries[segment]..<gsm_lar_boundaries[segment + 1] {
      let mut value = self.reference[120 + i]
      for j = 7; j >= 0; j = j - 1 {
        value -= gsm_mult(coefficients[j], self.lattice[j])
        self.lattice[j + 1] = self.lattice[j] + gsm_mult(coefficients[j], value)
      }
      self.lattice[0] = value
      // FFmpeg stores the lattice output in int16_t before deemphasis.
      let short_term = value << 16 >> 16
      self.deemphasis = clip_int16(
        short_term + gsm_mult(self.deemphasis, 28180),
      )
      samples.push(clip_int16(self.deemphasis * 2) & -8)
    }
  }
  for i in 0..<8 {
    self.previous_lar[i] = lar[i]
  }
}

///|
fn GsmDecoder::decode_block(
  self : GsmDecoder,
  read : (Int32) -> Int32,
  samples : Array[Int32],
) -> Unit {
  let lar = FixedArray::makei(8, i => {
    let (width, _, _) = gsm_lar_parameters[i]
    gsm_lar_decode(i, read(width))
  })
  for subframe in 0..<4 {
    let lag = read(7).max(40).min(120)
    let gain = gsm_long_term_gains[read(2)]
    let grid = read(2)
    let pulses = gsm_apcm_rows[read(6)]
    let base = 120 + subframe * 40
    for i in 0..<40 {
      self.reference[base + i] = gsm_mult(gain, self.reference[base + i - lag])
    }
    for i in 0..<13 {
      let pos = base + grid + 3 * i
      self.reference[pos] = (self.reference[pos] + pulses[read(3)]) << 16 >> 16
    }
  }
  self.synthesize(lar, samples)
  for i in 0..<120 {
    self.reference[i] = self.reference[160 + i]
  }
}

///|
/// Decode complete GSM blocks in order, preserving history between packets.
/// Native blocks are 33 bytes and WAV49 blocks contain two frames in 65 bytes.
pub fn GsmDecoder::decode_packet(
  self : GsmDecoder,
  data : Bytes,
  wav49~ : Bool = false,
) -> Result[Array[Int32], String] {
  let stride = if wav49 { 65 } else { 33 }
  if data.is_empty() || data.length() % stride != 0 {
    return Err("gsm: incomplete block")
  }
  if !wav49 {
    for start = 0; start < data.length(); start = start + stride {
      if (data[start].to_int() & 0xf0) != 0xd0 {
        return Err("gsm: missing frame magic")
      }
    }
  }
  let samples : Array[Int32] = []
  for start = 0; start < data.length(); start = start + stride {
    let block = data[start:start + stride]
    if wav49 {
      let bits = TtaBits::new(block)
      let read = n => bits.read(n).reinterpret_as_int()
      self.decode_block(read, samples)
      self.decode_block(read, samples)
    } else {
      let bits = BitReader::new(block.to_owned())
      bits.skip(4)
      self.decode_block(n => bits.read(n).reinterpret_as_int(), samples)
    }
  }
  Ok(samples)
}

///|
/// E-AC-3 spectral extension, from FFmpeg ac3dec.c and eac3dec.c.
priv struct Ac3SpxState {
  mut in_use : Bool
  mut copy_start : Int32
  mut start : Int32
  mut end : Int32
  bands : Ref[Int32]
  band_sizes : FixedArray[Int32]
  band_structure : FixedArray[Bool]
  channel_uses : FixedArray[Bool]
  first_coords : FixedArray[Bool]
  attenuation : FixedArray[Int32]
  noise : Array[Array[Double]]
  signal : Array[Array[Double]]
}

///|
let ac3_default_spx_band_structure : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
]

///|
fn ac3_spx_new() -> Ac3SpxState {
  let max_bands = ac3_default_spx_band_structure.length()
  {
    in_use: false,
    copy_start: 0,
    start: 0,
    end: 0,
    bands: { val: 0, },
    band_sizes: FixedArray::make(max_bands, 0),
    band_structure: FixedArray::make(max_bands, false),
    channel_uses: FixedArray::make(ac3_max_channels, false),
    first_coords: FixedArray::make(ac3_max_channels, true),
    attenuation: FixedArray::make(ac3_max_channels, -1),
    noise: ac3_channel_arrays_double(max_bands),
    signal: ac3_channel_arrays_double(max_bands),
  }
}

///|
fn Ac3Decoder::read_spx(
  self : Ac3Decoder,
  gb : BitReader,
  block : Int32,
) -> Result[Unit, String] {
  let spx = self.spx
  if !self.eac3 {
    spx.in_use = false
  } else if block == 0 || gb.read1() != 0 {
    spx.in_use = gb.read1() != 0
    if spx.in_use {
      for ch in 1..<=self.fbw_channels {
        spx.channel_uses[ch] = self.channel_mode == ac3_chmode_mono ||
          gb.read1() != 0
      }
      let copy_start = gb.read(2).reinterpret_as_int() * 12 + 25
      let start_code = gb.read(3).reinterpret_as_int() + 2
      let end_code = gb.read(3).reinterpret_as_int() + 5
      let start_band = start_code + (start_code - 7).max(0)
      let end_band = end_code + (end_code - 7).max(0)
      let start = start_band * 12 + 25
      guard start_band < end_band && copy_start < start else {
        return Err("eac3: invalid spectral extension range")
      }
      spx.copy_start = copy_start
      spx.start = start
      spx.end = end_band * 12 + 25
      ac3_decode_band_structure(
        gb,
        block,
        true,
        start_band,
        end_band,
        ac3_default_spx_band_structure,
        spx.band_structure,
        spx.bands,
        spx.band_sizes,
      )
    }
  }
  for ch in 1..<=self.fbw_channels {
    if !spx.in_use {
      spx.channel_uses[ch] = false
    }
    if !spx.channel_uses[ch] {
      spx.first_coords[ch] = true
    } else if spx.first_coords[ch] || gb.read1() != 0 {
      spx.first_coords[ch] = false
      let blend = gb.read(5).to_double() / 32.0
      let master = gb.read(2).reinterpret_as_int() * 3
      let mut bin = spx.start
      for band in 0..<spx.bands.val {
        let size = spx.band_sizes[band]
        let ratio = ((bin + size / 2).to_double() / spx.end.to_double() - blend).clamp(
          min=0.0,
          max=1.0,
        )
        let exp = gb.read(4).reinterpret_as_int()
        let mantissa = gb.read(2).reinterpret_as_int()
        let mantissa = if exp == 15 { mantissa * 2 } else { mantissa + 4 }
        let coord = (mantissa << (25 - exp - master)).to_double() / 8388608.0
        spx.noise[ch][band] = (3.0 * ratio).sqrt() * coord
        spx.signal[ch][band] = (1.0 - ratio).sqrt() * coord
        bin = bin + size
      }
    }
  }
  Ok(())
}

///|
fn Ac3Decoder::apply_spx(self : Ac3Decoder) -> Unit {
  let spx = self.spx
  let copy_width = spx.start - spx.copy_start
  let mut source = spx.copy_start
  let mut destination = spx.start
  let wrap = FixedArray::make(spx.bands.val, false)
  for band in 0..<spx.bands.val {
    let size = spx.band_sizes[band]
    wrap[band] = band == 0 || source + size > spx.start
    if wrap[band] {
      source = spx.copy_start
    }
    for offset in 0..<size {
      let src = spx.copy_start + (source - spx.copy_start + offset) % copy_width
      for ch in 1..<=self.fbw_channels {
        if spx.channel_uses[ch] {
          let coeffs = self.transform_coeffs[ch]
          coeffs[destination + offset] = coeffs[src]
        }
      }
    }
    // Retain an exact end-of-region cursor so the next band flags the wrap.
    source = spx.copy_start +
      1 +
      (source - spx.copy_start + size - 1) % copy_width
    destination = destination + size
  }
  for ch in 1..<=self.fbw_channels {
    if !spx.channel_uses[ch] {
      continue
    }
    let coeffs = self.transform_coeffs[ch]
    let energy = FixedArray::make(spx.bands.val, 0.0)
    let mut bin = spx.start
    for band in 0..<spx.bands.val {
      let size = spx.band_sizes[band]
      let mut sum = 0.0
      for i in bin..<(bin + size) {
        sum = sum + coeffs[i] * coeffs[i]
      }
      energy[band] = (sum / size.to_double()).sqrt()
      bin = bin + size
    }
    let attenuation = spx.attenuation[ch]
    if attenuation >= 0 {
      let mut notch = spx.start - 2
      let step = -(attenuation + 1).to_double() / 15.0
      for band in 0..<spx.bands.val {
        if wrap[band] {
          for i in 0..<5 {
            let exponent = (3 - (2 - i).abs()).to_double() * step
            coeffs[notch + i] = coeffs[notch + i] * @math.pow(2.0, exponent)
          }
        }
        notch = notch + spx.band_sizes[band]
      }
    }
    bin = spx.start
    for band in 0..<spx.bands.val {
      let noise_scale = spx.noise[ch][band] * energy[band] / -2147483648.0
      let signal_scale = spx.signal[ch][band]
      for _ in 0..<spx.band_sizes[band] {
        let noise = self.dith_state.get().reinterpret_as_int().to_double() *
          noise_scale
        coeffs[bin] = coeffs[bin] * signal_scale + noise
        bin = bin + 1
      }
    }
  }
}

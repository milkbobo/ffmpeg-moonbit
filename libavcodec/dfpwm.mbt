///|
/// DFPWM1a from FFmpeg 9.0.2 `dfpwmdec.c` and `dfpwmenc.c`.
/// Copyright (c) 2022 Jack Bruienne and (c) 2012, 2016 Ben Russell.
/// This port is LGPL-2.1-or-later.
priv struct DfpwmPredictor {
  mut charge : Int32
  mut strength : Int32
  mut target : Int32
}

///|
fn DfpwmPredictor::new() -> DfpwmPredictor {
  { charge: 0, strength: 0, target: -128, }
}

///|
fn DfpwmPredictor::update(self : DfpwmPredictor, target : Int32) -> Unit {
  let charge = self.charge +
    ((self.strength * (target - self.charge) + 512) >> 10)
  self.charge = if charge == self.charge && charge != target {
    charge + (if target == 127 { 1 } else { -1 })
  } else {
    charge
  }
  self.strength = if target == self.target {
    (self.strength + 1).clamp(min=8, max=1023)
  } else {
    (self.strength - 1).max(8)
  }
  self.target = target
}

///|
pub struct DfpwmDecoder {
  priv predictor : DfpwmPredictor
  mut filtered_charge : Int32
}

///|
/// Start decoding a DFPWM1a stream. Reuse the decoder across packets.
pub fn DfpwmDecoder::new() -> DfpwmDecoder {
  { predictor: DfpwmPredictor::new(), filtered_charge: 0, }
}

///|
/// Decode LSB-first DFPWM1a to eight unsigned 8-bit PCM samples per byte.
pub fn DfpwmDecoder::decode(self : DfpwmDecoder, data : BytesView) -> Bytes {
  let predictor = self.predictor
  Bytes::makei(data.length() * 8, i => {
    let target = if ((data[i / 8].to_int() >> (i % 8)) & 1) != 0 {
      127
    } else {
      -128
    }
    let old_charge = predictor.charge
    let changed = target != predictor.target
    predictor.update(target)
    let antijerk = if changed {
      (predictor.charge + old_charge + 1) >> 1
    } else {
      predictor.charge
    }
    self.filtered_charge += (140 * (antijerk - self.filtered_charge) + 128) >> 8
    (self.filtered_charge + 128).to_byte()
  })
}

///|
/// Encode unsigned 8-bit PCM to LSB-first DFPWM1a, padding the last byte
/// with encoded silence. Each call starts a fresh stream.
pub fn encode_dfpwm(samples : BytesView) -> Bytes {
  let predictor = DfpwmPredictor::new()
  Bytes::makei(
    samples.length() / 8 + (if samples.length() % 8 == 0 { 0 } else { 1 }),
    i => {
      let mut code = 0
      for bit in 0..<8 {
        let index = i * 8 + bit
        let sample = if index < samples.length() {
          samples[index].to_int() - 128
        } else {
          0
        }
        let high = sample > predictor.charge || sample == 127
        if high {
          code = code | (1 << bit)
        }
        predictor.update(if high { 127 } else { -128 })
      }
      code.to_byte()
    },
  )
}

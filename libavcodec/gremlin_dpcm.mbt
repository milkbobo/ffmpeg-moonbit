///|
/// Gremlin DPCM delta table from FFmpeg 9.0.2 dpcm.c.
/// Copyright (c) 2003 The FFmpeg project. LGPL-2.1-or-later.
let gremlin_dpcm_deltas : FixedArray[Int32] = {
  let deltas = FixedArray::make(256, 0)
  let mut delta = 0
  let mut code = 64
  let mut step = 45
  for i in 0..<127 {
    delta += code >> 5
    code += step
    step += 2
    deltas[2 * i + 1] = delta
    deltas[2 * i + 2] = -delta
  }
  deltas[255] = delta + (code >> 5)
  deltas
}

///|
pub struct GremlinDpcmDecoder {
  priv predictors : FixedArray[Int32]
}

///|
/// Start a new stream with two zero predictors.
pub fn GremlinDpcmDecoder::new() -> GremlinDpcmDecoder {
  { predictors: FixedArray::make(2, 0), }
}

///|
/// Decode one GDV audio packet. Predictor slots alternate within a packet,
/// including mono streams. Samples wrap to signed 16-bit PCM.
pub fn GremlinDpcmDecoder::decode(
  self : GremlinDpcmDecoder,
  data : BytesView,
) -> Array[Int32] {
  Array::makei(data.length(), i => {
    let slot = i & 1
    let sample = self.predictors[slot] + gremlin_dpcm_deltas[data[i].to_int()]
    self.predictors[slot] = adpcm_sign16(sample & 0xffff)
    self.predictors[slot]
  })
}

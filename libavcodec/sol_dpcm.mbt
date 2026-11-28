///|
/// Sierra SOL DPCM from FFmpeg 9.0.2 dpcm.c, LGPL-2.1-or-later.
let sol_dpcm_nibble_deltas : FixedArray[Int32] = [0, 1, 2, 3, 6, 10, 15, 21]

///|
let sol_dpcm_byte_deltas : FixedArray[Int32] = [
  0x000, 0x008, 0x010, 0x020, 0x030, 0x040, 0x050, 0x060, 0x070, 0x080, 0x090, 0x0a0,
  0x0b0, 0x0c0, 0x0d0, 0x0e0, 0x0f0, 0x100, 0x110, 0x120, 0x130, 0x140, 0x150, 0x160,
  0x170, 0x180, 0x190, 0x1a0, 0x1b0, 0x1c0, 0x1d0, 0x1e0, 0x1f0, 0x200, 0x208, 0x210,
  0x218, 0x220, 0x228, 0x230, 0x238, 0x240, 0x248, 0x250, 0x258, 0x260, 0x268, 0x270,
  0x278, 0x280, 0x288, 0x290, 0x298, 0x2a0, 0x2a8, 0x2b0, 0x2b8, 0x2c0, 0x2c8, 0x2d0,
  0x2d8, 0x2e0, 0x2e8, 0x2f0, 0x2f8, 0x300, 0x308, 0x310, 0x318, 0x320, 0x328, 0x330,
  0x338, 0x340, 0x348, 0x350, 0x358, 0x360, 0x368, 0x370, 0x378, 0x380, 0x388, 0x390,
  0x398, 0x3a0, 0x3a8, 0x3b0, 0x3b8, 0x3c0, 0x3c8, 0x3d0, 0x3d8, 0x3e0, 0x3e8, 0x3f0,
  0x3f8, 0x400, 0x440, 0x480, 0x4c0, 0x500, 0x540, 0x580, 0x5c0, 0x600, 0x640, 0x680,
  0x6c0, 0x700, 0x740, 0x780, 0x7c0, 0x800, 0x900, 0xa00, 0xb00, 0xc00, 0xd00, 0xe00,
  0xf00, 0x1000, 0x1400, 0x1800, 0x1c00, 0x2000, 0x3000, 0x4000,
]

///|
pub struct SolDpcmDecoder {
  priv mode : Int32
  priv predictors : FixedArray[Int32]
}

///|
/// SOL modes 1 and 2 decode old and new 8-bit DPCM. Mode 3 decodes 16-bit DPCM.
pub fn SolDpcmDecoder::new(
  mode : Int32,
  channels : Int32,
) -> Result[SolDpcmDecoder, String] {
  guard mode >= 1 && mode <= 3 && (channels == 1 || channels == 2) else {
    return Err("SOL DPCM: invalid variant or channel count")
  }
  Ok({
    mode,
    predictors: FixedArray::make(channels, if mode == 3 { 0 } else { 128 }),
  })
}

///|
/// Decode a packet to interleaved s16 samples while maintaining predictors.
pub fn SolDpcmDecoder::decode(
  self : SolDpcmDecoder,
  data : BytesView,
) -> Result[Array[Int32], String] {
  let channels = self.predictors.length()
  if self.mode == 3 {
    guard data.length() % channels == 0 else {
      return Err("SOL DPCM: incomplete PCM frame")
    }
    return Ok(
      Array::makei(data.length(), i => {
        let code = data[i].to_int()
        let magnitude = sol_dpcm_byte_deltas[code & 127]
        let channel = i % channels
        let delta = if code < 128 { magnitude } else { -magnitude }
        let sample = adpcm_clip_int16(self.predictors[channel] + delta)
        self.predictors[channel] = sample
        sample
      }),
    )
  }
  guard data.length() <= 0x3fffffff else {
    return Err("SOL DPCM: packet too large")
  }
  Ok(
    Array::makei(data.length() * 2, i => {
      let pair = data[i / 2].to_int()
      let code = if i % 2 == 0 { pair >> 4 } else { pair & 15 }
      let delta = if code < 8 {
        sol_dpcm_nibble_deltas[code]
      } else if self.mode == 1 {
        -sol_dpcm_nibble_deltas[15 - code]
      } else {
        -sol_dpcm_nibble_deltas[code - 8]
      }
      let channel = i % channels
      let sample = adpcm_clip(self.predictors[channel] + delta, 0, 255)
      self.predictors[channel] = sample
      (sample - 128) << 8
    }),
  )
}

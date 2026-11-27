///|
/// Macintosh Audio Compression/Expansion decoder, ported from FFmpeg
/// libavcodec/mace.c by Laszlo Torok, adapted by Francois Revol.
/// LGPL-2.1-or-later.
priv struct MaceChannel {
  mut index : Int32
  mut factor : Int32
  mut prev2 : Int32
  mut previous : Int32
  mut level : Int32
}

///|
/// Stateful decoder for one mono or stereo MACE stream.
struct MaceDecoder {
  channels : FixedArray[MaceChannel]
  bytes_per_channel : Int32
}

///|
/// Open a `mace3` or `mace6` stream. Reuse the decoder across packets.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.mace_decoder_new("mace6", 1).unwrap()
///   assert_eq(decoder.decode_packet(b"\x00").unwrap().length(), 6)
/// }
/// ```
pub fn mace_decoder_new(
  codec : String,
  channels : Int32,
) -> Result[MaceDecoder, String] {
  let bytes_per_channel = match codec {
    "mace3" => 2
    "mace6" => 1
    _ => return Err("mace: unsupported codec")
  }
  if channels != 1 && channels != 2 {
    return Err("mace: expected one or two channels")
  }
  Ok({
    bytes_per_channel,
    channels: FixedArray::makei(channels, _ => {
      index: 0,
      factor: 0,
      prev2: 0,
      previous: 0,
      level: 0,
    }),
  })
}

///|
fn MaceChannel::read_delta(
  self : MaceChannel,
  code : Int32,
  middle : Bool,
) -> Int32 {
  let (adjust, values, stride) = if middle {
    (mace_index2, mace_delta2, 2)
  } else {
    (mace_index3, mace_delta3, 4)
  }
  let row = ((self.index & 0x7F0) >> 4) * stride
  let delta = if code < stride {
    values[row + code]
  } else {
    -1 - values[row + 2 * stride - code - 1]
  }
  self.index = (self.index + adjust[code] - (self.index >> 5)).max(0)
  delta
}

///|
// QuickTime's predictor saturates negative overflow to -32767.
fn mace_clip(value : Int32) -> Int32 {
  if value < -32768 {
    -32767
  } else {
    value.min(32767)
  }
}

///|
// Expand the signed top byte by replicating its bit pattern.
fn mace_s16(value : Int32) -> Int32 {
  (value & -256) | ((value >> 8) & 255)
}

///|
fn MaceChannel::decode3(self : MaceChannel, delta : Int32) -> Int32 {
  let current = mace_clip(delta + self.level)
  self.level = current - (current >> 3)
  mace_s16(current)
}

///|
fn MaceChannel::decode6(self : MaceChannel, delta : Int32) -> (Int32, Int32) {
  self.factor = if (self.previous ^ delta) >= 0 {
    (self.factor + 506).min(32767)
  } else {
    mace_clip(self.factor - 314)
  }
  let current = mace_clip(delta + self.level)
  self.level = (current * self.factor) >> 15
  let half = current >> 1
  let correction = (self.prev2 - half) >> 2
  let first = mace_s16(self.previous + self.prev2 - correction)
  let second = mace_s16(self.previous + half + correction)
  self.prev2 = self.previous
  self.previous = half
  (first, second)
}

///|
/// Decode complete packet groups to interleaved signed 16-bit PCM.
/// Each group produces six samples per channel. An incomplete trailing
/// group is ignored when the packet contains at least one complete group.
pub fn MaceDecoder::decode_packet(
  self : MaceDecoder,
  packet : Bytes,
) -> Result[Array[Int32], String] {
  let channels = self.channels.length()
  let group_size = channels * self.bytes_per_channel
  let groups = packet.length() / group_size
  if groups == 0 || groups > 0x7FFFFFFF / (6 * channels) {
    return Err("mace: invalid packet size")
  }
  let pcm = Array::make(groups * 6 * channels, 0)
  let mace3 = self.bytes_per_channel == 2
  for group in 0..<groups {
    for channel in 0..<channels {
      let state = self.channels[channel]
      let start = group * group_size + channel * self.bytes_per_channel
      let mut out = group * 6 * channels + channel
      for byte in 0..<self.bytes_per_channel {
        let packed = packet[start + byte].to_int()
        let low = packed & 7
        let high = packed >> 5
        let middle = (packed >> 3) & 3
        let (first, last) = if mace3 { (low, high) } else { (high, low) }
        for slot in 0..<3 {
          let code = match slot {
            0 => first
            1 => middle
            _ => last
          }
          let delta = state.read_delta(code, slot == 1)
          if mace3 {
            pcm[out] = state.decode3(delta)
            out = out + channels
          } else {
            let (a, b) = state.decode6(delta)
            pcm[out] = a
            pcm[out + channels] = b
            out = out + 2 * channels
          }
        }
      }
    }
  }
  Ok(pcm)
}

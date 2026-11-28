///|
/// Pro Pinball soundbanks from FFmpeg 9.0.2 pp_bnk.c.
/// Copyright (C) 2020 Zane van Iperen. LGPL-2.1-or-later.
pub struct PpBnk {
  sample_rate : Int32
  tracks : Array[(Int32, Int32)]
  stereo : Bool
}

///|
fn probe_pp_bnk(pd : ProbeData) -> Int32 {
  let data = pd.buf[:]
  guard data.length() >= 40 else { return 0 }
  let rate = wav_u32(data, 4, false)
  let count = wav_u32(data, 12, false)
  if rate is (5512L | 11025L | 22050L | 44100L) &&
    count > 0L &&
    count <= 0x7fffffffL &&
    wav_u32(data, 8, false) == 1L &&
    wav_u32(data, 16, false) <= 3L &&
    wav_u32(data, 28, false) == rate &&
    wav_u32(data, 32, false) == 1L &&
    wav_u32(data, 36, false) == 1L {
    probe_score_max / 4 + 1
  } else {
    0
  }
}

///|
fn pp_bnk_open(data : Bytes) -> Result[PpBnk, String] {
  guard probe_pp_bnk(ProbeData::new(data)) > 0 else {
    return Err("pp_bnk: invalid header")
  }
  let view = data[:]
  let rate = wav_u32(view, 4, false)
  let count = wav_u32(view, 12, false)
  guard count <= (data.length() - 20).to_int64() / 20L else {
    return Err("pp_bnk: truncated track table")
  }
  let tracks : Array[(Int32, Int32)] = []
  let mut pos = 20
  for _ in 0..<count.to_int() {
    guard data.length() - pos >= 20 else {
      return Err("pp_bnk: truncated track header")
    }
    guard wav_u32(view, pos + 8, false) == rate &&
      wav_u32(view, pos + 12, false) == 1L &&
      wav_u32(view, pos + 16, false) == 1L else {
      return Err("pp_bnk: invalid track parameters")
    }
    let size = wav_u32(view, pos + 4, false)
    let start = pos + 20
    guard size <= (data.length() - start).to_int64() else {
      return Err("pp_bnk: truncated track audio")
    }
    tracks.push((start, size.to_int()))
    pos = start + size.to_int()
  }
  let stereo = (wav_u32(view, 16, false) & 2L) != 0L &&
    tracks.length() == 2 &&
    tracks[0].1 == tracks[1].1
  Ok({ sample_rate: rate.to_int(), tracks, stereo, })
}

///|
fn PpBnk::next_packet(
  self : PpBnk,
  data : Bytes,
  cursor : Array[Int32],
) -> MediaPacket? {
  let streams = if self.stereo { 1 } else { self.tracks.length() }
  for i in 0..<streams {
    let stream = ((cursor[0].to_int64() + i.to_int64()) % streams.to_int64()).to_int()
    let (start, total) = self.tracks[stream]
    let offset = cursor[stream + 1]
    if offset == total {
      continue
    }
    let size = (total - offset).min(4096)
    let first = start + offset
    let payload = if self.stereo {
      let second = self.tracks[1].0 + offset
      Bytes::makei(size * 2, i => {
        if i < size {
          data[first + i]
        } else {
          data[second + (i - size)]
        }
      })
    } else {
      data[first:first + size].to_owned()
    }
    cursor[0] = (stream + 1) % streams
    cursor[stream + 1] = offset + size
    return Some({
      stream_index: stream,
      data: payload,
      pts: offset.to_int64() * 2L,
      keyframe: offset == 0,
    })
  }
  None
}

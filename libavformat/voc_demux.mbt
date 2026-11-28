///|
// Creative Voice block demuxing, based on FFmpeg vocdec.c and voc_packet.c
// (copyright 2006 Aurelien Jacobs, LGPL-2.1-or-later).
let voc_magic : Bytes = b"Creative Voice File\x1a"

///|
fn voc_le16(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() | (data[pos + 1].to_int() << 8)
}

///|
fn voc_codec(tag : Int32) -> String {
  match tag {
    0 => "pcm_u8"
    1 => "adpcm_sbpro_4"
    2 => "adpcm_sbpro_3"
    3 => "adpcm_sbpro_2"
    4 => "pcm_s16le"
    6 => "pcm_alaw"
    7 => "pcm_mulaw"
    0x0200 => "adpcm_ct"
    _ => ""
  }
}

///|
/// Open single-format Creative Voice PCM, G.711, or Creative ADPCM.
/// Control and text blocks are skipped, matching FFmpeg playback.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_voc_open(b"Creative Voice File") is Err(_))
/// }
/// ```
pub fn av_voc_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if data.length() < 26 || data[:20] != voc_magic || voc_le16(data, 20) != 26 {
    return Err("voc: invalid header")
  }
  let frames : Array[RawAudioFrame] = []
  let mut rate = 0
  let mut channels = 0
  let mut tag = -1
  let mut extension : (Int32, Int32)? = None
  let mut pts = 0L
  for pos = 26; pos < data.length(); {
    let kind = data[pos].to_int()
    if kind == 0 {
      break
    }
    if data.length() - pos < 4 {
      return Err("voc: truncated block header")
    }
    let start = pos + 4
    let size = voc_le16(data, pos + 1) | (data[pos + 3].to_int() << 16)
    let length = if size == 0 { data.length() - start } else { size }
    if length > data.length() - start {
      return Err("voc: truncated block")
    }
    let end = start + length
    let (block_rate, block_channels, block_tag, payload) = match kind {
      1 => {
        if length < 2 {
          return Err("voc: truncated sound header")
        }
        let (r, c) = extension.unwrap_or(
          (1000000 / (256 - data[start].to_int()), 1),
        )
        extension = None
        (r, c, data[start + 1].to_int(), start + 2)
      }
      2 => {
        if rate == 0 {
          return Err("voc: continuation before sound header")
        }
        (rate, channels, tag, start)
      }
      8 => {
        if length < 4 {
          return Err("voc: truncated extended header")
        }
        let c = data[start + 3].to_int() + 1
        extension = Some((256000000 / (c * (65536 - voc_le16(data, start))), c))
        continue end
      }
      9 => {
        if length < 12 {
          return Err("voc: truncated new sound header")
        }
        extension = None
        (
          pb_le32(data, start).reinterpret_as_int(),
          data[start + 5].to_int(),
          voc_le16(data, start + 6),
          start + 12,
        )
      }
      _ => continue end
    }
    if block_rate <= 0 ||
      block_channels < 1 ||
      block_channels > 64 ||
      voc_codec(block_tag) == "" {
      return Err("voc: unsupported stream parameters")
    }
    let sbpro = block_tag >= 1 && block_tag <= 3
    let ct_adpcm = block_tag == 0x0200
    if sbpro && (block_channels > 2 || (block_tag == 2 && block_channels != 1)) {
      return Err("voc: unsupported Sound Blaster Pro channel count")
    }
    if ct_adpcm && block_channels > 2 {
      return Err("voc: unsupported Creative Technology ADPCM channel count")
    }
    if rate != 0 &&
      (rate != block_rate || channels != block_channels || tag != block_tag) {
      return Err("voc: midstream format change")
    }
    rate = block_rate
    channels = block_channels
    tag = block_tag
    let align = if sbpro || ct_adpcm {
      1
    } else {
      channels * (if tag == 4 { 2 } else { 1 })
    }
    if (end - payload) % align != 0 {
      return Err("voc: incomplete sample")
    }
    let packet_size = 2048 / align * align
    for offset = payload; offset < end; {
      let count = (end - offset).min(packet_size)
      let duration = if sbpro {
        let seed = if frames.is_empty() { channels } else { 0 }
        if count < seed {
          return Err("voc: missing ADPCM seed sample")
        }
        (if seed > 0 { 1 } else { 0 }) + (count - seed) * (tag + 1) / channels
      } else if ct_adpcm {
        count * 2 / channels
      } else {
        count / align
      }
      frames.push({
        pos: offset.to_int64(),
        size: count,
        pts,
        duration,
        is_keyframe: !ct_adpcm || frames.is_empty(),
      })
      pts += duration.to_int64()
      continue offset + count
    }
    continue end
  }
  if frames.is_empty() {
    return Err("voc: missing sound blocks")
  }
  Ok({
    codec: voc_codec(tag),
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: frames[0].duration,
    frames,
    total_samples: pts,
    bit_rate: 0,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
fn probe_voc(pd : ProbeData) -> Int32 {
  if pd.buf.length() < 26 || pd.buf[:20] != voc_magic {
    return 0
  }
  let version = voc_le16(pd.buf, 22)
  let checksum = (0x1233 - version) & 0xffff
  if checksum == voc_le16(pd.buf, 24) {
    probe_score_max
  } else {
    10
  }
}

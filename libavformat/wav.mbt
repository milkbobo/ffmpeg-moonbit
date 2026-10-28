///|
/// MoonBit port of the FFmpeg 9.0.2 WAV/RIFF demuxer slice:
/// `libavformat/wavdec.c` (`wav_read_header`, `wav_read_packet`,
/// `wav_probe`, `set_max_size`), `libavformat/riffdec.c`
/// (`ff_get_wav_header`, `ff_wav_codec_get_id`, `parse_waveformatex`) and
/// `libavformat/pcm.c` (`ff_pcm_default_packet_size`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The demuxer works on an in-memory file (the same design as the MP4,
/// Matroska and raw-audio slices) and materialises the packet list eagerly.
/// Packet boundaries follow `wav_read_packet`: at most `max_size` bytes,
/// truncated to `data_end` and rounded down to `block_align`, with
/// `max_size` derived from the bit rate at the 10 fps PCM target.
///
/// Out of scope: W64 GUID chunk walking, SMV video appended to a WAV,
/// BEXT/LIST/cue metadata, SPDIF probing, XMA2/HEAACWAVEINFO extradata,
/// and parsing of non-PCM payloads (they are framed, not decoded).

///|
/// `WAVEFORMATEX` fields this slice needs. `extradata` is the `cbSize`
/// payload (e.g. `AudioSpecificConfig` for WAVE_FORMAT_AAC). */
pub struct WavFormat {
  format_tag : Int32
  codec : String
  channels : Int32
  sample_rate : Int32
  /// `nAvgBytesPerSec` after `compute_bitrate` reconciliation.
  byte_rate : Int32
  bit_rate : Int32
  block_align : Int32
  bits_per_sample : Int32
  channel_mask : UInt32
  extradata : Bytes
}

///|
/// One demuxed WAV packet. Times are in PCM sample units (the stream's
/// time base is 1/sample_rate). */
pub struct WavPacket {
  pos : Int64
  size : Int32
  pts : Int64
  duration : Int32
  is_keyframe : Bool
}

///|
/// A parsed WAV stream plus its eagerly framed packets. */
pub struct WavDemux {
  format : WavFormat
  data_offset : Int64
  data_size : Int64
  /// Duration in PCM samples.
  sample_count : Int64
  /// `wav->max_size`, the packet size cap used by `wav_read_packet`.
  max_size : Int32
  packets : Array[WavPacket]
}

///|
/// `PCM_DEMUX_TARGET_FPS`: the packetiser aims for this many PCM packets
/// per second. */
let pcm_demux_target_fps : Int32 = 10

///|
fn wav_u16(data : BytesView, off : Int32, big_endian : Bool) -> Int32 {
  if off < 0 || off + 2 > data.length() {
    return 0
  }
  let a = data[off].to_int()
  let b = data[off + 1].to_int()
  if big_endian {
    (a << 8) | b
  } else {
    a | (b << 8)
  }
}

///|
fn wav_u32(data : BytesView, off : Int32, big_endian : Bool) -> Int64 {
  if off < 0 || off + 4 > data.length() {
    return 0L
  }
  let a = data[off].to_int().to_int64()
  let b = data[off + 1].to_int().to_int64()
  let c = data[off + 2].to_int().to_int64()
  let d = data[off + 3].to_int().to_int64()
  if big_endian {
    (a << 24) | (b << 16) | (c << 8) | d
  } else {
    a | (b << 8) | (c << 16) | (d << 24)
  }
}

///|
fn wav_u64(data : BytesView, off : Int32) -> Int64 {
  if off < 0 || off + 8 > data.length() {
    return 0L
  }
  let lo = wav_u32(data, off, false)
  let hi = wav_u32(data, off + 4, false)
  (hi << 32) | (lo & 0xFFFFFFFFL)
}

///|
/// Four-character chunk id as a string (`MKTAG` order). */
pub fn wav_fourcc(data : BytesView, off : Int32) -> String {
  if off < 0 || off + 4 > data.length() {
    return ""
  }
  let sb = StringBuilder()
  for i in 0..<4 {
    sb.write_char(data[off + i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// `wav_probe`: `RIFF`/`RIFX` + `WAVE`, or `RF64`/`BW64` + `ds64`. */
pub fn av_wav_probe(data : BytesView) -> Bool {
  if data.length() <= 32 {
    return false
  }
  let riff = wav_fourcc(data, 0)
  if wav_fourcc(data, 8) != "WAVE" {
    return false
  }
  riff == "RIFF" ||
  riff == "RIFX" ||
  ((riff == "RF64" || riff == "BW64") && wav_fourcc(data, 12) == "ds64")
}

///|
/// `ff_wav_codec_id`: the subset of `ff_codec_wav_tags` this port names,
/// resolved by bits per sample where the tag table has several entries.
pub fn ff_wav_codec_id(tag : Int32, bits : Int32) -> String {
  match tag {
    0x0001 =>
      if bits <= 8 {
        "pcm_u8"
      } else if bits <= 16 {
        "pcm_s16le"
      } else if bits <= 24 {
        "pcm_s24le"
      } else if bits <= 32 {
        "pcm_s32le"
      } else {
        "pcm_s64le"
      }
    0x0003 => if bits > 32 { "pcm_f64le" } else { "pcm_f32le" }
    0x0002 => "adpcm_ms"
    0x0006 => "pcm_alaw"
    0x0007 => "pcm_mulaw"
    0x0010 | 0x0017 => "adpcm_ima_oki"
    0x0011 => "adpcm_ima_wav"
    0x0020 => "adpcm_yamaha"
    0x0031 | 0x0032 => "gsm_ms"
    0x028F => "adpcm_g722"
    0x0042 | 0x0111 => "g723_1"
    0x0045 | 0x0014 | 0x0040 | 0x0064 => "adpcm_g726"
    0x0050 => "mp2"
    0x0055 => "mp3"
    0x0061 => "adpcm_ima_dk4"
    0x0062 => "adpcm_ima_dk3"
    0x0083 | 0x2222 => "g729"
    0x00FF | 0x1600 | 0x1610 => "aac"
    0x0130 => "sipr"
    0x1602 => "aac_latm"
    0x0160 => "wmav1"
    0x0161 => "wmav2"
    0x0162 => "wmapro"
    0x0163 => "wmalossless"
    0x2000 => "ac3"
    0x2001 => "dts"
    _ => ""
  }
}

///|
/// `ff_get_wav_header` reads RIFX fields big-endian but keeps the little-endian
/// codec id, so FFmpeg reports e.g. `pcm_s16le` and decodes the BE payload
/// byte-swapped. The port maps the ids to their BE variants instead, making
/// `pcm_*be` the codec name for the (spec-correct) big-endian payload.
fn wav_codec_be(codec : String) -> String {
  match codec {
    "pcm_s16le" => "pcm_s16be"
    "pcm_s24le" => "pcm_s24be"
    "pcm_s32le" => "pcm_s32be"
    "pcm_s64le" => "pcm_s64be"
    "pcm_u16le" => "pcm_u16be"
    "pcm_u24le" => "pcm_u24be"
    "pcm_u32le" => "pcm_u32be"
    "pcm_f32le" => "pcm_f32be"
    "pcm_f64le" => "pcm_f64be"
    _ => codec
  }
}

///|
/// `av_get_bits_per_sample` for the PCM/ADPCM codecs this demuxer names. */
pub fn wav_bits_per_sample(codec : String) -> Int32 {
  match codec {
    "pcm_u8" | "pcm_s8" | "pcm_alaw" | "pcm_mulaw" => 8
    "pcm_s16le" | "pcm_s16be" | "pcm_u16le" | "pcm_u16be" => 16
    "pcm_s24le" | "pcm_s24be" | "pcm_u24le" | "pcm_u24be" => 24
    "pcm_s32le"
    | "pcm_s32be"
    | "pcm_u32le"
    | "pcm_u32be"
    | "pcm_f32le"
    | "pcm_f32be"
    | "pcm_f24le"
    | "pcm_f16le" => 32
    "pcm_f64le" | "pcm_f64be" | "pcm_s64le" | "pcm_s64be" => 64
    "adpcm_ms" | "adpcm_ima_wav" | "adpcm_ima_oki" | "adpcm_yamaha" => 4
    _ => 0
  }
}

///|
/// `compute_bitrate` for the deterministic block codecs (PCM). Returns 0 when
/// the header is not self-consistent. */
fn wav_expected_bitrate(
  codec : String,
  sample_rate : Int32,
  channels : Int32,
  block_align : Int32,
  bits_per_coded_sample : Int32,
) -> Int64 {
  if sample_rate <= 0 || block_align <= 0 || channels <= 0 {
    return 0L
  }
  match codec {
    "pcm_s8"
    | "pcm_u8"
    | "pcm_s16le"
    | "pcm_s16be"
    | "pcm_u16le"
    | "pcm_u16be"
    | "pcm_s24le"
    | "pcm_s24be"
    | "pcm_s32le"
    | "pcm_s32be"
    | "pcm_s64le"
    | "pcm_f32le"
    | "pcm_f32be"
    | "pcm_f64le"
    | "pcm_f64be"
    | "pcm_alaw"
    | "pcm_mulaw" => {
      let align = (bits_per_coded_sample + 7) / 8 * channels
      if block_align != align {
        0L
      } else {
        sample_rate.to_int64() * align.to_int64() * 8L
      }
    }
    _ => 0L
  }
}

///|
/// `av_log2` for a positive value. */
fn wav_log2(v : Int32) -> Int32 {
  let mut n = -1
  let mut x = v
  while x > 0 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `ff_pcm_default_packet_size`; a negative result becomes the C's 4096
/// fallback in `set_max_size`. */
fn wav_pcm_default_packet_size(
  block_align : Int32,
  codec : String,
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> Int32 {
  if block_align <= 0 {
    return -1
  }
  let max_samples = 2147483647 / block_align
  let bits = wav_bits_per_sample(codec)
  let mut br = bit_rate.to_int64()
  if bits > 0 && sample_rate > 0 && channels > 0 {
    br = bits.to_int64() * sample_rate.to_int64() * channels.to_int64()
  }
  let mut nb_samples = 0
  if br > 0 {
    let mut n = br /
      8L /
      pcm_demux_target_fps.to_int64() /
      block_align.to_int64()
    if n < 1L {
      n = 1L
    }
    if n > max_samples.to_int64() {
      n = max_samples.to_int64()
    }
    nb_samples = 1 << wav_log2(n.to_int())
  } else {
    nb_samples = 4096 / block_align
    if nb_samples < 1 {
      nb_samples = 1
    }
    if nb_samples > max_samples {
      nb_samples = max_samples
    }
  }
  block_align * nb_samples
}

///|
/// Parse a `fmt ` chunk body starting at `off`.
fn wav_parse_fmt(
  data : BytesView,
  off : Int32,
  size : Int32,
  big_endian : Bool,
) -> Result[WavFormat, String] {
  if size < 14 {
    return Err("EINVAL: wav header size < 14")
  }
  let mut pos = off
  let mut format_tag = wav_u16(data, pos, big_endian)
  pos = pos + 2
  let mut channels = 0
  let mut sample_rate = 0
  let mut byte_rate = 0L
  let mut block_align = 0
  if format_tag != 0x0165 {
    channels = wav_u16(data, pos, big_endian)
    pos = pos + 2
    sample_rate = wav_u32(data, pos, big_endian).to_int()
    pos = pos + 4
    byte_rate = wav_u32(data, pos, big_endian)
    pos = pos + 4
    block_align = wav_u16(data, pos, big_endian)
    pos = pos + 2
  }
  let mut bits = 8
  if size == 14 {
    bits = 8
  } else {
    bits = wav_u16(data, pos, big_endian)
    pos = pos + 2
  }
  let mut codec = if format_tag == 0xFFFE {
    ""
  } else {
    ff_wav_codec_id(format_tag, bits)
  }
  let mut channel_mask : UInt32 = 0
  let mut extradata : Bytes = b""
  if size >= 18 && format_tag != 0x0165 {
    let mut cb_size = wav_u16(data, pos, big_endian)
    pos = pos + 2
    if big_endian {
      return Err("PATCHWELCOME: WAVEFORMATEX support for RIFX files")
    }
    let mut remaining = size - 18
    if cb_size > remaining {
      cb_size = remaining
    }
    let mut cb = cb_size
    if cb >= 22 && format_tag == 0xFFFE {
      let valid_bits = wav_u16(data, pos, big_endian)
      if valid_bits != 0 {
        bits = valid_bits
      }
      pos = pos + 2
      channel_mask = wav_u32(data, pos, false).to_int().reinterpret_as_uint()
      pos = pos + 4
      let subformat = data[pos:pos + 16]
      pos = pos + 16
      let base_matches = subformat.length() == 16 &&
        subformat[4] == b'\x00' &&
        subformat[5] == b'\x00' &&
        subformat[6] == b'\x10' &&
        subformat[7] == b'\x00' &&
        subformat[8] == b'\x80' &&
        subformat[9] == b'\x00' &&
        subformat[10] == b'\x00' &&
        subformat[11] == b'\xaa' &&
        subformat[12] == b'\x00' &&
        subformat[13] == b'\x38' &&
        subformat[14] == b'\x9b' &&
        subformat[15] == b'\x71'
      if base_matches {
        format_tag = wav_u32(subformat, 0, false).to_int()
        codec = ff_wav_codec_id(format_tag, bits)
      }
      cb = cb - 22
      remaining = remaining - 22
    }
    if cb > 0 {
      let end = if pos + cb > data.length() { data.length() } else { pos + cb }
      extradata = data[pos:end].to_owned()
      pos = pos + cb
      remaining = remaining - cb
    }
    pos = pos + remaining
  } else if format_tag == 0x0165 && size >= 32 {
    let end = if off + size > data.length() {
      data.length()
    } else {
      off + size
    }
    extradata = data[off + 4:end].to_owned()
  }
  if sample_rate <= 0 {
    return Err("EINVAL: invalid sample rate")
  }
  let codec = if big_endian { wav_codec_be(codec) } else { codec }
  let mut bit_rate = byte_rate * 8L
  let expected = wav_expected_bitrate(
    codec, sample_rate, channels, block_align, bits,
  )
  if expected != 0L && bit_rate / 8L != expected / 8L {
    bit_rate = expected
  }
  Ok({
    format_tag,
    codec,
    channels,
    sample_rate,
    byte_rate: (bit_rate / 8L).to_int(),
    bit_rate: if bit_rate > 2147483647L {
      2147483647
    } else {
      bit_rate.to_int()
    },
    block_align,
    bits_per_sample: bits,
    channel_mask,
    extradata,
  })
}

///|
/// Open an in-memory WAV/RIFX/RF64/BW64 file.
pub fn av_wav_open(data : Bytes) -> Result[WavDemux, String] {
  if data.length() < 12 {
    return Err("EINVAL: file too short")
  }
  let riff = wav_fourcc(data, 0)
  let big_endian = riff == "RIFX"
  let rf64 = riff == "RF64" || riff == "BW64"
  if riff != "RIFF" && riff != "RIFX" && !rf64 {
    return Err("EINVAL: invalid start code in RIFF header")
  }
  if wav_fourcc(data, 8) != "WAVE" {
    return Err("EINVAL: invalid format in RIFF header")
  }
  let mut pos = 12
  let mut rf64_data_size = 0L
  let mut rf64_sample_count = 0L
  if rf64 {
    if wav_fourcc(data, pos) != "ds64" {
      return Err("EINVAL: missing ds64")
    }
    let size = wav_u32(data, pos + 4, false).to_int()
    if size < 24 {
      return Err("EINVAL: ds64 too short")
    }
    rf64_data_size = wav_u64(data, pos + 12)
    rf64_sample_count = wav_u64(data, pos + 20)
    if rf64_data_size < 0L || rf64_sample_count < 0L {
      return Err("EINVAL: negative ds64 size")
    }
    pos = pos + 8 + size
  }
  let mut format : WavFormat? = None
  let mut got_fmt = false
  let mut data_ofs = -1L
  let mut data_size = 0L
  let mut sample_count = 0L
  while pos + 8 <= data.length() {
    let tag = wav_fourcc(data, pos)
    let size64 = wav_u32(data, pos + 4, big_endian)
    let body = pos + 8
    let next_ofs = body.to_int64() + size64 + (size64 & 1L)
    if tag == "fmt " && !got_fmt {
      match wav_parse_fmt(data, body, size64.to_int(), big_endian) {
        Ok(parsed) => {
          format = Some(parsed)
          got_fmt = true
        }
        Err(e) => return Err(e)
      }
    } else if tag == "fact" {
      if sample_count == 0L && body + 4 <= data.length() {
        sample_count = wav_u32(data, body, big_endian)
      }
    } else if tag == "data" {
      let size = if rf64 {
        rf64_data_size
      } else if size64 > 0L && size64 != 0xFFFFFFFFL {
        size64
      } else {
        0L
      }
      data_size = size
      data_ofs = body.to_int64()
      if rf64 && sample_count == 0L {
        sample_count = rf64_sample_count
      }
      if size == 0L {
        data_size = data.length().to_int64() - data_ofs
      }
    }
    if next_ofs <= pos.to_int64() {
      break
    }
    if next_ofs >= data.length().to_int64() {
      break
    }
    pos = next_ofs.to_int()
  }
  let fmt = match format {
    Some(f) => f
    None => return Err("EINVAL: no 'fmt ' tag found")
  }
  if data_ofs < 0L {
    return Err("EINVAL: no 'data' tag found")
  }
  let remaining = data.length().to_int64() - data_ofs
  if data_size <= 0L || data_size > remaining {
    data_size = remaining
  }
  let exact_bits = wav_bits_per_sample(fmt.codec)
  if (sample_count == 0L || exact_bits > 0) &&
    fmt.channels > 0 &&
    data_size > 0L &&
    exact_bits > 0 {
    sample_count = data_size *
      8L /
      (fmt.channels.to_int64() * exact_bits.to_int64())
  }
  let max_size = wav_pcm_default_packet_size(
    fmt.block_align,
    fmt.codec,
    fmt.sample_rate,
    fmt.channels,
    fmt.bit_rate,
  )
  let max_size = if max_size < 0 { 4096 } else { max_size }
  let packets : Array[WavPacket] = []
  let mut packet_pos = data_ofs
  let mut left = data_size
  let mut pts = 0L
  while left > 0L {
    let mut size = max_size
    if fmt.block_align > 1 {
      if size < fmt.block_align {
        size = fmt.block_align
      }
      size = size / fmt.block_align * fmt.block_align
    }
    if left < size.to_int64() {
      size = left.to_int()
    }
    let duration = if fmt.block_align > 0 {
      size / fmt.block_align
    } else if fmt.channels > 0 && exact_bits > 0 {
      size * 8 / (fmt.channels * exact_bits)
    } else {
      0
    }
    packets.push({ pos: packet_pos, size, pts, duration, is_keyframe: true, })
    packet_pos = packet_pos + size.to_int64()
    pts = pts + duration.to_int64()
    left = left - size.to_int64()
  }
  Ok({
    format: fmt,
    data_offset: data_ofs,
    data_size,
    sample_count,
    max_size,
    packets,
  })
}

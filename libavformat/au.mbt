///|
/// Sun/NeXT AU (`\.snd`) demuxer, ported from FFmpeg 9.0.2 `libavformat/au.c`.
///
/// Supports µ-law/A-law, signed PCM 8/16/24/32-bit big-endian, IEEE float
/// 32/64-bit and G.726LE (2/3/4/5-bit codewords, tags 23/25/26/'7262').
/// The header's annotation field is skipped.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AuFormat {
  codec : String
  codec_tag : UInt32
  channels : Int32
  sample_rate : Int32
  /// Bits per coded sample (G.726LE codeword size for ADPCM).
  bits : Int32
  block_align : Int32
}

///|
pub struct AuPacket {
  pos : Int64
  size : Int32
  pts : Int64
  duration : Int32
}

///|
pub struct AuDemux {
  format : AuFormat
  data_offset : Int64
  data_size : Int64
  sample_count : Int64
  packets : Array[AuPacket]
}

///|
fn au_u32be(data : Bytes, off : Int32) -> UInt32 {
  (data[off].to_uint() << 24) |
  (data[off + 1].to_uint() << 16) |
  (data[off + 2].to_uint() << 8) |
  data[off + 3].to_uint()
}

///|
fn au_codec_for_tag(tag : UInt32) -> (String, Int32) {
  if tag == 1U {
    ("pcm_mulaw", 8)
  } else if tag == 2U {
    ("pcm_s8", 8)
  } else if tag == 3U {
    ("pcm_s16be", 16)
  } else if tag == 4U {
    ("pcm_s24be", 24)
  } else if tag == 5U {
    ("pcm_s32be", 32)
  } else if tag == 6U {
    ("pcm_f32be", 32)
  } else if tag == 7U {
    ("pcm_f64be", 64)
  } else if tag == 23U {
    ("adpcm_g726le", 4)
  } else if tag == 25U {
    ("adpcm_g726le", 3)
  } else if tag == 26U {
    ("adpcm_g726le", 5)
  } else if tag == 0x37323632U {
    ("adpcm_g726le", 2)
  } else if tag == 27U {
    ("pcm_alaw", 8)
  } else {
    ("", 0)
  }
}

///|
/// Parse a Sun AU file into a stream description and packets.
pub fn av_au_open(data : Bytes) -> Result[AuDemux, String] {
  if data.length() < 24 ||
    data[0] != b'.' ||
    data[1] != b's' ||
    data[2] != b'n' ||
    data[3] != b'd' {
    return Err("au: missing .snd header")
  }
  let header_size = au_u32be(data, 4).reinterpret_as_int()
  let data_size = au_u32be(data, 8)
  let tag = au_u32be(data, 12)
  let sample_rate = au_u32be(data, 16).reinterpret_as_int()
  let channels = au_u32be(data, 20).reinterpret_as_int()
  if header_size < 24 || header_size > data.length() {
    return Err("au: invalid header size")
  }
  if sample_rate <= 0 || channels < 1 || channels > 64 {
    return Err("au: invalid stream parameters")
  }
  let (codec, bits) = au_codec_for_tag(tag)
  if codec == "" || bits == 0 {
    return Err("au: unsupported encoding \{tag}")
  }
  let bytes_per_sample = bits / 8
  let block_align = if codec == "adpcm_g726le" {
    bits
  } else {
    channels * bytes_per_sample
  }
  if block_align <= 0 {
    return Err("au: invalid block alignment")
  }
  let available = data.length() - header_size
  let size = if data_size == 0xFFFFFFFFU ||
    data_size.to_int64() > available.to_int64() {
    available.to_int64()
  } else {
    data_size.to_int64()
  }
  let sample_count = if codec == "adpcm_g726le" {
    size * 8L / (bits.to_int64() * channels.to_int64())
  } else {
    size / bytes_per_sample.to_int64() / channels.to_int64()
  }
  let max_size = 4096 / block_align * block_align
  let packet_size = if max_size > 0 { max_size } else { block_align }
  let packets : Array[AuPacket] = []
  let mut pos = header_size.to_int64()
  let mut left = size
  let mut pts = 0L
  while left > 0L {
    let psize = if left < packet_size.to_int64() {
      left.to_int()
    } else {
      packet_size
    }
    let duration = if codec == "adpcm_g726le" {
      psize * 8 / bits / channels
    } else {
      psize / bytes_per_sample / channels
    }
    packets.push({ pos, size: psize, pts, duration, })
    pos = pos + psize.to_int64()
    pts = pts + duration.to_int64()
    left = left - psize.to_int64()
  }
  Ok({
    format: { codec, codec_tag: tag, channels, sample_rate, bits, block_align, },
    data_offset: header_size.to_int64(),
    data_size: size,
    sample_count,
    packets,
  })
}

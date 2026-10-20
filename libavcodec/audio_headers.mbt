///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/adts_header.c`,
/// `libavcodec/adts_parser.c`, `libavcodec/mpegaudiodecheader.c` and the
/// tables of `libavcodec/mpegaudiotabs.h`: the AAC ADTS header and the MPEG
/// audio (MP1/MP2/MP3) frame header.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Deviations:
///   * `ff_adts_header_parse` returns the whole `AACADTSHeaderInfo` instead of
///     the duplicated frame length; `frame_length` carries the C return value.
///   * `avpriv_mpegaudio_decode_header`'s free-format return value 1 is carried
///     in `free_format`; `frame_size` stays 0 as in the C.
///   * Error values are strings: "AAC_SYNC", "AAC_SAMPLE_RATE",
///     "AAC_FRAME_SIZE", "EINVAL".

///| `AV_AAC_ADTS_HEADER_SIZE`. */
pub let av_aac_adts_header_size : Int = 7

///| `MODE_EXT_MS_STEREO`. */
pub let mode_ext_ms_stereo : Int = 2

///| `MODE_EXT_I_STEREO`. */
pub let mode_ext_i_stereo : Int = 1

///| `MPA_MONO` (the mode field's mono value). */
let mpa_mono : Int = 3

///| `ff_mpa_freq_tab[3]`. */
let ff_mpa_freq_tab : Array[Int] = [44100, 48000, 32000]

///| `ff_mpa_bitrate_tab[2][3][15]`. */
let ff_mpa_bitrate_tab : Array[Array[Array[Int]]] = [
  [
    [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  ],
  [
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  ],
]

// ---------------------------------------------------------------------------
// AAC ADTS
// ---------------------------------------------------------------------------

///| `AACADTSHeaderInfo`. */
pub struct AacAdtsHeaderInfo {
  sample_rate : Int
  samples : Int
  bit_rate : Int
  crc_absent : Int
  object_type : Int
  sampling_index : Int
  chan_config : Int
  num_aac_frames : Int
  frame_length : Int
}

///|
/// `ff_adts_header_parse`: parse the 54-bit ADTS fixed + variable header.
/// The reader must be positioned at the start of the frame.
pub fn ff_adts_header_parse(gb : BitReader) -> Result[AacAdtsHeaderInfo, String] {
  if gb.read(12) != 0xFFFU {
    return Err("AAC_SYNC")
  }
  let _ = gb.read1() // id
  let _ = gb.read(2) // layer
  let crc_absent = gb.read1().reinterpret_as_int()
  let aot = gb.read(2).reinterpret_as_int()
  let sr = gb.read(4).reinterpret_as_int()
  if sr < 0 || sr >= mpeg4audio_sample_rates.length() ||
    mpeg4audio_sample_rates[sr] == 0 {
    return Err("AAC_SAMPLE_RATE")
  }
  let _ = gb.read1() // private_bit
  let ch = gb.read(3).reinterpret_as_int()
  let _ = gb.read1() // original/copy
  let _ = gb.read1() // home
  let _ = gb.read1() // copyright_identification_bit
  let _ = gb.read1() // copyright_identification_start
  let size = gb.read(13).reinterpret_as_int()
  if size < av_aac_adts_header_size {
    return Err("AAC_FRAME_SIZE")
  }
  let _ = gb.read(11) // adts_buffer_fullness
  let rdb = gb.read(2).reinterpret_as_int()
  let samples = (rdb + 1) * 1024
  let sample_rate = mpeg4audio_sample_rates[sr]
  Ok({
    sample_rate,
    samples,
    bit_rate: (size * 8 * sample_rate) / samples,
    crc_absent,
    object_type: aot + 1,
    sampling_index: sr,
    chan_config: ch,
    num_aac_frames: rdb + 1,
    frame_length: size,
  })
}

///| `ff_adts_header_parse_buf`: parse a 7-byte ADTS header. */
pub fn ff_adts_header_parse_buf(buf : Bytes) -> Result[AacAdtsHeaderInfo, String] {
  if buf.length() < av_aac_adts_header_size {
    return Err("EINVAL")
  }
  let gb = BitReader::with_size(buf, av_aac_adts_header_size * 8)
  ff_adts_header_parse(gb)
}

// ---------------------------------------------------------------------------
// MPEG audio
// ---------------------------------------------------------------------------

///| `MPADecodeHeader`. */
pub struct MpaDecodeHeader {
  frame_size : Int
  error_protection : Int
  layer : Int
  sample_rate : Int
  sample_rate_index : Int
  bit_rate : Int
  nb_channels : Int
  mode : Int
  mode_ext : Int
  lsf : Int
  ///| `avpriv_mpegaudio_decode_header` returned 1 (free format).
  free_format : Bool
}

///| `ff_mpa_check_header`: quick resync validation. */
pub fn ff_mpa_check_header(header : UInt) -> Bool {
  if (header & 0xFFE00000U) != 0xFFE00000U {
    return false
  }
  if (header & (3U << 19)) == (1U << 19) {
    return false
  }
  if (header & (3U << 17)) == 0U {
    return false
  }
  if (header & (0xFU << 12)) == (0xFU << 12) {
    return false
  }
  if (header & (3U << 10)) == (3U << 10) {
    return false
  }
  true
}

///|
/// `avpriv_mpegaudio_decode_header`: decode a 32-bit MPEG audio frame header
/// (`0xFFExxxxx`). The caller must have validated it (or rely on "EINVAL").
pub fn avpriv_mpegaudio_decode_header(
  header : UInt
) -> Result[MpaDecodeHeader, String] {
  if !ff_mpa_check_header(header) {
    return Err("EINVAL")
  }
  let mut lsf = 0
  let mut mpeg25 = 0
  if (header & (1U << 20)) != 0U {
    lsf = if (header & (1U << 19)) != 0U { 0 } else { 1 }
  } else {
    lsf = 1
    mpeg25 = 1
  }
  let layer = 4 - ((header >> 17) & 3).reinterpret_as_int()
  let mut sample_rate_index = ((header >> 10) & 3).reinterpret_as_int()
  if sample_rate_index >= ff_mpa_freq_tab.length() {
    sample_rate_index = 0
  }
  let sample_rate = ff_mpa_freq_tab[sample_rate_index] >> (lsf + mpeg25)
  sample_rate_index = sample_rate_index + 3 * (lsf + mpeg25)
  let error_protection = (((header >> 16) & 1).reinterpret_as_int()) ^ 1
  let bitrate_index = ((header >> 12) & 0xF).reinterpret_as_int()
  let padding = ((header >> 9) & 1).reinterpret_as_int()
  let mode = ((header >> 6) & 3).reinterpret_as_int()
  let mode_ext = ((header >> 4) & 3).reinterpret_as_int()
  let nb_channels = if mode == mpa_mono { 1 } else { 2 }
  if bitrate_index != 0 {
    let table = ff_mpa_bitrate_tab[lsf][layer - 1][bitrate_index]
    let bit_rate = table * 1000
    let mut frame_size = 0
    if layer == 1 {
      frame_size = (table * 12000) / sample_rate
      frame_size = (frame_size + padding) * 4
    } else if layer == 2 {
      frame_size = (table * 144000) / sample_rate + padding
    } else {
      frame_size = (table * 144000) / (sample_rate << lsf) + padding
    }
    Ok({
      frame_size,
      error_protection,
      layer,
      sample_rate,
      sample_rate_index,
      bit_rate,
      nb_channels,
      mode,
      mode_ext,
      lsf,
      free_format: false,
    })
  } else {
    Ok({
      frame_size: 0,
      error_protection,
      layer,
      sample_rate,
      sample_rate_index,
      bit_rate: 0,
      nb_channels,
      mode,
      mode_ext,
      lsf,
      free_format: true,
    })
  }
}

///| `MPAStreamInfo`: the information `ff_mpa_decode_header` returns through
/// its pointer arguments. `samples_per_frame` is the C's `*frame_size` (which
/// is the number of PCM samples, not bytes). */
pub struct MpaStreamInfo {
  codec : String
  sample_rate : Int
  channels : Int
  samples_per_frame : Int
  bit_rate : Int
}

///| `ff_mpa_decode_header`. */
pub fn ff_mpa_decode_header(header : UInt) -> Result[MpaStreamInfo, String] {
  let h = match avpriv_mpegaudio_decode_header(header) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let (codec, samples_per_frame) = if h.layer == 1 {
    ("mp1", 384)
  } else if h.layer == 2 {
    ("mp2", 1152)
  } else if h.lsf != 0 {
    ("mp3", 576)
  } else {
    ("mp3", 1152)
  }
  Ok({
    codec,
    sample_rate: h.sample_rate,
    channels: h.nb_channels,
    samples_per_frame,
    bit_rate: h.bit_rate,
  })
}

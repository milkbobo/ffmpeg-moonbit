///|
/// Codec extradata extraction for the MP4/MOV demuxer, ported from FFmpeg
/// 9.0.2 `libavformat/mov.c` (`mov_read_glbl`) and `libavformat/isom.c` +
/// `libavformat/mov_esds.c` (`ff_mov_read_esds`, `ff_mp4_read_descr*`,
/// `ff_mp4_read_dec_config_descr`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope notes:
///   * `avcC`/`hvcC`/`av1C`/`glbl`/`vvcC`/`evcC`/`lvcC`/`apvC` all funnel
///     through `mov_read_glbl`: the payload becomes the extradata verbatim
///     (the codec-specific records are decoded by libavcodec, not here).
///   * `esds` walks the MPEG-4 descriptor chain down to the
///     DecoderSpecificInfo, which becomes the extradata; for AAC tracks the
///     AudioSpecificConfig is parsed (`mpeg4audio.mbt` plus LC PCE in `aac_config.mbt`)
///     to fill channels / sample rate / frame length, and the codec-id may
///     be refined to `mp3on4` / `mp4als`.
///   * the `dvc1`/`dvvC`/`dvh1`-style mov_read_extradata boxes (which store
///     the whole atom and gate on a codec id) are not ported.
///
/// `st->codecpar->codec_id` is modelled as the FFmpeg codec-id *name*
/// (`"aac"`, `"mp3"`, ...) via a string subset of `ff_mp4_obj_type`.

///|
/// `MP4ESDescrTag`. */
let mp4_es_descr_tag : Int32 = 0x03

///|
/// `MP4DecConfigDescrTag`. */
let mp4_dec_config_descr_tag : Int32 = 0x04

///|
/// `MP4DecSpecificDescrTag`. */
let mp4_dec_specific_descr_tag : Int32 = 0x05

///|
/// `ff_mp4_obj_type` from isom.c: object type id to FFmpeg codec-id name.
/// First match wins, as with `ff_codec_get_id` (so 0x40 is AAC, not ALS).
fn mp4_obj_type_codec(object_type_id : Int32) -> String? {
  match object_type_id {
    0x08 => Some("mov_text")
    0x20 => Some("mpeg4")
    0x21 => Some("h264")
    0x23 => Some("hevc")
    0x33 => Some("vvc")
    0x40 => Some("aac")
    0x60 | 0x61 | 0x62 | 0x63 | 0x64 | 0x65 => Some("mpeg2video")
    0x66 | 0x67 | 0x68 => Some("aac")
    0x69 => Some("mp3")
    0x6A => Some("mpeg1video")
    0x6B => Some("mp3")
    0x6C => Some("mjpeg")
    0x6D => Some("png")
    0x6E => Some("jpeg2000")
    0xA3 => Some("vc1")
    0xA4 => Some("dirac")
    0xA5 => Some("ac3")
    0xA6 => Some("eac3")
    0xA9 => Some("dts")
    0xAD => Some("opus")
    0xB1 => Some("vp9")
    0xD0 => Some("tscc2")
    0xD1 => Some("evrc")
    0xDD => Some("vorbis")
    0xE0 => Some("dvd_subtitle")
    0xE1 => Some("qcelp")
    0x01 | 0x02 => Some("mpeg4systems")
    _ => None
  }
}

///|
/// `mp4_audio_types` from isom.c: AudioSpecificConfig object types that
/// override the AAC codec id.
fn mp4_audio_type_codec(object_type : Int32) -> String? {
  match object_type {
    29 | 32 | 33 | 34 => Some("mp3on4") // AOT_PS (old mp3on4 draft) / Layer 1-3
    36 => Some("mp4als") // AOT_ALS
    _ => None
  }
}

///|
/// `ff_mpa_freq_tab` from libavcodec/mpegaudiotabs.h. */
let mpa_freq_tab : FixedArray[Int32] = [44100, 48000, 32000]

///|
/// `mov_read_dops`: convert an OpusSpecificBox into an `OpusHead`-shaped
/// extradata block (magic + version 1 + payload with little-endian pre-skip,
/// input sample rate and output gain), exactly like the C demuxer.
fn parse_dops(st : MovState, r : AvioContext, size : Int64) -> Unit {
  if !st.in_trak || size < 11 || size > 1073741824 {
    let _ = r.avio_skip(size)
    return
  }
  let has_extra = match st.cur.extradata {
    Some(b) => b.length() > 0
    None => false
  }
  if has_extra {
    let _ = r.avio_skip(size)
    return
  }
  let version = r.avio_r8()
  if version != 0 {
    let _ = r.avio_skip(size - 1L)
    return
  }
  let out : Array[Byte] = [
    b'O', b'p', b'u', b's', b'H', b'e', b'a', b'd', b'\x01',
  ]
  for _ in 1..<size.to_int() {
    out.push(r.avio_r8().to_byte())
  }
  // OpusSpecificBox is big-endian; OpusHead is little-endian.
  let pre_skip = (out[10].to_int() << 8) | out[11].to_int()
  out[10] = (pre_skip & 0xFF).to_byte()
  out[11] = ((pre_skip >> 8) & 0xFF).to_byte()
  let rate = (out[12].to_int() << 24) |
    (out[13].to_int() << 16) |
    (out[14].to_int() << 8) |
    out[15].to_int()
  out[12] = (rate & 0xFF).to_byte()
  out[13] = ((rate >> 8) & 0xFF).to_byte()
  out[14] = ((rate >> 16) & 0xFF).to_byte()
  out[15] = ((rate >> 24) & 0xFF).to_byte()
  let gain = (out[16].to_int() << 8) | out[17].to_int()
  out[16] = (gain & 0xFF).to_byte()
  out[17] = ((gain >> 8) & 0xFF).to_byte()
  st.cur.extradata = Some(Bytes::from_array(out[:]))
}

///|
/// `mov_read_glbl`: store the payload as the track's extradata. The
/// legacy-broken `fiel`-wrapped variant is ported too (recursing into the
/// payload as child boxes).
fn parse_glbl(
  st : MovState,
  r : AvioContext,
  kind : String,
  size : Int64,
) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  if size > 1073741824 {
    raise InvalidData("glbl too large")
  }
  let mut size = size
  if kind == "vvcC" {
    let _ = r.avio_skip(4L)
    size = size - 4L
  }
  if size >= 10 {
    // Broken files created by legacy versions of libavformat wrap a whole
    // `fiel` atom inside a `glbl` atom.
    let start = r.avio_tell()
    let inner_size = r.avio_rb32()
    let b0 = r.avio_r8()
    let b1 = r.avio_r8()
    let b2 = r.avio_r8()
    let b3 = r.avio_r8()
    if r.avio_feof() {
      raise InvalidData("EOF in glbl")
    }
    let _ = r.avio_seek(start, SEEK_SET)
    if b0 == 0x66 &&
      b1 == 0x69 &&
      b2 == 0x65 &&
      b3 == 0x6C &&
      inner_size.to_int64() == size {
      // 'fiel' with a matching size: recurse into the wrapped boxes.
      parse_default(st, r, size)
      return
    }
  }
  // `extradata_size > 1`: ignore a second box unless the first one was a
  // degenerate 0/1-byte extradata.
  let overwrite = match st.cur.extradata {
    Some(d) => d.length() <= 1
    None => true
  }
  if overwrite {
    let bytes : Array[Byte] = []
    for i = 0; i < size.to_int(); i = i + 1 {
      bytes.push(r.avio_r8().to_byte())
    }
    st.cur.extradata = Some(Bytes::from_array(bytes[:]))
  }
}

///|
/// `ff_mp4_read_descr_len`: up to four 7-bit length bytes. */
fn mp4_read_descr_len(r : AvioContext) -> Int32 {
  let mut len = 0
  let mut count = 4
  while count > 0 {
    let c = r.avio_r8().reinterpret_as_int()
    len = (len << 7) | (c & 0x7F)
    if (c & 0x80) == 0 {
      break
    }
    count = count - 1
  }
  len
}

///|
/// `ff_mp4_read_descr`: tag byte plus length. */
fn mp4_read_descr(r : AvioContext) -> (Int32, Int32) {
  let tag = r.avio_r8().reinterpret_as_int()
  (tag, mp4_read_descr_len(r))
}

///|
/// `ff_mp4_parse_es_descr`: ES_ID, flags and the optional URL/OCR fields. */
fn mp4_parse_es_descr(r : AvioContext) -> Unit {
  let _ = r.avio_rb16() // ES_ID
  let flags = r.avio_r8()
  if (flags & 0x80) != 0 {
    // streamDependenceFlag
    let _ = r.avio_rb16()
  }
  if (flags & 0x40) != 0 {
    // URL_Flag
    let len = r.avio_r8().reinterpret_as_int()
    let _ = r.avio_skip(len.to_int64())
  }
  if (flags & 0x20) != 0 {
    // OCRstreamFlag
    let _ = r.avio_rb16()
  }
}

///|
/// `ff_mp4_read_dec_config_descr`: object type, bit rate and the
/// DecoderSpecificInfo extradata; for AAC the AudioSpecificConfig is parsed
/// to refine channels / sample rate / frame length / codec id.
fn mp4_read_dec_config_descr(
  st : MovState,
  r : AvioContext,
) -> Unit raise MovError {
  let object_type_id = r.avio_r8().reinterpret_as_int()
  let _ = r.avio_r8() // stream type
  let _ = r.avio_rb24() // buffer size db
  let _ = r.avio_rb32() // max bitrate
  st.cur.bit_rate = r.avio_rb32() // avg bitrate
  match mp4_obj_type_codec(object_type_id) {
    Some(id) => st.cur.codec_id = id
    None => ()
  }
  let (tag, len) = mp4_read_descr(r)
  if tag == mp4_dec_specific_descr_tag {
    // No decSpecificInfo is defined for MPEG-1/2 Audio.
    if object_type_id == 0x69 || object_type_id == 0x6B {
      return
    }
    if len <= 0 || len > 1073741824 {
      raise InvalidData("invalid dec specific info length")
    }
    let bytes : Array[Byte] = []
    for i = 0; i < len; i = i + 1 {
      bytes.push(r.avio_r8().to_byte())
    }
    st.cur.extradata = Some(Bytes::from_array(bytes[:]))
    if st.cur.codec_id == "aac" {
      let mut cfg = @libavcodec.new_mpeg4_audio_config()
      match
        @libavcodec.ff_mpeg4audio_get_config(
          cfg,
          st.cur.extradata.unwrap(),
          true,
        ) {
        Err(_) => raise InvalidData("invalid audio specific config")
        Ok(_) => ()
      }
      if cfg.object_type == 2 && cfg.chan_config == 0 {
        match
          @libavcodec.aac_parse_audio_specific_config(st.cur.extradata.unwrap()) {
          Ok(parsed) => cfg = parsed.config
          Err(_) =>
            raise InvalidData("invalid AAC PCE in audio specific config")
        }
      }
      if cfg.channels != st.cur.channels.reinterpret_as_int() {
        st.cur.channels = cfg.channels.reinterpret_as_uint()
      }
      // Old mp3on4 carries an MPEG layer sampling index; otherwise the
      // extension (SBR) rate wins when present.
      if cfg.object_type == 29 && cfg.sampling_index < 3 {
        // AOT_PS with a low sampling index
        st.cur.sample_rate = mpa_freq_tab[cfg.sampling_index].reinterpret_as_uint()
      } else if cfg.ext_sample_rate != 0 {
        st.cur.sample_rate = cfg.ext_sample_rate.reinterpret_as_uint()
      } else {
        st.cur.sample_rate = cfg.sample_rate.reinterpret_as_uint()
      }
      match cfg.object_type {
        1 | 2 | 3 | 4 | 17 | 23 | 39 | 42 =>
          // AAC object types with a defined frame length
          st.cur.frame_length = cfg.frame_length
        _ => ()
      }
      match mp4_audio_type_codec(cfg.object_type) {
        Some(id) => st.cur.codec_id = id
        None => st.cur.codec_id = "aac"
      }
    }
  }
}

///|
/// `ff_mov_read_esds` (mov_esds.c): version/flags, ES descriptor, then the
/// DecoderConfigDescriptor.
fn parse_esds(st : MovState, r : AvioContext) -> Unit raise MovError {
  if !st.in_trak {
    return
  }
  let _ = r.avio_rb32() // version + flags
  let (tag, _len) = mp4_read_descr(r)
  if tag == mp4_es_descr_tag {
    mp4_parse_es_descr(r)
  } else {
    let _ = r.avio_rb16() // ID
  }
  let (tag2, _len2) = mp4_read_descr(r)
  if tag2 == mp4_dec_config_descr_tag {
    mp4_read_dec_config_descr(st, r)
  }
}

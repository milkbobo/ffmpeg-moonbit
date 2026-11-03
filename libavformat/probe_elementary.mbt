///|
/// `read_probe` callbacks for the elementary / raw demuxers this port
/// implements: `adts_aac_probe` (aacdec.c), `ac3_eac3_probe` (ac3dec.c),
/// `aiff_probe` (aiffdec.c), `amr_probe` (amr.c), `png_probe` (img2dec.c),
/// `asf_probe` (asfdec_f.c), `au_probe` (au.c), `probe` (cafdec.c),
/// `flac_probe` / `raw_flac_probe` (flacdec.c), `mjpeg_probe` (rawdec.c),
/// `mp3_read_probe` (mp3dec.c) and `ogg_probe` (oggdec.c).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// ADTS AAC (aacdec.c: adts_aac_probe)
// ---------------------------------------------------------------------------

///|
/// `adts_aac_probe`: count consecutive ADTS headers from every candidate
/// start, keeping the best run. Anything that does not chain from the buffer
/// start is scored only by the longest run found anywhere.
fn probe_adts_aac(pd : ProbeData) -> Int {
  let buf = pd.buf
  let end = buf.length() - 7
  let mut max_frames = 0
  let mut first_frames = 0
  let mut pos = 0
  while pos < end {
    let mut buf2 = pos
    let mut frames = 0
    while buf2 < end {
      let header = pb_be16(buf, buf2)
      if (header & 0xFFF6_U) != 0xFFF0_U {
        if pos != 0 {
          // Not an ADTS header away from the start: discard this run.
          frames = 0
        }
        break
      }
      let mut fsize = ((pb_be32(buf, buf2 + 3) >> 13) & 0x1FFF_U).reinterpret_as_int()
      if fsize < 7 {
        break
      }
      fsize = imin(fsize, end - buf2)
      frames = frames + 1
      buf2 = buf2 + fsize
    }
    max_frames = imax(max_frames, frames)
    if pos == 0 {
      first_frames = frames
    }
    pos = buf2 + 1
  }
  if first_frames >= 3 {
    probe_score_extension + 1
  } else if max_frames > 100 {
    probe_score_extension
  } else if max_frames >= 3 {
    probe_score_extension / 2
  } else if first_frames >= 1 {
    1
  } else {
    0
  }
}

// ---------------------------------------------------------------------------
// AC-3 / E-AC-3 (ac3dec.c: ac3_eac3_probe)
// ---------------------------------------------------------------------------

///|
/// `ac3_eac3_probe`: walk AC-3 sync words, validating each frame header and
/// its AV_CRC_16_ANSI trailer (MSB-first, poly 0x8005). `bitstream_id > 10` marks the stream as E-AC-3, so
/// the AC-3 and E-AC-3 demuxers score the same bytes differently.
fn probe_ac3_eac3(pd : ProbeData, expect_eac3 : Bool) -> Int {
  let buf = pd.buf
  let end = buf.length()
  let crc_ctx = match @libavutil.av_crc_init(false, 16, 0x8005) {
    Ok(ctx) => ctx
    Err(_) => []
  }
  let mut max_frames = 0
  let mut first_frames = 0
  let mut is_eac3 = false
  let mut pos = 0
  while pos < end {
    let b0 = pb_u8(buf, pos).reinterpret_as_int()
    let b1 = pb_u8(buf, pos + 1).reinterpret_as_int()
    let sync_plain = b0 == 0x0B && b1 == 0x77
    let sync_swapped = b0 == 0x77 && b1 == 0x0B
    // The C only requires a sync word once past the first byte; position 0 is
    // always attempted (the file may start mid-header).
    if pos > 0 && !sync_plain && !sync_swapped {
      pos = pos + 1
      continue
    }
    let mut buf2 = pos
    let mut frames = 0
    while buf2 < end {
      if pb_u8(buf, buf2) == 0x01_U && pb_u8(buf, buf2 + 1) == 0x10_U {
        if buf2 + 16 > end {
          break
        }
        buf2 = buf2 + 16
      }
      // 0x772B streams are 16-bit byte-swapped: the header and the CRC are
      // both computed over the swapped copy, as the C does.
      let header_bytes = if sync_swapped {
        let swapped : Array[Byte] = []
        for k in 0..<8 {
          if k % 2 == 0 {
            swapped.push(pb_byte(buf, buf2 + k + 1))
          } else {
            swapped.push(pb_byte(buf, buf2 + k))
          }
        }
        Bytes::from_array(swapped[:])
      } else {
        // The C passes the rest of the window (`end - buf2`); the header only
        // needs the first bytes, so cap the copy to keep probing linear.
        buf[buf2:imin(buf2 + 64, end)].to_owned()
      }
      let header = match @libavcodec.ac3_parse_header(header_bytes) {
        Ok(h) => h
        Err(_) => break
      }
      let frame_size = header.frame_size
      if frame_size <= 0 || buf2 + frame_size > end {
        break
      }
      let crc_body = if sync_swapped {
        let swapped : Array[Byte] = []
        if frame_size < 8 {
          break
        }
        for k in 0..<frame_size {
          if k % 2 == 0 {
            swapped.push(pb_byte(buf, buf2 + k + 1))
          } else {
            swapped.push(pb_byte(buf, buf2 + k))
          }
        }
        Bytes::from_array(swapped[2:])
      } else {
        buf[buf2 + 2:buf2 + frame_size].to_owned()
      }
      if @libavutil.av_crc(crc_ctx, 0U, crc_body) != 0U {
        break
      }
      if header.bitstream_id > 10 {
        is_eac3 = true
      }
      frames = frames + 1
      buf2 = buf2 + frame_size
    }
    max_frames = imax(max_frames, frames)
    if pos == 0 {
      first_frames = frames
    }
    pos = pos + 1
  }
  if is_eac3 != expect_eac3 {
    return 0
  }
  if first_frames >= 7 {
    probe_score_extension + 2
  } else if max_frames > 200 {
    probe_score_extension
  } else if max_frames >= 4 {
    probe_score_extension / 2
  } else if max_frames >= 1 {
    1
  } else {
    0
  }
}

///|
/// `ac3_probe`. */
fn probe_ac3(pd : ProbeData) -> Int {
  probe_ac3_eac3(pd, false)
}

///|
/// `eac3_probe`. */
fn probe_eac3(pd : ProbeData) -> Int {
  probe_ac3_eac3(pd, true)
}

// ---------------------------------------------------------------------------
// AIFF / AU / CAF / ASF / AMR
// ---------------------------------------------------------------------------

///|
/// `aiff_probe`: `FORM` + size ≥ 4 + `AIFF` or `AIFC`. */
fn probe_aiff(pd : ProbeData) -> Int {
  let buf = pd.buf
  if pb_match(buf, 0, "FORM") &&
    pb_be32(buf, 4) >= 4U &&
    pb_u8(buf, 8) == 0x41_U &&
    pb_u8(buf, 9) == 0x49_U &&
    pb_u8(buf, 10) == 0x46_U &&
    (pb_u8(buf, 11) == 0x46_U || pb_u8(buf, 11) == 0x43_U) {
    probe_score_max
  } else {
    0
  }
}

///|
/// `au_probe`: `.snd` magic plus five non-zero u32 header fields (data offset,
/// data size, encoding, sample rate, channels) so a stray `.snd` in payload
/// does not match. */
fn probe_au(pd : ProbeData) -> Int {
  let buf = pd.buf
  if buf.length() < 24 ||
    pb_le32(buf, 0) != 0x64_6E_73_2EU ||
    pb_be32(buf, 4) == 0U ||
    pb_be32(buf, 8) == 0U ||
    pb_be32(buf, 12) == 0U ||
    pb_be32(buf, 16) == 0U ||
    pb_be32(buf, 20) == 0U {
    return 0
  }
  probe_score_max
}

///|
/// `probe` in cafdec.c: `caff` v1 with a 32-byte `desc` chunk. */
fn probe_caf(pd : ProbeData) -> Int {
  let buf = pd.buf
  if pb_be32(buf, 0) != 0x63_61_66_66U {
    return 0
  }
  if pb_be16(buf, 4) != 1U {
    return 0
  }
  if pb_be32(buf, 8) != 0x64_65_73_63U {
    return 0
  }
  if pb_be64(buf, 12) != 32UL {
    return 0
  }
  probe_score_max
}

///|
/// `asf_probe`: the ASF header GUID. */
fn probe_asf(pd : ProbeData) -> Int {
  let buf = pd.buf
  let guid : Array[Int] = [
    0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00,
    0x62, 0xCE, 0x6C,
  ]
  for i in 0..<16 {
    if pb_u8(buf, i).reinterpret_as_int() != guid[i] {
      return 0
    }
  }
  probe_score_max
}

///|
/// `amr_probe`: `#!AMR` (covers AMR-NB, AMR-WB and the multichannel headers). */
fn probe_amr(pd : ProbeData) -> Int {
  if pb_prefix(pd.buf, "#!AMR") {
    probe_score_max
  } else {
    0
  }
}

// ---------------------------------------------------------------------------
// PNG / MJPEG
// ---------------------------------------------------------------------------

///|
/// `png_probe`: the 8-byte PNG signature. */
fn probe_png(pd : ProbeData) -> Int {
  if pb_be64(pd.buf, 0) == 0x89_50_4E_47_0D_0A_1A_0AUL {
    probe_score_max - 1
  } else {
    0
  }
}

///|
/// `mjpeg_probe`: walk JPEG markers and count well-formed
/// SOI→SOF→SOS→EOI sequences, penalising markers that appear out of order.
fn probe_mjpeg(pd : ProbeData) -> Int {
  let buf = pd.buf
  let n = buf.length()
  let mut state = -1
  let mut nb_invalid = 0
  let mut nb_frames = 0
  let mut i = 0
  while i < n - 1 {
    if pb_u8(buf, i) == 0xFFU {
      let c = pb_u8(buf, i + 1).reinterpret_as_int()
      if c == 0xD8 {
        state = 0xD8
      } else if c == 0xC0 ||
        c == 0xC1 ||
        c == 0xC2 ||
        c == 0xC3 ||
        c == 0xC5 ||
        c == 0xC6 ||
        c == 0xC7 ||
        c == 0xF7 {
        if state == 0xD8 {
          state = 0xC0
        } else {
          nb_invalid = nb_invalid + 1
        }
      } else if c == 0xDA {
        if state == 0xC0 {
          state = 0xDA
        } else {
          nb_invalid = nb_invalid + 1
        }
      } else if c == 0xD9 {
        if state == 0xDA {
          state = 0xD9
          nb_frames = nb_frames + 1
        } else {
          nb_invalid = nb_invalid + 1
        }
      } else if (c >= 0x02 && c <= 0xBF) || c == 0xC8 {
        nb_invalid = nb_invalid + 1
      }
    }
    i = i + 1
  }
  if nb_invalid * 4 + 1 < nb_frames {
    let ct = "\r\nContent-Type: image/jpeg\r\n"
    let lim = imin(n - (ct.length() + 1), 100)
    for k in 0..<lim {
      if pb_match(buf, k, ct) {
        return probe_score_extension
      }
    }
    if nb_invalid == 0 && nb_frames > 2 {
      return probe_score_extension / 2
    }
    return probe_score_extension / 4
  }
  if nb_invalid == 0 && nb_frames > 0 {
    return probe_score_extension / 4
  }
  0
}

// ---------------------------------------------------------------------------
// FLAC (flacdec.c: raw_flac_probe + flac_probe)
// ---------------------------------------------------------------------------

///|
/// `raw_flac_probe`: validate the four bytes after the 14-bit sync word. */
fn probe_raw_flac(pd : ProbeData) -> Int {
  let buf = pd.buf
  if (pb_u8(buf, 2) & 0xF0_U) == 0U {
    return 0
  }
  if (pb_u8(buf, 2) & 0x0F_U) == 0x0F_U {
    return 0
  }
  // `(FLAC_MAX_CHANNELS + FLAC_CHMODE_MID_SIDE) << 4` == 11 << 4.
  if (pb_u8(buf, 3) & 0xF0_U) >= 176U {
    return 0
  }
  if (pb_u8(buf, 3) & 0x06_U) == 0x06_U {
    return 0
  }
  if (pb_u8(buf, 3) & 0x01_U) == 0x01_U {
    return 0
  }
  probe_score_extension / 4 + 1
}

///|
/// `flac_probe`: either a raw FLAC frame header, or `fLaC` with a valid
/// STREAMINFO metadata block. */
fn probe_flac(pd : ProbeData) -> Int {
  let buf = pd.buf
  if (pb_be16(buf, 0) & 0xFFFE_U) == 0xFFF8_U {
    return probe_raw_flac(pd)
  }
  if buf.length() >= 4 + 4 + 13 {
    let ty = pb_u8(buf, 4).reinterpret_as_int() & 0x7F
    let size = pb_be24(buf, 5).reinterpret_as_int()
    let min_block_size = pb_be16(buf, 8).reinterpret_as_int()
    let max_block_size = pb_be16(buf, 10).reinterpret_as_int()
    let sample_rate = (pb_be24(buf, 18) >> 4).reinterpret_as_int()
    if !pb_prefix(buf, "fLaC") {
      return 0
    }
    if ty == 0 &&
      size == 34 &&
      min_block_size >= 16 &&
      max_block_size >= min_block_size &&
      sample_rate != 0 &&
      sample_rate <= 655350 {
      return probe_score_max
    }
    return probe_score_extension
  }
  0
}

// ---------------------------------------------------------------------------
// MP3 (mp3dec.c: mp3_read_probe)
// ---------------------------------------------------------------------------

///|
/// `MP3_MASK` (`mpegaudiodecheader.h`). */
let mp3_mask : UInt = 0xFFFE0CCFU

///|
/// `mp3_read_probe`: chain MPEG audio frames from every candidate start and
/// reject runs whose payload contains the same header signature more than
/// twice (an embedded-header false positive).
fn probe_mp3(pd : ProbeData) -> Int {
  let buf = pd.buf
  let end = buf.length() - 4
  let mut start = 0
  while start < end && pb_u8(buf, start) == 0U {
    start = start + 1
  }
  let mut max_frames = 0
  let mut first_frames = 0
  let mut max_framesizes = 0
  let mut whole_used = false
  let mut pos = start
  while pos < end {
    let mut buf2 = pos
    let mut frames = 0
    let mut framesizes = 0
    while buf2 < end {
      let header = pb_be32(buf, buf2)
      let h = match @libavcodec.avpriv_mpegaudio_decode_header(header) {
        Ok(h) => h
        Err(_) => break
      }
      // `avpriv_mpegaudio_decode_header` returns 1 for a free-format frame;
      // the C probe treats any non-zero return as "stop", and a zero
      // `frame_size` would otherwise never advance `buf2`.
      if h.free_format || h.frame_size <= 0 {
        break
      }
      let available = imin(h.frame_size, end - buf2)
      let mut header_emu = 0
      for k in (buf2 + 4)..<(buf2 + available) {
        let next_sync = pb_be32(buf, k)
        if (next_sync & mp3_mask) == (header & mp3_mask) {
          header_emu = header_emu + 1
        }
      }
      if header_emu > 2 {
        break
      }
      framesizes = framesizes + h.frame_size
      frames = frames + 1
      if available < h.frame_size {
        buf2 = buf2 + available
        break
      }
      buf2 = buf2 + h.frame_size
    }
    max_frames = imax(max_frames, frames)
    max_framesizes = imax(max_framesizes, framesizes)
    if pos == start {
      first_frames = frames
      if buf2 == end + 4 {
        whole_used = true
      }
    }
    pos = buf2 + 1
  }
  if first_frames >= 7 {
    probe_score_extension + 2
  } else if max_frames > 200 && buf.length() < 2 * max_framesizes {
    probe_score_extension
  } else if max_frames >= 4 && buf.length() < 2 * max_framesizes {
    probe_score_extension / 2
  } else if probe_id3v2_match_at(buf, 0) &&
    (2 * probe_id3v2_tag_len_at(buf, 0)) >= buf.length() {
    if buf.length() < probe_buf_max {
      probe_score_extension / 4
    } else {
      probe_score_extension - 2
    }
  } else if first_frames > 1 && whole_used {
    5
  } else if max_frames >= 1 && buf.length() < 10 * max_framesizes {
    1
  } else {
    0
  }
}

// ---------------------------------------------------------------------------
// Ogg (oggdec.c: ogg_probe)
// ---------------------------------------------------------------------------

///|
/// `ogg_probe`: `"OggS"` including its NUL terminator (a five-byte compare in
/// C) plus a version byte of at most 7. */
fn probe_ogg(pd : ProbeData) -> Int {
  let buf = pd.buf
  if pb_match(buf, 0, "OggS") && pb_u8(buf, 4) == 0U && pb_u8(buf, 5) <= 7U {
    probe_score_max
  } else {
    0
  }
}

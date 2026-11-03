///|
/// `read_probe` callbacks for the container demuxers this port implements:
/// `mov_probe` (mov.c), `matroska_probe` (matroskadec.c), `mpegts_probe` +
/// `analyze` (mpegts.c), `wav_probe` / `w64_probe` (wavdec.c), `hls_probe`
/// (hls.c) and `dash_probe` (dashdec.c).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// MP4 / MOV (mov.c: mov_probe)
// ---------------------------------------------------------------------------

///|
/// `mov_probe`: walk the top-level box chain in the probe window and score the
/// tags `mov_read_header` would also accept. A `moov` header additionally gets
/// checked for a `mhlr`/`MPEG` handler, which means this is a MOV-packed
/// MPEG-PS and must be probed again with a larger window (score 5).
fn probe_mov(pd : ProbeData) -> Int {
  let buf = pd.buf
  let buf_size = buf.length()
  let mut offset = 0L
  let mut score = 0
  let mut moov_offset = -1L
  while true {
    let mut minsize = 8L
    if offset + 8L > buf_size.to_int64() {
      break
    }
    let off = offset.to_int()
    let mut size = pb_be32(buf, off).to_int64()
    if size == 1L && offset + 16L <= buf_size.to_int64() {
      size = pb_be64(buf, off + 8).reinterpret_as_int64()
      minsize = 16L
    } else if size == 0L {
      size = buf_size.to_int64() - offset
    }
    if size < minsize {
      offset = offset + 4L
      continue
    }
    let tag_off = off + 4
    if pb_match(buf, tag_off, "moov") {
      moov_offset = offset + 4L
      score = imax(score, probe_score_max)
    } else if pb_match(buf, tag_off, "mdat") ||
      pb_match(buf, tag_off, "pnot") ||
      pb_match(buf, tag_off, "udta") ||
      pb_match(buf, tag_off, "ftyp") {
      // `ftyp` with a JPEG-2000 brand only rates 5; everything else is a
      // confident container hit.
      if pb_match(buf, tag_off, "ftyp") &&
        (pb_le32(buf, off + 8) == 0x20_32_70_6AU ||
          pb_le32(buf, off + 8) == 0x20_78_70_6AU ||
          pb_le32(buf, off + 8) == 0x20_6C_78_6AU) {
        score = imax(score, 5)
      } else {
        score = imax(score, probe_score_max)
      }
    } else if pb_match(buf, tag_off, "ediw") ||
      pb_match(buf, tag_off, "wide") ||
      pb_match(buf, tag_off, "free") ||
      pb_match(buf, tag_off, "junk") ||
      pb_match(buf, tag_off, "pict") {
      score = imax(score, probe_score_max - 5)
    } else if pb_le32(buf, tag_off) == 0x7D_7F_82_82U {
      score = imax(score, probe_score_extension - 5)
    } else if pb_match(buf, tag_off, "skip") ||
      pb_match(buf, tag_off, "uuid") ||
      pb_match(buf, tag_off, "prfl") {
      score = imax(score, probe_score_extension)
    }
    if size > 9223372036854775807L - offset {
      break
    }
    offset = offset + size
  }
  if score > probe_score_max - 50 && moov_offset != -1L {
    // A moov in the header might be a MOV-packed MPEG-PS; look for a
    // `hdlr`/`mhlr`/`MPEG` triple and drop the score so the caller grows the
    // probe window.
    let mut p = moov_offset.to_int()
    while p < buf_size - 16 {
      if pb_match(buf, p, "hdlr") &&
        pb_match(buf, p + 8, "mhlr") &&
        pb_match(buf, p + 12, "MPEG") {
        return 5
      }
      p = p + 2
    }
  }
  score
}

// ---------------------------------------------------------------------------
// Matroska / WebM (matroskadec.c: matroska_probe)
// ---------------------------------------------------------------------------

///|
/// `EBML_ID_HEADER` (`0x1A45DFA3`), as a local name to avoid clashing with
/// `ebml.mbt`'s constant. */
let probe_ebml_id_header : UInt = 0x1A45DFA3U

///|
/// `matroska_probe`: validate the EBML header, then look for a known DocType
/// inside it. A valid EBML header without `matroska`/`webm` still rates 50.
fn probe_matroska(pd : ProbeData) -> Int {
  let buf = pd.buf
  let buf_size = buf.length()
  if pb_be32(buf, 0) != probe_ebml_id_header {
    return 0
  }
  let mut len_mask = 0x80
  let mut size = 1
  let mut total = pb_u8(buf, 4).to_uint64()
  while size <= 8 && (total & len_mask.to_uint64()) == 0UL {
    size = size + 1
    len_mask = len_mask >> 1
  }
  if size > 8 {
    return 0
  }
  total = total & (len_mask.to_uint64() - 1UL)
  let mut n = 1
  while n < size {
    total = (total << 8) | pb_u8(buf, 4 + n).to_uint64()
    n = n + 1
  }
  let unknown = total + 1UL == 1UL << (7 * size)
  if unknown {
    total = (buf_size - 4 - size).to_uint64()
  } else if buf_size.to_int64() < 4L + size.to_int64() + total.reinterpret_as_int64() {
    return 0
  }
  let doctypes : Array[String] = ["matroska", "webm"]
  for doctype in doctypes {
    let probelen = doctype.length()
    if total < probelen.to_uint64() {
      continue
    }
    let last = 4 + size + (total.to_int() - probelen)
    for start in (4 + size)..=last {
      if pb_match(buf, start, doctype) {
        return probe_score_max
      }
    }
  }
  // Valid EBML header but no recognised DocType.
  probe_score_extension
}

// ---------------------------------------------------------------------------
// MPEG-TS (mpegts.c: analyze + mpegts_probe)
// ---------------------------------------------------------------------------

///|
/// `TS_PACKET_SIZE` / `TS_DVHS_PACKET_SIZE` / `TS_FEC_PACKET_SIZE`. */
let ts_packet_size : Int = 188
let ts_dvhs_packet_size : Int = 192
let ts_fec_packet_size : Int = 204

///|
/// `analyze`: histogram the byte offsets of sync bytes inside a window of
/// whole packets. `best_score` counts how often the most common offset repeats,
/// penalised by sync bytes that land on other offsets.
fn probe_ts_analyze(
  buf : Bytes,
  base : Int,
  size : Int,
  packet_size : Int,
  probe : Bool,
) -> Int {
  let stat : Array[Int] = Array::make(packet_size, 0)
  let mut stat_all = 0
  let mut best_score = 0
  let mut i = 0
  while i < size - 3 {
    if pb_u8(buf, base + i) == 0x47U {
      let pid = pb_be16(buf, base + i + 1) & 0x1FFF_U
      let asc = pb_u8(buf, base + i + 3) & 0x30_U
      if !probe || pid == 0x1FFF_U || asc != 0U {
        let x = i % packet_size
        stat[x] = stat[x] + 1
        stat_all = stat_all + 1
        if stat[x] > best_score {
          best_score = stat[x]
        }
      }
    }
    i = i + 1
  }
  best_score - imax(stat_all - 10 * best_score, 0) / 10
}

///|
/// `mpegts_probe`: score 188/192/204-byte layouts over up to ten 204-byte
/// blocks, then combine the per-block sum and maximum as the C does. */
fn probe_mpegts(pd : ProbeData) -> Int {
  let buf = pd.buf
  let size = buf.length()
  let check_count = size / ts_fec_packet_size
  if check_count == 0 {
    return 0
  }
  let check_count_block = 10
  let check_block = 100
  let mut maxscore = 0
  let mut sumscore = 0
  let mut i = 0
  while i < check_count {
    let left = imin(check_count - i, check_block)
    let score = probe_ts_analyze(
      buf,
      ts_packet_size * i,
      ts_packet_size * left,
      ts_packet_size,
      true,
    )
    let dvhs_score = probe_ts_analyze(
      buf,
      ts_dvhs_packet_size * i,
      ts_dvhs_packet_size * left,
      ts_dvhs_packet_size,
      true,
    )
    let fec_score = probe_ts_analyze(
      buf,
      ts_fec_packet_size * i,
      ts_fec_packet_size * left,
      ts_fec_packet_size,
      true,
    )
    let best = imax(imax(score, dvhs_score), fec_score)
    sumscore = sumscore + best
    maxscore = imax(maxscore, best)
    i = i + check_block
  }
  sumscore = sumscore * check_count_block / check_count
  maxscore = maxscore * check_count_block / check_block
  if check_count > check_count_block && sumscore > 6 {
    probe_score_max + sumscore - check_count_block
  } else if check_count >= check_count_block && sumscore >= check_count_block {
    probe_score_max + sumscore - check_count_block
  } else if check_count >= check_count_block && sumscore > 6 {
    probe_score_max / 2 + sumscore - check_count_block
  } else if check_count >= check_count_block && maxscore > 6 {
    probe_score_max / 2 + sumscore - check_count_block
  } else if sumscore > 6 {
    2
  } else {
    0
  }
}

// ---------------------------------------------------------------------------
// WAV / W64 (wavdec.c: wav_probe, w64_probe)
// ---------------------------------------------------------------------------

///|
/// `wav_probe`: `RIFF`/`RIFX` + `WAVE`, or `RF64`/`BW64` + `ds64`. The
/// `AVPROBE_SCORE_MAX - 1` for plain RIFF is deliberate: the ACT demuxer
/// embeds a WAV header and must win the tie.
fn probe_wav(pd : ProbeData) -> Int {
  let buf = pd.buf
  if buf.length() <= 32 {
    return 0
  }
  if pb_match(buf, 8, "WAVE") {
    if pb_prefix(buf, "RIFF") || pb_prefix(buf, "RIFX") {
      return probe_score_max - 1
    } else if (pb_prefix(buf, "RF64") || pb_prefix(buf, "BW64")) &&
      pb_match(buf, 12, "ds64") {
      return probe_score_max
    }
  }
  0
}

///|
/// `w64_probe`: Sony Wave64 `riff` + `wave` GUIDs. */
fn probe_w64(pd : ProbeData) -> Int {
  let buf = pd.buf
  if buf.length() <= 40 {
    return 0
  }
  if pb_match(buf, 0, "riff") &&
    pb_u8(buf, 4) == 0x2E_U &&
    pb_u8(buf, 5) == 0x91_U &&
    pb_u8(buf, 6) == 0xCF_U &&
    pb_u8(buf, 7) == 0x11_U &&
    pb_u8(buf, 8) == 0xA5_U &&
    pb_u8(buf, 9) == 0xD6_U &&
    pb_u8(buf, 10) == 0x28_U &&
    pb_u8(buf, 11) == 0xDB_U &&
    pb_u8(buf, 12) == 0x04_U &&
    pb_u8(buf, 13) == 0xC1_U &&
    pb_u8(buf, 14) == 0x00_U &&
    pb_u8(buf, 15) == 0x00_U &&
    pb_match(buf, 24, "wave") &&
    pb_u8(buf, 28) == 0xF3_U &&
    pb_u8(buf, 29) == 0xAC_U &&
    pb_u8(buf, 30) == 0xD3_U &&
    pb_u8(buf, 31) == 0x11_U &&
    pb_u8(buf, 32) == 0x8C_U &&
    pb_u8(buf, 33) == 0xD1_U &&
    pb_u8(buf, 34) == 0x00_U &&
    pb_u8(buf, 35) == 0xC0_U &&
    pb_u8(buf, 36) == 0x4F_U &&
    pb_u8(buf, 37) == 0x8E_U &&
    pb_u8(buf, 38) == 0xDB_U &&
    pb_u8(buf, 39) == 0x8A_U {
    return probe_score_max
  }
  0
}

// ---------------------------------------------------------------------------
// HLS / DASH (hls.c: hls_probe, dashdec.c: dash_probe)
// ---------------------------------------------------------------------------

///|
/// `av_strcasecmp(a, b) == 0`. */
fn probe_mime_eq(a : String, b : String) -> Bool {
  @libavutil.av_strcasecmp(a, b) == 0
}

///|
/// `ff_match_url_ext`: match the extension of the URL path (everything before
/// the first '?') against a comma-separated list.
fn probe_match_url_ext(url : String, extensions : String) -> Bool {
  let n = url.length()
  let mut end = n
  for i in 0..<n {
    if url[i] == '?' {
      end = i
      break
    }
  }
  let mut ext_start = -1
  let mut i = 0
  while i < end {
    if url[i] == '.' {
      ext_start = i + 1
    }
    i = i + 1
  }
  if ext_start < 0 || ext_start >= end {
    return false
  }
  @libavutil.av_match_name(url[ext_start:end].to_owned(), extensions)
}

///|
/// `hls_probe`: `#EXTM3U` at the start plus one of the three HLS tags, and the
/// file must look like a playlist by MIME type or extension.
fn probe_hls(pd : ProbeData) -> Int {
  let buf = pd.buf
  if !pb_prefix(buf, "#EXTM3U") {
    return 0
  }
  let text = probe_ascii(buf)
  if @libavutil.av_stristr(text, "#EXT-X-STREAM-INF:") is Some(_) ||
    @libavutil.av_stristr(text, "#EXT-X-TARGETDURATION:") is Some(_) ||
    @libavutil.av_stristr(text, "#EXT-X-MEDIA-SEQUENCE:") is Some(_) {
    let mime = pd.mime_type
    let mime_ok = mime != "" &&
      (probe_mime_eq(mime, "application/vnd.apple.mpegurl") ||
        probe_mime_eq(mime, "audio/mpegurl"))
    let mime_x = mime != "" &&
      (probe_mime_eq(mime, "audio/x-mpegurl") ||
        probe_mime_eq(mime, "application/x-mpegurl"))
    if !mime_ok &&
      !mime_x &&
      !probe_match_ext(pd.filename, "m3u8,m3u") &&
      !probe_match_url_ext(pd.filename, "m3u8,m3u") {
      return 0
    }
    return probe_score_max
  }
  0
}

///|
/// `dash_probe`: an MPD root element with a recognised profile string. */
fn probe_dash(pd : ProbeData) -> Int {
  let buf = pd.buf
  if !probe_stristr(buf, "<MPD") {
    return 0
  }
  if probe_stristr(buf, "dash:profile:isoff-on-demand:2011") ||
    probe_stristr(buf, "dash:profile:isoff-live:2011") ||
    probe_stristr(buf, "dash:profile:isoff-live:2012") ||
    probe_stristr(buf, "dash:profile:isoff-main:2011") ||
    probe_stristr(buf, "3GPP:PSS:profile:DASH1") {
    return probe_score_max
  }
  if probe_stristr(buf, "dash:profile") {
    return probe_score_max
  }
  0
}

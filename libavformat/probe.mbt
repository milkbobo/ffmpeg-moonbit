///|
/// MoonBit port of the FFmpeg 9.0.2 input-format probing layer:
/// `libavformat/format.c` (`av_probe_input_format3`, `av_probe_input_buffer2`,
/// `av_match_ext`) plus the `read_probe` callbacks of every demuxer this
/// port already implements.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Design notes:
/// - FFmpeg walks a table of `AVInputFormat` and keeps the highest `read_probe`
///   score; a tie clears the result (`fmt = NULL`). The registry below keeps
///   the `libavformat/allformats.c` declaration order so ties behave the same.
/// - C code may over-read into `AVPROBE_PADDING_SIZE` zero bytes; here every
///   byte read is bounds-checked and yields 0 outside the buffer, which is
///   equivalent for the probe callbacks (they only read what they check).
/// - The demuxer set is the subset this port implements, so a format that
///   only FFmpeg knows is reported as unknown instead of mis-scored.

///|
/// `AVPROBE_SCORE_RETRY` (`avformat.h`). */
pub let probe_score_retry : Int = 25

///|
/// `AVPROBE_SCORE_EXTENSION` (`avformat.h`). */
pub let probe_score_extension : Int = 50

///|
/// `AVPROBE_SCORE_MIME_BONUS` (`avformat.h`). */
pub let probe_score_mime_bonus : Int = 30

///|
/// `AVPROBE_SCORE_MAX` (`avformat.h`). */
pub let probe_score_max : Int = 100

///|
/// `PROBE_BUF_MIN` (`internal.h`). */
pub let probe_buf_min : Int = 2048

///|
/// `PROBE_BUF_MAX` (`internal.h`). */
pub let probe_buf_max : Int = 1048576

///|
/// The input formats this port can actually open, named after FFmpeg's
/// `AVInputFormat::name` so a probe result can be compared with `ffprobe`.
pub(all) enum FormatId {
  Aac
  Ac3
  Aiff
  Amr
  Png
  Asf
  Au
  Caf
  Dash
  Eac3
  Flac
  Hls
  Matroska
  Mjpeg
  Mov
  Mp3
  MpegTs
  Ogg
  W64
  Wav
}

///|
/// `AVInputFormat::name` of the format (the string `ffprobe` prints in
/// `format_name` for a single-demuxer match). */
pub fn FormatId::name(self : FormatId) -> String {
  match self {
    Aac => "aac"
    Ac3 => "ac3"
    Aiff => "aiff"
    Amr => "amr"
    Png => "png_pipe"
    Asf => "asf"
    Au => "au"
    Caf => "caf"
    Dash => "dash"
    Eac3 => "eac3"
    Flac => "flac"
    Hls => "hls"
    Matroska => "matroska,webm"
    // `mjpeg_probe` is shared by the `mjpeg` and `jpeg_pipe` demuxers; on a
    // single JPEG file FFmpeg 9.0.2 wins with `jpeg_pipe` (verified with
    // ffprobe), so that is the name reported here.
    Mjpeg => "jpeg_pipe"
    Mov => "mov,mp4,m4a,3gp,3g2,mj2"
    Mp3 => "mp3"
    MpegTs => "mpegts"
    Ogg => "ogg"
    W64 => "w64"
    Wav => "wav"
  }
}

///|
/// `AVInputFormat::extensions` of the format. */
pub fn FormatId::extensions(self : FormatId) -> String {
  match self {
    Aac => "aac,adts"
    Ac3 => "ac3"
    Aiff => "aiff,aif,aifc,afc,afd"
    Amr => "amr"
    Png => "png"
    Asf => "asf,wmv,wma"
    Au => "au,snd"
    Caf => "caf"
    Dash => "mpd"
    Eac3 => "eac3,ec3"
    Flac => "flac"
    Hls => "m3u8,m3u"
    Matroska => "mkv,mka,mks,webm"
    Mjpeg => "mjpg,mjpeg,mpo"
    Mov => "mov,mp4,m4a,3gp,3g2,mj2,qt"
    Mp3 => "mp3,mp2,mp1,m1a,m2a,mpa"
    MpegTs => "ts,m2t,m2ts,mts,mpg,mpeg"
    Ogg => "ogg,oga,ogv,ogx,opus,spx"
    W64 => "w64"
    Wav => "wav,rf64,bw64"
  }
}

///|
/// `AVInputFormat::mime_type` (used by the MIME bonus). */
pub fn FormatId::mime_type(self : FormatId) -> String {
  match self {
    Aac => "audio/aac"
    Ac3 => "audio/ac3"
    Aiff => "audio/aiff"
    Amr => "audio/amr"
    Png => "image/png"
    Asf => "video/x-ms-asf"
    Au => "audio/basic"
    Caf => "audio/x-caf"
    Dash => "application/dash+xml"
    Eac3 => "audio/eac3"
    Flac => "audio/flac"
    Hls => "application/vnd.apple.mpegurl"
    Matroska => "video/x-matroska"
    Mjpeg => "video/x-mjpeg"
    Mov => "video/mp4"
    Mp3 => "audio/mpeg"
    MpegTs => "video/mp2t"
    Ogg => "application/ogg"
    W64 => "audio/x-w64"
    Wav => "audio/x-wav"
  }
}

///|
/// `AVProbeData`: the probe window plus the two optional hints FFmpeg also
/// scores (`filename` for the extension, `mime_type` for the MIME bonus). */
pub struct ProbeData {
  buf : Bytes
  filename : String
  mime_type : String
}

///|
/// Build a `ProbeData`. `filename` / `mime_type` default to "" (NULL in C). */
pub fn ProbeData::new(
  buf : Bytes,
  filename? : String = "",
  mime_type? : String = "",
) -> ProbeData {
  { buf, filename, mime_type }
}

// ---------------------------------------------------------------------------
// Bounds-checked byte readers (AV_RB*/AV_RL* on a possibly short buffer)
// ---------------------------------------------------------------------------

///|
fn pb_u8(b : Bytes, i : Int) -> UInt {
  if i < 0 || i >= b.length() {
    0U
  } else {
    b[i].to_uint()
  }
}

///|
fn pb_be16(b : Bytes, i : Int) -> UInt {
  (pb_u8(b, i) << 8) | pb_u8(b, i + 1)
}

///|
/// One byte, zero outside the buffer (the C reads padding there). */
fn pb_byte(b : Bytes, i : Int) -> Byte {
  if i < 0 || i >= b.length() {
    b'\x00'
  } else {
    b[i]
  }
}

///|
fn pb_be24(b : Bytes, i : Int) -> UInt {
  (pb_u8(b, i) << 16) | (pb_u8(b, i + 1) << 8) | pb_u8(b, i + 2)
}

///|
fn pb_be32(b : Bytes, i : Int) -> UInt {
  (pb_u8(b, i) << 24) |
  (pb_u8(b, i + 1) << 16) |
  (pb_u8(b, i + 2) << 8) |
  pb_u8(b, i + 3)
}

///|
fn pb_le32(b : Bytes, i : Int) -> UInt {
  pb_u8(b, i) |
  (pb_u8(b, i + 1) << 8) |
  (pb_u8(b, i + 2) << 16) |
  (pb_u8(b, i + 3) << 24)
}

///|
fn pb_be64(b : Bytes, i : Int) -> UInt64 {
  (pb_be32(b, i).to_uint64() << 32) | pb_be32(b, i + 4).to_uint64()
}

///|
/// Compare `n` bytes at `pos` against an ASCII tag; out-of-range is false so a
/// short probe window never matches. */
fn pb_match(b : Bytes, pos : Int, tag : String) -> Bool {
  let n = tag.length()
  if pos < 0 || pos + n > b.length() {
    return false
  }
  for i in 0..<n {
    if b[pos + i].to_int() != tag[i].to_int() {
      return false
    }
  }
  true
}

///|
/// `strncmp` against an ASCII prefix. */
fn pb_prefix(b : Bytes, tag : String) -> Bool {
  pb_match(b, 0, tag)
}

// ---------------------------------------------------------------------------
// Extension matching (`av_match_ext`)
// ---------------------------------------------------------------------------

///|
/// The extension of `filename` (text after the last '.'), "" when absent. */
fn probe_file_ext(filename : String) -> String {
  let n = filename.length()
  let mut i = n - 1
  while i >= 0 {
    if filename[i] == '.' {
      return filename[i + 1:].to_owned()
    }
    i = i - 1
  }
  ""
}

///|
/// `av_match_ext`: the extension of `filename` matched against a
/// comma-separated list, case-insensitively. */
fn probe_match_ext(filename : String, extensions : String) -> Bool {
  if filename == "" || extensions == "" {
    return false
  }
  let ext = probe_file_ext(filename)
  if ext == "" {
    return false
  }
  @libavutil.av_match_name(ext, extensions)
}

// ---------------------------------------------------------------------------
// ASCII helpers for the text-based probes (HLS playlists, DASH MPD)
// ---------------------------------------------------------------------------

///|
/// Copy bytes up to the first NUL (the C string view `av_stristr` sees). */
fn probe_ascii(buf : Bytes) -> String {
  let chars : Array[Char] = []
  for i in 0..<buf.length() {
    let c = buf[i].to_int()
    if c == 0 {
      break
    }
    chars.push(c.unsafe_to_char())
  }
  String::from_array(chars)
}

///|
/// `av_stristr` over the C-string prefix of `buf`. */
fn probe_stristr(buf : Bytes, needle : String) -> Bool {
  @libavutil.av_stristr(probe_ascii(buf), needle) is Some(_)
}

// ---------------------------------------------------------------------------
// ID3v2 skipping (`av_probe_input_format3` prologue)
// ---------------------------------------------------------------------------

///|
/// `ff_id3v2_match` at a byte offset. */
fn probe_id3v2_match_at(buf : Bytes, off : Int) -> Bool {
  if buf.length() - off < 10 {
    return false
  }
  pb_match(buf, off, "ID3") &&
  pb_u8(buf, off + 3) != 0xFFU &&
  pb_u8(buf, off + 4) != 0xFFU &&
  (pb_u8(buf, off + 6) & 0x80U) == 0U &&
  (pb_u8(buf, off + 7) & 0x80U) == 0U &&
  (pb_u8(buf, off + 8) & 0x80U) == 0U &&
  (pb_u8(buf, off + 9) & 0x80U) == 0U
}

///|
/// `ff_id3v2_tag_len` at a byte offset. */
fn probe_id3v2_tag_len_at(buf : Bytes, off : Int) -> Int {
  if buf.length() - off < 10 {
    return 0
  }
  let mut len = ((pb_u8(buf, off + 6).reinterpret_as_int() & 0x7F) << 21) +
    ((pb_u8(buf, off + 7).reinterpret_as_int() & 0x7F) << 14) +
    ((pb_u8(buf, off + 8).reinterpret_as_int() & 0x7F) << 7) +
    (pb_u8(buf, off + 9).reinterpret_as_int() & 0x7F) +
    10
  if (pb_u8(buf, off + 5).reinterpret_as_int() & 0x10) != 0 {
    len = len + 10
  }
  len
}

///|
/// The `nodat` state of `av_probe_input_format3`: whether a leading ID3v2 tag
/// hid the real header, and therefore how much the extension may lift the
/// score.
pub(all) enum ProbeNoData {
  /// No ID3v2 tag was skipped.
  ProbeNoId3
  /// A tag was skipped but a second tag nearly filled the window.
  ProbeId3AlmostGreater
  /// The tag alone is larger than the probe window.
  ProbeId3Greater
  /// The tag is at least `PROBE_BUF_MAX`.
  ProbeId3GreaterMax
}

///|
/// Strip leading ID3v2 tags the way `av_probe_input_format3` does, returning
/// the remaining view and the `nodat` state. */
fn probe_skip_id3(buf : Bytes) -> (Bytes, ProbeNoData) {
  let size = buf.length()
  let mut off = 0
  let mut nodat = ProbeNoId3
  while size - off > 10 && probe_id3v2_match_at(buf, off) {
    let id3len = probe_id3v2_tag_len_at(buf, off)
    if size - off > id3len + 16 {
      if size - off < 2 * id3len + 16 {
        nodat = ProbeId3AlmostGreater
      }
      off = off + id3len
    } else if id3len >= probe_buf_max {
      nodat = ProbeId3GreaterMax
      break
    } else {
      nodat = ProbeId3Greater
      break
    }
  }
  (buf[off:].to_owned(), nodat)
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

///|
/// One entry of the probe registry: what `FFInputFormat` carries that the
/// scoring loop needs, plus the `read_probe` callback. */
priv struct ProbeEntry {
  id : FormatId
  probe : (ProbeData) -> Int
}

///|
/// `ff_format_probe_table[]` in `libavformat/allformats.c` declaration order,
/// restricted to the demuxers this port implements. */
fn probe_registry() -> Array[ProbeEntry] {
  [
    { id: Aac, probe: probe_adts_aac },
    { id: Ac3, probe: probe_ac3 },
    { id: Aiff, probe: probe_aiff },
    { id: Amr, probe: probe_amr },
    { id: Png, probe: probe_png },
    { id: Asf, probe: probe_asf },
    { id: Au, probe: probe_au },
    { id: Caf, probe: probe_caf },
    { id: Dash, probe: probe_dash },
    { id: Eac3, probe: probe_eac3 },
    { id: Flac, probe: probe_flac },
    { id: Hls, probe: probe_hls },
    { id: Matroska, probe: probe_matroska },
    { id: Mjpeg, probe: probe_mjpeg },
    { id: Mov, probe: probe_mov },
    { id: Mp3, probe: probe_mp3 },
    { id: MpegTs, probe: probe_mpegts },
    { id: Ogg, probe: probe_ogg },
    { id: W64, probe: probe_w64 },
    { id: Wav, probe: probe_wav },
  ]
}

///|
/// `av_probe_input_format3`: score every registered demuxer over the same
/// window and return the winner. A tie yields `None` (FFmpeg clears `fmt`),
/// and `is_opened` is not modelled because every format here is a file format
/// (`AVFMT_NOFILE` is never set).
///
/// Scores are the raw `read_probe` values in `0..=100`, optionally lifted by
/// the filename extension and the MIME bonus exactly as in `format.c`.
pub fn av_probe_input_format(pd : ProbeData) -> (FormatId?, Int) {
  let (view, nodat) = probe_skip_id3(pd.buf)
  let lpd : ProbeData = {
    buf: view,
    filename: pd.filename,
    mime_type: pd.mime_type,
  }
  let mut score_max = 0
  let mut found : FormatId? = None
  for entry in probe_registry() {
    let mut score = (entry.probe)(lpd)
    if probe_match_ext(lpd.filename, entry.id.extensions()) {
      let ext_score = match nodat {
        ProbeNoId3 => 1
        ProbeId3Greater | ProbeId3AlmostGreater => probe_score_extension / 2 - 1
        ProbeId3GreaterMax => probe_score_extension
      }
      score = imax(score, ext_score)
    }
    if lpd.mime_type != "" &&
      @libavutil.av_match_name(lpd.mime_type, entry.id.mime_type()) {
      score = imin(score + probe_score_mime_bonus, probe_score_max)
    }
    if score > score_max {
      score_max = score
      found = Some(entry.id)
    } else if score == score_max {
      found = None
    }
  }
  if nodat is ProbeId3Greater {
    score_max = imin(probe_score_extension / 2 - 1, score_max)
  }
  (found, score_max)
}

///|
/// `av_probe_input_format2`: the same probe, additionally refusing a winner
/// whose score is at most `score_max` (FFmpeg's `av_probe_input_format2` drops
/// low-confidence matches).
pub fn av_probe_input_format2(pd : ProbeData) -> (FormatId?, Int) {
  let (fmt, score) = av_probe_input_format(pd)
  if score <= probe_score_retry {
    (None, score)
  } else {
    (fmt, score)
  }
}

// ---------------------------------------------------------------------------
// Buffer probing (`av_probe_input_buffer2`)
// ---------------------------------------------------------------------------

///|
/// `av_probe_input_buffer2`: read up to `max_probe_size` bytes from `pb`,
/// doubling the window from `PROBE_BUF_MIN` until a format is recognised or
/// the data runs out. The context is rewound to its original position, which
/// is what FFmpeg's `ffio_rewind_with_probe_data` achieves by keeping the
/// probe buffer.
///
/// Returns the format (when any) plus the final score. Unlike C, the rewind is
/// a plain `avio_seek` back to the start; callers that need the buffered bytes
/// already have them in their own source.
pub fn av_probe_input_buffer(
  pb : AvioContext,
  filename? : String = "",
  mime_type? : String = "",
  max_probe_size? : Int = probe_buf_max,
) -> Result[(FormatId?, Int), String] {
  let max_probe_size = if max_probe_size == 0 {
    probe_buf_max
  } else {
    max_probe_size
  }
  if max_probe_size < probe_buf_min {
    return Err("EINVAL")
  }
  let start = pb.avio_tell()
  let mut probe_size = probe_buf_min
  let mut collected = Bytes::new(0)
  let mut result : (FormatId?, Int) = (None, 0)
  let mut done = false
  while !done && probe_size <= max_probe_size {
    let want = probe_size - collected.length()
    let chunk = match pb.avio_read(want) {
      Ok(b) => b
      Err(_) => Bytes::new(0)
    }
    if chunk.length() > 0 {
      let merged : Array[Byte] = []
      for i in 0..<collected.length() {
        merged.push(collected[i])
      }
      for i in 0..<chunk.length() {
        merged.push(chunk[i])
      }
      collected = Bytes::from_array(merged[:])
    }
    // Re-probe the accumulated bytes with the current retry floor.
    let pd = ProbeData::new(collected, filename~, mime_type~)
    let (fmt, score) = av_probe_input_format(pd)
    let floor = if probe_size < max_probe_size {
      probe_score_retry
    } else {
      0
    }
    if fmt is Some(_) && score > floor {
      result = (fmt, score)
      done = true
    } else {
      // Keep the read cursor where it is: the C accumulates `buf_offset`
      // across iterations and only rewinds once, after probing finishes.
      result = (fmt, score)
      if chunk.length() == 0 {
        done = true
      } else {
        let next = imin(probe_size * 2, imax(max_probe_size, probe_size + 1))
        if next == probe_size {
          done = true
        } else {
          probe_size = next
        }
      }
    }
  }
  let _ = avio_seek_quiet(pb, start)
  match result {
    (Some(_), _) => Ok(result)
    (None, _) => Err("EINVAL")
  }
}

///|
/// Rewind helper: `avio_seek` back to an absolute position, ignoring the
/// result (the C code only logs a warning when the source is non-seekable). */
fn avio_seek_quiet(pb : AvioContext, pos : Int64) -> Unit {
  match pb.avio_seek(pos, SEEK_SET) {
    Ok(_) => ()
    Err(_) => ()
  }
}

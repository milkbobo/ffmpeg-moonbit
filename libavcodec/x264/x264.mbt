///|
/// Safe H.264 encoder surface over the libx264 stub (native-only). FFmpeg
/// n9.0.2 has no in-tree software H.264 encoder - the encode capability is
/// FFmpeg's libx264 wrapper reached through avcodec - so this package binds
/// it: the C stub owns the AVCodecContext, and every entry point here turns
/// flat status blobs into plain MoonBit values.
///
/// The encoder runs deterministic by construction: `thread_count = 1` and
/// (by default) `AV_CODEC_FLAG_BITEXACT`, which also drops the x264 version
/// SEI so the bitstream stays stable across x264 builds.
pub struct X264Encoder {
  h : X264EncHandle
}

///|
/// Pixel formats the binding accepts. The selector integers are translated
/// to `AVPixelFormat` inside the stub, never passed through as enum values.
pub(all) enum X264PixelFormat {
  Yuv420p
  Yuv420p10le
} derive(Debug, Eq)

///|
pub extend X264PixelFormat with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend X264PixelFormat with Eq::{equal, not_equal}

///|
fn X264PixelFormat::selector(self : X264PixelFormat) -> Int32 {
  match self {
    Yuv420p => 0
    Yuv420p10le => 1
  }
}

///|
/// Bytes per luma sample of the format (1 or 2).
pub fn X264PixelFormat::bytes_per_sample(self : X264PixelFormat) -> Int32 {
  match self {
    Yuv420p => 1
    Yuv420p10le => 2
  }
}

///|
/// The encoder call failed (open rejected, send/receive error, or a stub
/// allocation failure). `code` is the raw avcodec status where one exists.
pub(all) suberror X264Error {
  EncoderUnavailable(String)
  SendFailed(Int32)
  ReceiveFailed(Int32)
  ExtradataUnavailable
} derive(Debug)

///|
pub extend X264Error with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One encoded H.264 access unit. `pts`/`dts` are in the encoder's
/// `time_base` (`None` where avcodec reports AV_NOPTS_VALUE); with B
/// pictures the stream is in decode (dts) order.
pub(all) struct X264Packet {
  data : Bytes
  pts : Int64?
  dts : Int64?
  keyframe : Bool
}

///|
/// Result of pulling the encoder: a packet, nothing ready yet (`Again`),
/// or the drain completed (`Eof`).
pub(all) enum X264Receive {
  Packet(X264Packet)
  Again
  Eof
}

///|
fn x264_rd_i32(b : Bytes, i : Int32) -> Int32 {
  b[i].to_int() |
  (b[i + 1].to_int() << 8) |
  (b[i + 2].to_int() << 16) |
  (b[i + 3].to_int() << 24)
}

///|
fn x264_rd_i64(b : Bytes, i : Int32) -> Int64 {
  let lo = x264_rd_i32(b, i).reinterpret_as_uint().to_int64()
  let hi = x264_rd_i32(b, i + 4).reinterpret_as_uint().to_int64()
  lo | (hi << 32)
}

///|
fn x264_rd_opt_i64(v : Int64) -> Int64? {
  if v == 0x8000000000000000L {
    None
  } else {
    Some(v)
  }
}

///|
/// Whether the named encoder (`"libx264"`) lists the pixel format; used to
/// capability-gate optional paths (distro x264 builds vary in bit depth).
pub fn x264_supports(codec : String, fmt : X264PixelFormat) -> Bool {
  x264enc_supports_ffi(@utf8.encode(codec), fmt.selector()) == 1
}

///|
/// Open an H.264 encoder.
///
/// `options` reaches avcodec_open2's dictionary, so both AVCodecContext
/// fields (`g`, `bf`, `b`...) and the libx264 private options (`preset`,
/// `tune`, `profile`, `crf`, `x264-params`...) go through it as
/// key/value pairs. `global_header = true` moves SPS/PPS out of the
/// bitstream into `extradata` (avcC; the MP4/MKV configuration record);
/// `bitexact = true` additionally drops the x264 version SEI.
///
/// ```mbt nocheck
/// let enc = X264Encoder::open(width=96, height=64, options=[
///   ("preset", "medium"),
///   ("crf", "23"),
/// ])
/// ```
pub fn X264Encoder::open(
  width~ : Int32,
  height~ : Int32,
  pix_fmt~ : X264PixelFormat = Yuv420p,
  time_base~ : (Int32, Int32) = (1, 25),
  framerate~ : (Int32, Int32) = (25, 1),
  bit_rate~ : Int32 = 0,
  /// VBV maximum rate (bit/s) and buffer size (bits) passed to libx264 via
  /// `AVCodecContext.rc_max_rate` / `rc_buffer_size`. Required by
  /// `x264-params=nal-hrd=cbr`; both default to 0 (disabled).
  rc_max_rate~ : Int32 = 0,
  rc_buffer_size~ : Int32 = 0,
  global_header~ : Bool = true,
  bitexact~ : Bool = true,
  codec~ : String = "libx264",
  options~ : Array[(String, String)] = [],
) -> X264Encoder raise X264Error {
  if width <= 0 || height <= 0 {
    raise EncoderUnavailable("invalid geometry \{width}x\{height}")
  }
  let mut joined = ""
  for i, (key, value) in options {
    joined = joined + (if i == 0 { "" } else { ":" }) + key + "=" + value
  }
  let mut flags = 0
  if global_header {
    flags = flags | 1
  }
  if bitexact {
    flags = flags | 2
  }
  let handle = x264enc_open_ffi(
    @utf8.encode(codec),
    width,
    height,
    pix_fmt.selector(),
    time_base.0,
    time_base.1,
    framerate.0,
    framerate.1,
    bit_rate,
    flags,
    rc_max_rate,
    rc_buffer_size,
    @utf8.encode(joined),
  )
  // Failed opens come back as a failed-open handle (see ffi.mbt).
  if x264enc_status_ffi(handle) != 0 {
    let reason = match x264enc_errmsg_ffi(handle) {
      Some(msg) => @utf8.decode_lossy(msg)
      None => "unknown failure"
    }
    raise EncoderUnavailable("libx264 \{width}x\{height}: \{reason}")
  }
  { h: handle, }
}

///|
/// Push one frame. `y`/`u`/`v` are tightly-packed planes (visible area
/// only, row-major, `bytes_per_sample` bytes per sample, little-endian).
/// Returns `false` when the encoder still has an undrained packet
/// (avcodec's EAGAIN); the caller should drain and resend.
pub fn X264Encoder::send_frame(
  self : X264Encoder,
  pts~ : Int64,
  y~ : Bytes,
  u~ : Bytes,
  v~ : Bytes,
) -> Bool raise X264Error {
  match x264enc_send_frame_ffi(self.h, pts, y, u, v) {
    0 => true
    1 => false
    code => raise SendFailed(code)
  }
}

///|
/// Enter drain mode; after this only `receive_packet` until `Eof`.
pub fn X264Encoder::send_eof(self : X264Encoder) -> Unit raise X264Error {
  match x264enc_send_eof_ffi(self.h) {
    0 | 1 => ()
    code => raise SendFailed(code)
  }
}

///|
/// Pull the next packet. `Again` means the encoder needs another frame
/// (or, after `send_eof`, that nothing is ready yet); `Eof` ends the drain.
pub fn X264Encoder::receive_packet(
  self : X264Encoder,
) -> X264Receive raise X264Error {
  let blob = x264enc_receive_packet_ffi(self.h)
  guard blob is Some(b) else { raise ReceiveFailed(-1) }
  match x264_rd_i32(b, 0) {
    0 =>
      Packet({
        data: b[28:].to_owned(),
        pts: x264_rd_opt_i64(x264_rd_i64(b, 8)),
        dts: x264_rd_opt_i64(x264_rd_i64(b, 16)),
        keyframe: (x264_rd_i32(b, 4) & 1) == 1,
      })
    1 => Again
    2 => Eof
    _ => raise ReceiveFailed(-1)
  }
}

///|
/// Drain every remaining packet (`send_eof` + pull until `Eof`).
pub fn X264Encoder::flush(
  self : X264Encoder,
) -> Array[X264Packet] raise X264Error {
  self.send_eof()
  let out : Array[X264Packet] = []
  for ;; {
    match self.receive_packet() {
      Packet(p) => out.push(p)
      Again => continue
      Eof => break
    }
  }
  out
}

///|
/// The global-header extradata (avcC with `global_header = true`). Valid
/// immediately after `open`; raises before the first use otherwise.
pub fn X264Encoder::extradata(self : X264Encoder) -> Bytes raise X264Error {
  match x264enc_extradata_ffi(self.h) {
    Some(b) => b
    None => raise ExtradataUnavailable
  }
}

///|
/// Encode a whole frame sequence in one call: push every frame (draining
/// whenever avcodec reports EAGAIN), then flush. A convenience over the
/// incremental API for offline-style use.
pub fn X264Encoder::encode_all(
  self : X264Encoder,
  frames : Array[(Int64, Bytes, Bytes, Bytes)],
) -> Array[X264Packet] raise X264Error {
  let out : Array[X264Packet] = []
  fn drain_enc(
    enc : X264Encoder,
    out : Array[X264Packet],
  ) -> Unit raise X264Error {
    for ;; {
      match enc.receive_packet() {
        Packet(p) => out.push(p)
        Again => break
        Eof => break
      }
    }
  }
  for frame in frames {
    let (pts, y, u, v) = frame
    let mut sent = self.send_frame(pts~, y~, u~, v~)
    while !sent {
      drain_enc(self, out)
      sent = self.send_frame(pts~, y~, u~, v~)
    }
    drain_enc(self, out)
  }
  for packet in self.flush() {
    out.push(packet)
  }
  out
}

///|
/// Release the encoder immediately (idempotent). The external-object
/// finalizer makes the same call if the encoder is dropped unopened-close.
pub fn X264Encoder::close(self : X264Encoder) -> Unit {
  x264enc_close_ffi(self.h)
}

///|
/// Result of decoding an Annex B H.264 stream with FFmpeg's real software
/// decoder through the stub (`x264dec_annexb`): the frame count and
/// geometry of the decoded pictures plus the packed-plane blob. This is the
/// C-oracle side of the repository's dual-decode standard (the pure MoonBit
/// decoder must produce the same pixels).
pub struct X264DecFrames {
  n_frames : Int32
  width : Int32
  height : Int32
  /// 0 = yuv420p, 1 = yuv420p10le (the stub's sink kinds).
  kind : Int32
  blob : Bytes
}

///|
fn X264DecFrames::bps(self : X264DecFrames) -> Int32 {
  if self.kind == 1 {
    2
  } else {
    1
  }
}

///|
/// Bytes per sample of the decoded planes (1 for 8-bit, 2 for 10-bit LE).
pub fn X264DecFrames::bytes_per_sample(self : X264DecFrames) -> Int32 {
  self.bps()
}

///|
/// One frame's packed luma plane (visible area, row-major, LE samples).
pub fn X264DecFrames::frame_y(self : X264DecFrames, i : Int32) -> Bytes {
  let n = self.width * self.height * self.bps()
  let base = 16 +
    i * (n + 2 * (self.width / 2) * (self.height / 2) * self.bps())
  self.blob[base:base + n].to_owned()
}

///|
/// One frame's packed Cb plane.
pub fn X264DecFrames::frame_u(self : X264DecFrames, i : Int32) -> Bytes {
  let bps = self.bps()
  let cy = self.width * self.height * bps
  let cc = self.width / 2 * (self.height / 2) * bps
  let base = 16 + i * (cy + 2 * cc) + cy
  self.blob[base:base + cc].to_owned()
}

///|
/// One frame's packed Cr plane.
pub fn X264DecFrames::frame_v(self : X264DecFrames, i : Int32) -> Bytes {
  let bps = self.bps()
  let cy = self.width * self.height * bps
  let cc = self.width / 2 * (self.height / 2) * bps
  let base = 16 + i * (cy + 2 * cc) + cy + cc
  self.blob[base:base + cc].to_owned()
}

///|
/// Decode a whole Annex B H.264 stream with FFmpeg's real software decoder.
/// The geometry/kind header is validated against the payload size; a NULL
/// return from the stub surfaces as `Err`.
pub fn x264_decode_annexb(stream : Bytes) -> Result[X264DecFrames, String] {
  // Shape validation belongs on the MoonBit side of the boundary: a NAL
  // start code plus a non-empty payload is the shortest thing the C parser
  // could plausibly split. Rejecting it here keeps a caller's empty buffer
  // from turning into an opaque NULL blob at the extern.
  if stream.length() < 8 {
    return Err("x264dec: stream too short for an Annex B access unit")
  }
  let blob = match x264dec_annexb_ffi(stream) {
    Some(b) => b
    None => return Err("x264dec: C decoder failed on the stream")
  }
  if blob.length() < 16 {
    return Err("x264dec: short blob header")
  }
  let n = x264_rd_i32(blob, 0)
  let width = x264_rd_i32(blob, 4)
  let height = x264_rd_i32(blob, 8)
  let kind = x264_rd_i32(blob, 12)
  if width <= 0 || height <= 0 || n < 0 {
    return Err("x264dec: bad blob geometry")
  }
  if kind != 0 && kind != 1 {
    return Err("x264dec: unsupported pixel kind \{kind}")
  }
  let bps = if kind == 1 { 2 } else { 1 }
  let frame_len = width * height * bps + 2 * (width / 2) * (height / 2) * bps
  if blob.length() != 16 + n * frame_len {
    return Err("x264dec: blob size \{blob.length()} != 16 + \{n}x\{frame_len}")
  }
  Ok({ n_frames: n, width, height, kind, blob, })
}

///|
/// C-side view of an Annex B stream: the NAL types in stream order, the
/// access units FFmpeg's H.264 parser split, how many pictures the real
/// software decoder produced, and the WARNING/ERROR diagnostics raised
/// while consuming them. This turns the external "ffmpeg decodes with zero
/// warnings" arbitration into an in-process native test.
pub struct X264AnnexbProbe {
  /// Pictures the C decoder produced.
  n_frames : Int32
  /// Diagnostics at WARNING level during the decode.
  warnings : Int32
  /// Diagnostics at ERROR level (or worse) during the decode.
  errors : Int32
  /// NAL unit types in stream order, from raw start-code scanning.
  nal_types : Array[Int32]
  /// Byte sizes of the access units the H.264 parser split.
  au_sizes : Array[Int32]
}

///|
/// Probe an Annex B stream with the real FFmpeg H.264 parser/decoder.
/// Shape validation and blob decoding stay on the MoonBit side of the
/// boundary; a NULL return from the stub surfaces as `Err`.
pub fn x264_probe_annexb(stream : Bytes) -> Result[X264AnnexbProbe, String] {
  if stream.length() < 8 {
    return Err("x264probe: stream too short for an Annex B access unit")
  }
  let blob = match x264probe_annexb_ffi(stream) {
    Some(b) => b
    None => return Err("x264probe: C parser/decoder failed on the stream")
  }
  if blob.length() < 20 {
    return Err("x264probe: short blob header")
  }
  let n_frames = x264_rd_i32(blob, 0)
  let warnings = x264_rd_i32(blob, 4)
  let errors = x264_rd_i32(blob, 8)
  let n_nals = x264_rd_i32(blob, 12)
  let n_aus = x264_rd_i32(blob, 16)
  if n_frames < 0 || n_nals < 0 || n_aus < 0 {
    return Err("x264probe: bad blob counts")
  }
  let expected = 20 + n_nals + 4 * n_aus
  if blob.length() != expected {
    return Err("x264probe: blob size \{blob.length()} != \{expected}")
  }
  let nal_types : Array[Int32] = []
  for i = 0; i < n_nals; i = i + 1 {
    nal_types.push(blob[20 + i].to_int())
  }
  let au_sizes : Array[Int32] = []
  for i = 0; i < n_aus; i = i + 1 {
    au_sizes.push(x264_rd_i32(blob, 20 + n_nals + 4 * i))
  }
  Ok({ n_frames, warnings, errors, nal_types, au_sizes, })
}

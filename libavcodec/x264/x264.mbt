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
/// Per-picture type request, mirroring libx264.c's `X264_frame` switch on
/// `frame->pict_type`. `Auto` signals nothing and lets x264's own GOP
/// logic pick; the other variants set the corresponding `AVPictureType`
/// so libx264 maps them to `X264_TYPE_KEYFRAME` (I, not IDR - unless the
/// `forced-idr` option applies, as `Idr` arranges), `X264_TYPE_P` or
/// `X264_TYPE_B`.
pub(all) enum X264PictType {
  Auto
  Keyframe
  Idr
  P
  B
}

///|
fn X264PictType::to_sel(self : X264PictType) -> Int32 {
  match self {
    Auto => 0
    Keyframe => 1
    Idr => 2
    P => 3
    B => 4
  }
}

///|
/// One `AVRegionOfInterest` region for per-MB quantisation deltas
/// (libx264.c's `setup_roi`). The rectangle is in pixels, exclusive at
/// `right` / `bottom` and clipped upstream to the 16px macroblock grid;
/// `qoffset_num / qoffset_den` is the normalised quality offset in
/// -1..+1 (negative = better quality, positive = worse) which upstream
/// scales by the QP range and clamps per macroblock.
///
/// Setup requires adaptive quantisation to be on (`aq-mode != 0`; it is
/// x264's default with CRF but the caller can pin `aq-mode=1`) — with AQ
/// off upstream warns once and silently skips the ROI. When regions
/// overlap the FIRST region in the array wins.
pub(all) struct X264Roi {
  top : Int32
  bottom : Int32
  left : Int32
  right : Int32
  qoffset_num : Int32
  qoffset_den : Int32
}

///|
/// Serialize to the stub's 24-bytes-per-region little-endian blob
/// (struct field order; `self_size` is filled host-side).
fn X264Roi::encode_blob(rois : Array[X264Roi]) -> Bytes {
  let buf : Array[Byte] = []
  for r in rois {
    for v in [r.top, r.bottom, r.left, r.right, r.qoffset_num, r.qoffset_den] {
      buf.push((v & 0xFF).to_byte())
      buf.push(((v >> 8) & 0xFF).to_byte())
      buf.push(((v >> 16) & 0xFF).to_byte())
      buf.push(((v >> 24) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(buf[:])
}

///|
/// Stereo3D layout for per-picture frame packing (libx264.c's
/// `reconfig_encoder` STEREO3D path). x264 emits an H.264
/// frame-packing-arrangement SEI for as long as the packing stays set;
/// a conforming decoder exports it as `Stereo3d` frame side data. The
/// upstream INVERT flag is rejected by x264 (warning, no packing) and is
/// therefore not exposed here.
pub(all) enum X264Stereo3D {
  Checkerboard
  Columns
  Lines
  SideBySide
  TopBottom
  FrameSequence
  TwoD
}

///|
/// Selector 0 stays reserved for "absent" at the FFI boundary.
fn X264Stereo3D::to_sel(self : X264Stereo3D) -> Int32 {
  match self {
    Checkerboard => 1
    Columns => 2
    Lines => 3
    SideBySide => 4
    TopBottom => 5
    FrameSequence => 6
    TwoD => 7
  }
}

///|
/// Which side the `X264VideoHint` rectangles describe (libx264.c's
/// `setup_mb_info` via `AVVideoHintType`): `Constant` rects delimit the
/// UNCHANGED areas (the rest of the frame is assumed changed);
/// `Changed` rects delimit the CHANGED areas (the rest is assumed
/// unchanged).
pub(all) enum X264VideoHintKind {
  Constant
  Changed
}

///|
fn X264VideoHintKind::to_type(self : X264VideoHintKind) -> Int32 {
  match self {
    Constant => 1
    Changed => 2
  }
}

///|
/// Per-macroblock motion hint (libx264.c's `setup_mb_info` →
/// `pic.prop.mb_info`): pixel rectangles telling the encoder which areas
/// of the picture did (`Changed`) or did not (`Constant`) change since
/// the previous picture. x264 only acts on the array when the `mb_info`
/// option is enabled — pass `("mb_info", "1")` in `open`'s options.
/// Rectangles are pixel coordinates (no alignment requirement; upstream
/// clamps to the 16px macroblock grid) and an empty `rects` array is
/// legal: with `Constant` it claims the WHOLE frame changed, with
/// `Changed` that nothing did.
pub(all) struct X264VideoHint {
  kind : X264VideoHintKind
  rects : Array[X264HintRect]
}

///|
/// One pixel rectangle of an `X264VideoHint`.
pub(all) struct X264HintRect {
  x : Int32
  y : Int32
  width : Int32
  height : Int32
}

///|
/// Serialize to the stub's 16-bytes-per-rect little-endian blob.
fn X264VideoHint::encode_blob(self : X264VideoHint) -> Bytes {
  let buf : Array[Byte] = []
  for r in self.rects {
    for v in [r.x, r.y, r.width, r.height] {
      buf.push((v & 0xFF).to_byte())
      buf.push(((v >> 8) & 0xFF).to_byte())
      buf.push(((v >> 16) & 0xFF).to_byte())
      buf.push(((v >> 24) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(buf[:])
}

///|
/// Pixel formats the binding accepts. The selector integers are translated
/// to `AVPixelFormat` inside the stub, never passed through as enum values.
pub(all) enum X264PixelFormat {
  Yuv420p
  Yuv420p10le
  Yuv422p
  Yuv422p10le
  Yuv444p
  Yuv444p10le
  Gray8
  Gray10le
  /// Semi-planar 4:2:0: plane 0 luma, plane 1 interleaved U then V.
  Nv12
  /// Semi-planar 4:2:0 with the chroma pairs swapped (V then U).
  Nv21
  /// Semi-planar 4:2:2: one luma plane plus interleaved U then V.
  Nv16
  /// Semi-planar 4:2:2 at 10-bit little-endian.
  Nv20le
  /// Packed 32-bit BGRX (alpha ignored) for the `libx264rgb` encoder.
  Bgr0
  /// Packed 24-bit BGR for the `libx264rgb` encoder.
  Bgr24
  /// Packed 24-bit RGB for the `libx264rgb` encoder.
  Rgb24
  /// Full-range 4:2:0 (FFmpeg's deprecated `yuvj420p` alias). Same plane
  /// layout as `Yuv420p`; the wrapper turns on VUI full-range signalling
  /// unless `color_range` overrides it.
  Yuvj420p
  /// Full-range 4:2:2 (`yuvj422p`): same layout as `Yuv422p`.
  Yuvj422p
  /// Full-range 4:4:4 (`yuvj444p`): same layout as `Yuv444p`.
  Yuvj444p
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
    Yuv422p => 2
    Yuv422p10le => 3
    Yuv444p => 4
    Yuv444p10le => 5
    Gray8 => 6
    Gray10le => 7
    Nv12 => 8
    Nv21 => 9
    Nv16 => 10
    Nv20le => 11
    Bgr0 => 12
    Bgr24 => 13
    Rgb24 => 14
    Yuvj420p => 15
    Yuvj422p => 16
    Yuvj444p => 17
  }
}

///|
/// Bytes per component of the format (1 or 2). Note that the packed RGB
/// formats store whole pixels in one plane: size `y` with
/// `bytes_per_pixel()`, not with this.
pub fn X264PixelFormat::bytes_per_sample(self : X264PixelFormat) -> Int32 {
  match self {
    Yuv420p | Yuv422p | Yuv444p | Gray8 => 1
    Yuvj420p | Yuvj422p | Yuvj444p => 1
    Yuv420p10le | Yuv422p10le | Yuv444p10le | Gray10le => 2
    Nv12 | Nv21 | Nv16 => 1
    Nv20le => 2
    Bgr0 | Bgr24 | Rgb24 => 1
  }
}

///|
/// Bytes per pixel of plane 0: 1 for the planar and grayscale formats,
/// 2 for the 10-bit ones (a sample spans two bytes), and 3 (Bgr24, Rgb24)
/// or 4 (Bgr0) for the packed RGB formats. The semi-planar chroma plane
/// holds 2 samples per pixel of `bytes_per_sample()` bytes each.
pub fn X264PixelFormat::bytes_per_pixel(self : X264PixelFormat) -> Int32 {
  match self {
    Bgr24 | Rgb24 => 3
    Bgr0 => 4
    _ => self.bytes_per_sample()
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
  /// A per-picture side-data payload violated its shape contract
  /// (e.g. A53 captions whose length is not a multiple of 3).
  BadSideData(String)
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
/// Colour metadata values for `X264Encoder::open`, kept as the raw
/// `AVCOL_*` / `AVCHROMA_LOC_*` integers so the wrapper's own value space
/// (libx264.c copies these onto `x264_param_t.vui`) passes through
/// unchanged; 0 everywhere means unspecified and leaves the field unset.
/// The handful below are the values the tests and README reference; any
/// other FFmpeg enumeration value (e.g. `AVCOL_TRC_ARIB_STD_B67 = 17`)
/// passes through equally well.
pub let x264_color_range_mpeg : Int32 = 1 // AVCOL_RANGE_MPEG

///|
pub let x264_color_range_jpeg : Int32 = 2 // AVCOL_RANGE_JPEG

///|
pub let x264_col_spc_unspecified : Int32 = 2 // AVCOL_SPC_UNSPECIFIED (0 is RGB!)

///|
pub let x264_col_spc_bt709 : Int32 = 1 // AVCOL_SPC_BT709

///|
pub let x264_col_spc_smpte170m : Int32 = 4 // AVCOL_SPC_SMPTE170M

///|
pub let x264_col_spc_bt2020nc : Int32 = 7 // AVCOL_SPC_BT2020NCL

///|
pub let x264_col_pri_bt709 : Int32 = 1 // AVCOL_PRI_BT709

///|
pub let x264_col_pri_bt2020 : Int32 = 9 // AVCOL_PRI_BT2020

///|
pub let x264_col_trc_bt709 : Int32 = 1 // AVCOL_TRC_BT709

///|
pub let x264_col_trc_smpte2084 : Int32 = 15 // AVCOL_TRC_SMPTE2084

///|
pub let x264_chroma_loc_left : Int32 = 1 // AVCHROMA_LOC_LEFT

///|
pub let x264_chroma_loc_center : Int32 = 2 // AVCHROMA_LOC_CENTER

///|
// av_get_token removes one escape layer when av_dict_parse_string reads
// the outer dictionary. Preserve nested x264-params separators and quotes.
fn x264_option_token(text : String) -> String {
  let out = StringBuilder()
  for ch in text.iter() {
    if ch == ':' ||
      ch == '=' ||
      ch == '\\' ||
      ch == '\'' ||
      ch.is_ascii_whitespace() {
      out.write_char('\\')
    }
    out.write_char(ch)
  }
  out.to_string()
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
/// Packed RGB input (`Bgr0`/`Bgr24`/`Rgb24`) goes through the separate
/// `libx264rgb` encoder: pass `codec = "libx264rgb"`.
/// Values are passed literally, including nested `x264-params` lists;
/// callers do not escape the outer dictionary separators. Empty keys or
/// values and embedded NUL characters are rejected before entering C.
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
  /// Colour metadata passed to libx264's VUI signalling (the raw
  /// `AVCOL_*` / `AVCHROMA_LOC_*` values; see the `x264_color_*` /
  /// `x264_col_*` / `x264_chroma_loc_*` constants). 0 (the default) means
  /// unspecified and leaves the field unset, so an absent value never
  /// forces a VUI. Note that FFmpeg 9's encode core force-marks every
  /// selected `yuvj*` format `AVCOL_RANGE_JPEG` before the wrapper runs
  /// (encode.c ff_encode_preinit), so the YUVJ formats always signal
  /// full-range regardless of `color_range`.
  color_range~ : Int32 = 0,
  /// `AVCOL_SPC_UNSPECIFIED` is 2, not 0 (0 is RGB), so the default
  /// mirrors the wrapper's "field unset" guard; pass
  /// `x264_col_spc_unspecified` explicitly if you want to be literal.
  colorspace~ : Int32 = 2,
  color_primaries~ : Int32 = 0,
  color_trc~ : Int32 = 0,
  chroma_sample_location~ : Int32 = 0,
  /// Sample aspect ratio as a fraction (`sample_aspect_ratio`), written
  /// into the SPS VUI by libx264 at open (av_reduce-capped at 4096).
  /// The default 0/0 leaves the aspect-ratio VUI unset (square-pixel
  /// inference is then the decoder's policy, not the bitstream's);
  /// `sar=(1, 1)` explicitly marks square pixels.
  sar~ : (Int32, Int32) = (0, 0),
  options~ : Array[(String, String)] = [],
) -> X264Encoder raise X264Error {
  if width <= 0 || height <= 0 {
    raise EncoderUnavailable("invalid geometry \{width}x\{height}")
  }
  let mut joined = ""
  for i, (key, value) in options {
    if key.is_empty() ||
      value.is_empty() ||
      key.iter().any(ch => ch.to_int() == 0) ||
      value.iter().any(ch => ch.to_int() == 0) {
      raise EncoderUnavailable(
        "option keys and values must be nonempty and contain no NUL",
      )
    }
    joined = joined +
      (if i == 0 { "" } else { ":" }) +
      x264_option_token(key) +
      "=" +
      x264_option_token(value)
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
    color_range,
    colorspace,
    color_primaries,
    color_trc,
    chroma_sample_location,
    sar.0,
    sar.1,
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
/// Grayscale and the packed RGB formats (`Bgr0`/`Bgr24`/`Rgb24`, opened
/// with `codec="libx264rgb"`) pass empty `u` and `v` buffers; the
/// semi-planar `Nv12`/`Nv21`/`Nv16`/`Nv20le` formats pass one interleaved
/// chroma plane of `chroma_width * chroma_height * 2` samples as `u` and
/// an empty `v` (`Nv12` pairs are U then V, `Nv21` pairs are V then U).
/// Packed RGB `y` planes hold `width * height * bytes_per_pixel()` bytes.
/// Returns `false` when the encoder still has an undrained packet
/// (avcodec's EAGAIN); the caller should drain and resend.
/// `force_idr = true` requests an IDR picture at this frame's PTS, even
/// with an open GOP. On EAGAIN, resend with the same flag and planes.
/// `pict_type` is libx264.c's per-frame `AVPictureType` mapping (the
/// `X264_frame` switch): `Auto` lets x264 pick, `Keyframe` asks for an
/// I picture that is NOT an IDR (open-GOP scene-cut keyframe), `Idr`
/// behaves like `force_idr = true`, and `P` / `B` pin the slice type
/// x264 would otherwise choose with b-adapt. `force_idr = true` wins
/// over `pict_type = Keyframe`, mirroring upstream's
/// `I + forced-idr -> X264_TYPE_IDR`. The forcing is per picture: the
/// stub restores the open-time `forced-idr` option value afterwards,
/// so mixed IDR / non-IDR keyframe requests compose.
///
/// SEI side data (libx264.c's per-frame path): `a53` carries raw A53
/// closed-caption blocks - a multiple of 3 bytes, up to 63 (21 blocks) -
/// which libx264 wraps into a registered ITU-T T.35 `GA94` SEI (option
/// `a53cc`, on by upstream default). `sei_unregistered` carries one
/// unregistered-SEI payload verbatim: a 16-byte UUID followed by the
/// data (up to 16 MiB per SEI); the binding enables the upstream
/// `udu_sei` option on demand. Both attach to THIS picture's access
/// unit only, and both round-trip: a conforming decoder exports them
/// as `A53Cc` / `SeiUnregistered` frame side data.
///
/// `roi` carries `AVRegionOfInterest` per-macroblock quantisation deltas
/// for THIS picture (see `X264Roi`; requires `aq-mode != 0`, first
/// region wins overlaps, and a zero `qoffset_den` is rejected here at
/// the safe boundary). `stereo3d` attaches an `AVStereo3D` side data for
/// THIS picture, which libx264 turns into frame packing; x264 emits the
/// frame-packing SEI on IDR pictures only and captures the packing in
/// force when the picture is actually encoded (lookahead may delay an
/// IDR past its send call - the safe pattern is one request per forced
/// IDR riding the same send_frame), and the decoder exports the
/// resulting frame-packing SEI as `Stereo3d` side data. `video_hint`
/// carries per-macroblock motion hints for THIS picture (see
/// `X264VideoHint`; requires the `mb_info` option at open time).
pub fn X264Encoder::send_frame(
  self : X264Encoder,
  pts~ : Int64,
  y~ : Bytes,
  u~ : Bytes,
  v~ : Bytes,
  force_idr~ : Bool = false,
  pict_type~ : X264PictType = Auto,
  a53~ : Bytes = b"",
  sei_unregistered~ : Bytes = b"",
  roi~ : Array[X264Roi] = [],
  stereo3d~ : X264Stereo3D? = None,
  video_hint~ : X264VideoHint? = None,
) -> Bool raise X264Error {
  if a53.length() % 3 != 0 {
    raise BadSideData(
      "A53 caption payload must be a multiple of 3 bytes, got \{a53.length()}",
    )
  }
  if a53.length() > 63 {
    raise BadSideData(
      "A53 caption payload exceeds 21 cc blocks (63 bytes), got \{a53.length()}",
    )
  }
  for r in roi {
    if r.qoffset_den == 0 {
      raise BadSideData(
        "X264Roi qoffset_den must not be zero (upstream AVERROR(EINVAL))",
      )
    }
  }
  let request = if force_idr { X264PictType::Idr } else { pict_type }
  let sel = request.to_sel()
  let roi_blob = X264Roi::encode_blob(roi)
  let stereo_sel = match stereo3d {
    Some(s) => s.to_sel()
    None => 0
  }
  let hint_type = match video_hint {
    Some(h) => h.kind.to_type()
    None => 0
  }
  let hint_blob = match video_hint {
    Some(h) => h.encode_blob()
    None => b""
  }
  match
    x264enc_send_frame_ffi(
      self.h,
      pts,
      y,
      u,
      v,
      sel,
      a53,
      sei_unregistered,
      roi_blob,
      stereo_sel,
      hint_type,
      hint_blob,
    ) {
    0 => true
    1 => false
    code => raise SendFailed(code)
  }
}

///|
/// Enter drain mode; after acceptance, call `receive_packet` until `Eof`.
/// Raises `SendFailed(1)` on backpressure: receive pending packets, then
/// retry `send_eof`. `flush` handles this retry and collects the packets.
/// Repeated calls after drain acceptance succeed.
pub fn X264Encoder::send_eof(self : X264Encoder) -> Unit raise X264Error {
  match x264enc_send_eof_ffi(self.h) {
    0 => ()
    code => raise SendFailed(code)
  }
}

///|
/// Pull the next packet. `Again` means the encoder needs another frame
/// until EOF is accepted; `Eof` ends the drain.
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
/// Drain every remaining packet, receiving and retrying EOF on backpressure.
/// Repeated calls return an empty array after draining completes.
pub fn X264Encoder::flush(
  self : X264Encoder,
) -> Array[X264Packet] raise X264Error {
  let out : Array[X264Packet] = []
  for ;; {
    match x264enc_send_eof_ffi(self.h) {
      0 => break
      1 =>
        match self.receive_packet() {
          Packet(p) => out.push(p)
          Again => raise ReceiveFailed(1)
          Eof => return out
        }
      code => raise SendFailed(code)
    }
  }
  for ;; {
    match self.receive_packet() {
      Packet(p) => out.push(p)
      Again => raise ReceiveFailed(1)
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
  /// Sink kinds: 0/1/2 = 420 at 8/10/9 bits;
  /// 3/4 = 422 at 8/10 bits; 5/6 = 444 at 8/10 bits;
  /// 7 = GBR planar 4:4:4 (libx264rgb keeps RGB plane order).
  kind : Int32
  /// First-frame VUI-derived colour metadata, the raw `AVCOL_*` /
  /// `AVCHROMA_LOC_*` values (0 = unspecified in the bitstream).
  color_range : Int32
  colorspace : Int32
  color_primaries : Int32
  color_trc : Int32
  chroma_location : Int32
  blob : Bytes
}

///|
fn X264DecFrames::bps(self : X264DecFrames) -> Int32 {
  if self.kind == 0 || self.kind == 3 || self.kind == 5 || self.kind == 7 {
    1
  } else {
    2
  }
}

///|
fn x264_chroma_geometry(
  width : Int32,
  height : Int32,
  kind : Int32,
) -> (Int32, Int32) {
  let cw = if kind >= 5 { width } else { width / 2 + width % 2 }
  let ch = if kind >= 3 { height } else { height / 2 + height % 2 }
  (cw, ch)
}

///|
fn X264DecFrames::chroma_bytes(self : X264DecFrames) -> Int32 {
  let (cw, ch) = x264_chroma_geometry(self.width, self.height, self.kind)
  cw * ch * self.bps()
}

///|
/// Bytes per sample of the decoded planes (1 for 8-bit, 2 for 9/10-bit LE).
pub fn X264DecFrames::bytes_per_sample(self : X264DecFrames) -> Int32 {
  self.bps()
}

///|
/// One frame's packed luma plane (visible area, row-major, LE samples).
pub fn X264DecFrames::frame_y(self : X264DecFrames, i : Int32) -> Bytes {
  let n = self.width * self.height * self.bps()
  let base = 36 + i * (n + 2 * self.chroma_bytes())
  self.blob[base:base + n].to_owned()
}

///|
/// One frame's packed Cb plane.
pub fn X264DecFrames::frame_u(self : X264DecFrames, i : Int32) -> Bytes {
  let bps = self.bps()
  let cy = self.width * self.height * bps
  let cc = self.chroma_bytes()
  let base = 36 + i * (cy + 2 * cc) + cy
  self.blob[base:base + cc].to_owned()
}

///|
/// One frame's packed Cr plane.
pub fn X264DecFrames::frame_v(self : X264DecFrames, i : Int32) -> Bytes {
  let bps = self.bps()
  let cy = self.width * self.height * bps
  let cc = self.chroma_bytes()
  let base = 36 + i * (cy + 2 * cc) + cy + cc
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
  if blob.length() < 36 {
    return Err("x264dec: short blob header")
  }
  let n = x264_rd_i32(blob, 0)
  let width = x264_rd_i32(blob, 4)
  let height = x264_rd_i32(blob, 8)
  let kind = x264_rd_i32(blob, 12)
  let color_range = x264_rd_i32(blob, 16)
  let colorspace = x264_rd_i32(blob, 20)
  let color_primaries = x264_rd_i32(blob, 24)
  let color_trc = x264_rd_i32(blob, 28)
  let chroma_location = x264_rd_i32(blob, 32)
  if width <= 0 || height <= 0 || n < 0 {
    return Err("x264dec: bad blob geometry")
  }
  if kind < 0 || kind > 7 {
    return Err("x264dec: unsupported pixel kind \{kind}")
  }
  let bps = if kind == 0 || kind == 3 || kind == 5 || kind == 7 {
    1L
  } else {
    2L
  }
  let (cw, ch) = x264_chroma_geometry(width, height, kind)
  let payload = (blob.length() - 36).to_int64()
  let luma_samples = width.to_int64() * height.to_int64()
  if n == 0 || luma_samples > payload {
    return Err("x264dec: geometry exceeds packed payload")
  }
  let frame_len = (luma_samples + 2L * cw.to_int64() * ch.to_int64()) * bps
  // Compare by division before multiplying by the untrusted frame count.
  if payload / frame_len != n.to_int64() || payload % frame_len != 0 {
    return Err("x264dec: blob size \{blob.length()} != 36 + \{n}x\{frame_len}")
  }
  Ok({
    n_frames: n,
    width,
    height,
    kind,
    color_range,
    colorspace,
    color_primaries,
    color_trc,
    chroma_location,
    blob,
  })
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

///|
/// One picture as the real FFmpeg H.264 decoder output it, in display
/// order. `pict_type` follows `AVPictureType` (1 = I, 2 = P, 3 = B);
/// `key_frame` is 1 when `AV_FRAME_FLAG_KEY` is set (FFmpeg n9.0.2 removed
/// `AVFrame.key_frame`). `flags` / `decode_error_flags` are the raw frame
/// flags. `digest_lo` / `digest_hi` are the halves of a 64-bit FNV-1a
/// digest over the visible-area planes (Y, then chroma, row-major, LE
/// samples); `pts_lo` / `pts_hi` are the halves of the int64 PTS bits.
pub(all) struct X264FrameInfo {
  pict_type : Int32
  key_frame : Int32
  flags : Int32
  decode_error_flags : Int32
  pts_lo : Int32
  pts_hi : Int32
  digest_lo : Int32
  digest_hi : Int32
}

///|
/// Frame-level C-side view of an Annex B stream: geometry and pixel format
/// of the first picture, the WARNING/ERROR diagnostics raised while
/// decoding, and one `X264FrameInfo` per output picture in display order.
pub struct X264FrameProbe {
  n_frames : Int32
  warnings : Int32
  errors : Int32
  width : Int32
  height : Int32
  pix_fmt : Int32
  frames : Array[X264FrameInfo]
}

///|
/// Probe an Annex B stream with the real FFmpeg H.264 decoder at frame
/// granularity. Shape validation and blob decoding stay on the MoonBit
/// side of the boundary; a NULL return from the stub surfaces as `Err`.
/// The C stub installs a process-global av_log callback for the duration
/// of the decode, so callers must not run this probe concurrently with
/// `x264_probe_annexb`.
pub fn x264_probe_frames(stream : Bytes) -> Result[X264FrameProbe, String] {
  if stream.length() < 8 {
    return Err("x264probe: stream too short for an Annex B access unit")
  }
  let blob = match x264probe_frames_ffi(stream) {
    Some(b) => b
    None => return Err("x264probe: C frame decoder failed on the stream")
  }
  if blob.length() < 32 {
    return Err("x264probe: short frame blob header")
  }
  let n_frames = x264_rd_i32(blob, 0)
  let warnings = x264_rd_i32(blob, 4)
  let errors = x264_rd_i32(blob, 8)
  let width = x264_rd_i32(blob, 12)
  let height = x264_rd_i32(blob, 16)
  let pix_fmt = x264_rd_i32(blob, 20)
  let fields = x264_rd_i32(blob, 24)
  if fields != 8 || n_frames < 0 {
    return Err("x264probe: bad frame blob shape")
  }
  let expected = 32 + 32 * n_frames
  if blob.length() != expected {
    return Err("x264probe: frame blob size \{blob.length()} != \{expected}")
  }
  let frames : Array[X264FrameInfo] = []
  for i = 0; i < n_frames; i = i + 1 {
    let base = 32 + 32 * i
    frames.push({
      pict_type: x264_rd_i32(blob, base),
      key_frame: x264_rd_i32(blob, base + 4),
      flags: x264_rd_i32(blob, base + 8),
      decode_error_flags: x264_rd_i32(blob, base + 12),
      pts_lo: x264_rd_i32(blob, base + 16),
      pts_hi: x264_rd_i32(blob, base + 20),
      digest_lo: x264_rd_i32(blob, base + 24),
      digest_hi: x264_rd_i32(blob, base + 28),
    })
  }
  Ok({ n_frames, warnings, errors, width, height, pix_fmt, frames, })
}

///|
/// Unified video-encode facade (`§414`): one codec selector, one option
/// struct and one entry pair for every supported video codec, mirroring
/// the audio encoders' open/push/finish pattern. H.264 is the only
/// backend today; a future encoder plugs in as a new `VideoCodec` case
/// and both the config surface and the CLI keep working unchanged.
///
/// Everything here is a thin, byte-preserving forwarder: the batch entry
/// dispatches to the codec's own `*_encode_frames*` functions with exactly
/// the arguments the callers used to pass, and the streaming entry wraps
/// `H264StreamEncoder`. Nothing in this file changes bitstream bytes.

///|
/// Video codecs available through the facade.
pub(all) enum VideoCodec {
  H264
}

///|
/// Codec name for reports and JSON summaries.
pub fn VideoCodec::name(self : VideoCodec) -> String {
  match self {
    VideoCodec::H264 => "h264"
  }
}

///|
/// The facade's default codec (what omitting the codec selection means).
pub fn VideoCodec::default() -> VideoCodec {
  VideoCodec::H264
}

///|
/// The input/output layout's ffmpeg name for the configured depth:
/// planar 4:2:0 8-bit (`yuv420p`), or little-endian 16-bit above 8 bits
/// (`yuv420p9le` / `yuv420p10le`, the High 10 family).
pub fn video_pixel_format(bit_depth : Int32) -> String {
  if bit_depth > 8 {
    "yuv420p\{bit_depth}le"
  } else {
    "yuv420p"
  }
}

///|
/// Codec-shared encode options. The defaults reproduce the §403/§413
/// sequence defaults (B-line + 8x8DCT + CABAC-RD pricing + weighted P
/// prediction on, CAVLC entropy). Rate controls (`target_bytes` or
/// `vbv_maxrate`/`vbv_bufsize` + `fps`) are supported by the batch entry;
/// streaming supports P/B VBV, while ABR remains batch-only. Options this struct
/// does not carry (`pcm_first`, `intra_in_p`, `intra4x4_in_p`,
/// `level_idc`, `vbv_init`) stay reachable through the codec's direct
/// entry points.
pub(all) struct VideoEncConfig {
  width : Int32
  height : Int32
  qp : Int32
  cabac : Bool
  cabac_rd : Bool
  dct8x8 : Bool
  b_slices : Bool
  b_parts : Bool
  intra_in_b : Bool
  intra4x4_in_b : Bool
  weightp : Bool
  bit_depth : Int32
  aud : Bool
  aq : Bool
  aq_strength : Int32
  target_bytes : Int32
  vbv_maxrate : Int32
  vbv_bufsize : Int32
  fps : Int32
  /// `§415`: P-slice multi-reference history depth (1 = single reference).
  /// `§418` extends it to the B schedule (the B's list 0 holds the past
  /// references); batch rate controls are supported.
  multi_ref : Int32
  /// `§420`: chroma format 1 (4:2:0, default) or 2 (4:2:2).
  chroma_format : Int32
  /// Periodic IDR distance in display frames, 0 = disabled. Batch ABR and
  /// VBV cover the full sequence, including reordered B GOPs.
  /// Explicit forced IDRs restart this interval in the streaming encoder.
  keyint : Int32
}

///|
/// Defaults for a `width` x `height` sequence: QP 26, CAVLC, the §403
/// feature defaults on, 8-bit, no rate controls.
pub fn VideoEncConfig::new(width~ : Int32, height~ : Int32) -> VideoEncConfig {
  {
    width,
    height,
    qp: 26,
    cabac: false,
    cabac_rd: true,
    dct8x8: true,
    b_slices: true,
    b_parts: true,
    intra_in_b: true,
    intra4x4_in_b: true,
    weightp: true,
    bit_depth: 8,
    aud: false,
    aq: false,
    aq_strength: 1,
    target_bytes: 0,
    vbv_maxrate: 0,
    vbv_bufsize: 0,
    fps: 0,
    multi_ref: 1,
    chroma_format: 1,
    keyint: 0,
  }
}

///|
/// Streaming video encoder: finished access units appear on `drain()`
/// after every `push_frame` and `finish()` flushes the tail. The facade
/// reports the codec name and the pixel format so embedders (and the CLI
/// summary) need no codec-specific knowledge.
pub struct VideoEncoder {
  codec : VideoCodec
  config : VideoEncConfig
  h264 : H264StreamEncoder
}

///|
/// Open the streaming encoder for `codec` with `config`.
pub fn VideoEncoder::open(
  codec~ : VideoCodec,
  config~ : VideoEncConfig,
  stats~ : H264EncStats = H264EncStats::new(),
) -> Result[VideoEncoder, String] {
  if config.keyint < 0 {
    return Err("video enc: keyint must be nonnegative")
  }
  match codec {
    VideoCodec::H264 => {
      if config.target_bytes > 0 {
        return Err("video enc: the streaming encoder does not support ABR")
      }
      match
        H264StreamEncoder::open(
          width=config.width,
          height=config.height,
          qp=config.qp,
          cabac=config.cabac,
          cabac_rd=config.cabac_rd,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          bit_depth=config.bit_depth,
          chroma_format=config.chroma_format,
          multi_ref=config.multi_ref,
          aud=config.aud,
          aq=config.aq,
          aq_strength=config.aq_strength,
          stats~,
          vbv_maxrate=config.vbv_maxrate,
          vbv_bufsize=config.vbv_bufsize,
          fps=config.fps,
        ) {
        Ok(h264) => Ok({ codec, config, h264, })
        Err(e) => Err(e)
      }
    }
  }
}

///|
/// Codec name of this encoder (for JSON summaries).
pub fn VideoEncoder::codec_name(self : VideoEncoder) -> String {
  self.codec.name()
}

///|
/// Input pixel format name (for JSON summaries).
pub fn VideoEncoder::pixel_format(self : VideoEncoder) -> String {
  video_pixel_format(self.config.bit_depth)
}

///|
pub fn VideoEncoder::width(self : VideoEncoder) -> Int32 {
  self.config.width
}

///|
pub fn VideoEncoder::height(self : VideoEncoder) -> Int32 {
  self.config.height
}

///|
/// Push one display-order planar frame (packed u8 at 8 bits, little-endian
/// 16-bit samples above). Returns when the frame is consumed; call
/// `drain()` for the access units this made final.
/// `force_idr=true` closes any pending B pair and starts an independent GOP.
pub fn VideoEncoder::push_frame(
  self : VideoEncoder,
  y : Bytes,
  u : Bytes,
  v : Bytes,
  force_idr~ : Bool = false,
) -> Result[Unit, String] {
  let force_idr = force_idr ||
    (
      self.config.keyint > 0 &&
      self.h264.next_display > 0 &&
      self.h264.next_display - self.h264.gop_start >= self.config.keyint
    )
  match self.codec {
    VideoCodec::H264 => self.h264.push_frame(y, u, v, force_idr~)
  }
}

///|
/// Access units made final by pushes so far, in decode order.
pub fn VideoEncoder::drain(self : VideoEncoder) -> Array[Bytes] {
  match self.codec {
    VideoCodec::H264 => self.h264.drain()
  }
}

///|
/// Flush the encoder tail (delayed B pictures and the stream end).
pub fn VideoEncoder::finish(
  self : VideoEncoder,
) -> Result[Array[Bytes], String] {
  match self.codec {
    VideoCodec::H264 => self.h264.finish()
  }
}

///|
/// Encode a whole display-order frame sequence with the batch entry for
/// `codec` (rate controls supported). With `keyint=0`, byte-identical to
/// the codec's own entry with the same effective options; the plain (no rate
/// control) case could equally go through the streaming encoder, which
/// the CLI tests pin byte-for-byte.
/// Positive `keyint` uses periodic independent GOPs. ABR targets the whole
/// sequence; VBV keeps a continuous CPB in decoding order.
/// `recon` excludes every IDR and keeps predicted pictures in coding order.
pub fn video_encode(
  frames : Array[(Bytes, Bytes, Bytes)],
  codec~ : VideoCodec,
  config~ : VideoEncConfig,
  recon~ : Array[Bytes] = [],
  stats~ : H264EncStats = H264EncStats::new(),
) -> Result[Bytes, String] {
  if config.keyint < 0 {
    return Err("video enc: keyint must be nonnegative")
  }
  if config.keyint > 0 {
    if frames.length() == 0 {
      return Err("h264 enc: no frames")
    }
    if config.vbv_maxrate > 0 || config.vbv_bufsize > 0 || config.fps > 0 {
      return video_encode_periodic_vbv(frames, codec~, config~, recon~, stats~)
    }
    if config.target_bytes > 0 {
      return video_encode_periodic_abr(frames, codec~, config~, recon~, stats~)
    }
    let enc = match VideoEncoder::open(codec~, config~, stats~) {
      Ok(e) => e
      Err(e) => return Err(e)
    }
    let output : Array[Bytes] = []
    for (y, u, v) in frames {
      match enc.push_frame(y, u, v) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      stats.frame_qps.push(config.qp)
      for au in enc.drain() {
        output.push(au)
      }
    }
    match enc.finish() {
      Ok(tail) =>
        for au in tail {
          output.push(au)
        }
      Err(e) => return Err(e)
    }
    // Like the codec's batch recon output, keep only predicted pictures;
    // each periodic IDR starts a fresh independently reconstructed GOP.
    for frame in enc.h264.recons {
      recon.push(frame)
    }
    return Ok(h264_enc_concat(output))
  }
  match codec {
    VideoCodec::H264 =>
      if config.cabac {
        h264_encode_frames_cabac(
          frames,
          cabac_rd=config.cabac_rd,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          width=config.width,
          height=config.height,
          qp=config.qp,
          aq=config.aq,
          aq_strength=config.aq_strength,
          aud=config.aud,
          target_bytes=config.target_bytes,
          vbv_maxrate=config.vbv_maxrate,
          vbv_bufsize=config.vbv_bufsize,
          fps=config.fps,
          bit_depth=config.bit_depth,
          recon~,
          stats~,
          multi_ref=config.multi_ref,
          chroma_format=config.chroma_format,
        )
      } else {
        h264_encode_frames(
          frames,
          dct8x8=config.dct8x8,
          b_slices=config.b_slices,
          b_parts=config.b_parts,
          intra_in_b=config.intra_in_b,
          intra4x4_in_b=config.intra4x4_in_b,
          weightp=config.weightp,
          width=config.width,
          height=config.height,
          qp=config.qp,
          aq=config.aq,
          aq_strength=config.aq_strength,
          aud=config.aud,
          target_bytes=config.target_bytes,
          vbv_maxrate=config.vbv_maxrate,
          vbv_bufsize=config.vbv_bufsize,
          fps=config.fps,
          bit_depth=config.bit_depth,
          recon~,
          stats~,
          multi_ref=config.multi_ref,
          chroma_format=config.chroma_format,
        )
      }
  }
}

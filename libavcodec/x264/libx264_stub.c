// ⛔ 未接线（用户决定 2026-11-17）：wasm-only——libx264 native 绑定下线
// （agent.md §2），moon.pkg 已注释置空，本文件不再参与任何构建；内容
// 原样保留为历史证据。
//
// C wrapper over FFmpeg's avcodec encoder API for the MoonBit libavcodec/x264
// binding (the libx264 wrapper is FFmpeg's portable software H.264 encoder).
// Only the C ABI surface lives here; everything MoonBit-visible is wrapped
// safely in x264.mbt.
//
// The encoder handle is a GC-tracked external object (finalizer releases the
// AVCodecContext / AVFrame / AVPacket); every entry point returns flat
// little-endian record blobs as MoonBit Bytes or an int32 status, so there
// are no other ownership questions across the boundary: plane Bytes are
// copied into an AVFrame during send_frame, packet payloads are copied out
// of AVPacket during receive_packet, and both directions are call-scoped.
//
// The decoder entry at the bottom is round-trip test support: it decodes a
// whole Annex B stream with the real FFmpeg H.264 decoder and packs the
// presentation-order output exactly like the pure port's
// H264Frame::yuvp() (visible area, planar Y/Cb/Cr, LE samples), so the two
// decoders can be diffed pixel-for-pixel in-process.

#include "moonbit.h"

#include "libavcodec/avcodec.h"
#include "libavutil/common.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/frame.h"
#include "libavutil/imgutils.h"
#include "libavutil/log.h"
#include "libavutil/opt.h"
#include "libavutil/pixdesc.h"
#include "libavutil/pixfmt.h"
#include "libavutil/stereo3d.h"
#include "libavutil/video_hint.h"

#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  AVCodecContext *ctx;
  AVFrame *frame;
  AVPacket *pkt;
  // Open-time value of libx264's `forced-idr` private option (0 unless the
  // caller's options string set it). Per-picture IDR forcing writes the
  // option to 1 for that picture only and restores this value afterwards,
  // so mixed IDR / non-IDR keyframe requests compose (upstream reads the
  // sticky option every frame; the binding keeps the caller's base).
  int64_t base_forced_idr;
  // Open-failure state: the MoonBit toolchain's optional return for
  // external objects does not map a raw pointer to Some (verified against
  // moon 0.1.20261104), so open() ALWAYS returns a handle - on failure one
  // carrying the message - and the MoonBit side checks status() first.
  int failed;
  char errmsg[256];
} X264Enc;

static void x264enc_destroy(void *ptr) {
  X264Enc *e = (X264Enc *)ptr;
  if (!e)
    return;
  avcodec_free_context(&e->ctx);
  av_frame_free(&e->frame);
  av_packet_free(&e->pkt);
  // Do NOT free ptr -- GC manages the container.
}

// A failed-open handle (message copied in; ctx/frame/pkt stay NULL).
static X264Enc *x264enc_fail(const char *fmt, const char *arg) {
  X264Enc *e = (X264Enc *)moonbit_make_external_object(x264enc_destroy,
                                                       sizeof(X264Enc));
  if (!e)
    return NULL;
  memset(e, 0, sizeof(*e));
  e->failed = 1;
  snprintf(e->errmsg, sizeof(e->errmsg), fmt, arg ? arg : "");
  return e;
}

static void put_i32(uint8_t *p, int32_t v) { memcpy(p, &v, 4); }

static void put_i64(uint8_t *p, int64_t v) { memcpy(p, &v, 8); }

// Pixel format selector -> AVPixelFormat. Kept as an int mapping (instead of
// passing enum values) so the MoonBit side never assumes the C enum layout.
// Stable selectors; independent of AVPixelFormat enum values.
static int sel_pix_fmt(int sel, enum AVPixelFormat *out) {
  switch (sel) {
  case 0:
    *out = AV_PIX_FMT_YUV420P;
    return 0;
  case 1:
    *out = AV_PIX_FMT_YUV420P10LE;
    return 0;
  case 2:
    *out = AV_PIX_FMT_YUV422P;
    return 0;
  case 3:
    *out = AV_PIX_FMT_YUV422P10LE;
    return 0;
  case 4:
    *out = AV_PIX_FMT_YUV444P;
    return 0;
  case 5:
    *out = AV_PIX_FMT_YUV444P10LE;
    return 0;
  case 6:
    *out = AV_PIX_FMT_GRAY8;
    return 0;
  case 7:
    *out = AV_PIX_FMT_GRAY10LE;
    return 0;
  case 8:
    *out = AV_PIX_FMT_NV12;
    return 0;
  case 9:
    *out = AV_PIX_FMT_NV21;
    return 0;
  case 10:
    *out = AV_PIX_FMT_NV16;
    return 0;
  case 11:
    *out = AV_PIX_FMT_NV20LE;
    return 0;
  case 12:
    *out = AV_PIX_FMT_BGR0;
    return 0;
  case 13:
    *out = AV_PIX_FMT_BGR24;
    return 0;
  case 14:
    *out = AV_PIX_FMT_RGB24;
    return 0;
  case 15:
    *out = AV_PIX_FMT_YUVJ420P;
    return 0;
  case 16:
    *out = AV_PIX_FMT_YUVJ422P;
    return 0;
  case 17:
    *out = AV_PIX_FMT_YUVJ444P;
    return 0;
  default:
    return -1;
  }
}

// flags: bit0 = AV_CODEC_FLAG_GLOBAL_HEADER, bit1 = AV_CODEC_FLAG_BITEXACT.
// `options` is an escaped "key=value:key=value" list (one av_get_token
// escape layer supplied by MoonBit) applied through avcodec_open2's
// dictionary (ctx options first, then the codec's private options: preset,
// tune, profile, crf, g, bf, ...). `rc_max_rate` / `rc_buffer_size` map onto
// libx264's VBV fields, which `nal-hrd=cbr` requires; zero leaves the
// existing flat/CRF configurations untouched.
// The five colour metadata ints are AVCOL_* / AVCHROMA_LOC_* values as
// libavcodec stores them; each field's *_UNSPECIFIED value (0 for all but
// colorspace, whose unspecified is 2) leaves it unset, mirroring
// libx264.c's `!= UNSPECIFIED` guards. FFmpeg 9's encode core force-marks
// every selected yuvj format AVCOL_RANGE_JPEG before the wrapper's private
// init runs (encode.c ff_encode_preinit), so yuvj inputs always signal VUI
// full-range no matter what color_range says here.
// Always returns a handle; on failure it is a failed-open handle carrying
// the message (see `x264enc_status`).
MOONBIT_FFI_EXPORT
X264Enc *x264enc_open(moonbit_bytes_t codec_name, int32_t width, int32_t height,
                      int32_t pix_sel, int32_t tb_num, int32_t tb_den,
                      int32_t fps_num, int32_t fps_den, int32_t bit_rate,
                      int32_t flags, int32_t rc_max_rate,
                      int32_t rc_buffer_size, int32_t color_range,
                      int32_t colorspace, int32_t color_primaries,
                      int32_t color_trc, int32_t chroma_sample_location,
                      int32_t sar_num, int32_t sar_den,
                      moonbit_bytes_t options) {
  enum AVPixelFormat fmt;
  if (sel_pix_fmt(pix_sel, &fmt) < 0)
    return x264enc_fail("%s: bad pixel format selector", NULL);
  const AVCodec *enc = avcodec_find_encoder_by_name((const char *)codec_name);
  if (!enc) {
    fprintf(stderr, "x264enc: no encoder '%s'\n", (const char *)codec_name);
    return x264enc_fail("no encoder '%s'", (const char *)codec_name);
  }
  AVCodecContext *cc = avcodec_alloc_context3(enc);
  AVFrame *frame = av_frame_alloc();
  AVPacket *pkt = av_packet_alloc();
  if (!cc || !frame || !pkt) {
    avcodec_free_context(&cc);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return x264enc_fail("allocation failed", NULL);
  }
  cc->width = width;
  cc->height = height;
  cc->pix_fmt = fmt;
  cc->time_base = (AVRational){tb_num, tb_den};
  cc->framerate = (AVRational){fps_num, fps_den};
  if (bit_rate > 0)
    cc->bit_rate = bit_rate;
  // FFmpeg's libx264 wrapper copies these onto
  // x264_param_t.rc.i_vbv_max_bitrate / i_vbv_buffer_size. Setting them
  // through the wrapped context (rather than requiring x264-params) makes
  // `nal-hrd=cbr` produce a real CBR HRD stream.
  if (rc_max_rate > 0)
    cc->rc_max_rate = rc_max_rate;
  if (rc_buffer_size > 0)
    cc->rc_buffer_size = rc_buffer_size;
  if (flags & 1)
    cc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  if (flags & 2)
    cc->flags |= AV_CODEC_FLAG_BITEXACT;
  // Colour metadata: zero means unspecified, matching the AVCOL_*
  // enumerations, so absent fields keep the wrapper's own defaults
  // (libx264.c copies these onto x264_param_t.vui during X264_init).
  if (color_range != AVCOL_RANGE_UNSPECIFIED)
    cc->color_range = color_range;
  // AVCOL_SPC_UNSPECIFIED is 2 (0 is RGB!), so 2 means "leave unset" and
  // an explicit 0 still reaches the encoder as a real colourspace.
  if (colorspace != AVCOL_SPC_UNSPECIFIED)
    cc->colorspace = colorspace;
  if (color_primaries != AVCOL_PRI_UNSPECIFIED)
    cc->color_primaries = color_primaries;
  if (color_trc != AVCOL_TRC_UNSPECIFIED)
    cc->color_trc = color_trc;
  if (chroma_sample_location != AVCHROMA_LOC_UNSPECIFIED)
    cc->chroma_sample_location = chroma_sample_location;
  // Sample aspect ratio (libx264.c:1308 av_reduce's into the SPS VUI at
  // open). 0/0 leaves the field unset (av_reduce maps it to 0/1 and
  // x264 skips the aspect-ratio VUI), matching the default open.
  cc->sample_aspect_ratio = (AVRational){sar_num, sar_den};
  cc->thread_count = 1; // deterministic output: no frame/slice threading
  AVDictionary *dict = NULL;
  if (Moonbit_array_length(options) > 0 &&
      av_dict_parse_string(&dict, (const char *)options, "=", ":", 0) < 0) {
    av_dict_free(&dict);
    avcodec_free_context(&cc);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return x264enc_fail("bad options string", NULL);
  }
  int ret = avcodec_open2(cc, enc, &dict);
  av_dict_free(&dict);
  if (ret < 0) {
    fprintf(stderr, "x264enc: open '%s' failed: %s\n", (const char *)codec_name,
            av_err2str(ret));
    avcodec_free_context(&cc);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return x264enc_fail("avcodec_open2: %s", av_err2str(ret));
  }
  X264Enc *e = (X264Enc *)moonbit_make_external_object(x264enc_destroy,
                                                       sizeof(X264Enc));
  if (!e) {
    avcodec_free_context(&cc);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    return NULL; // container allocation failure: nothing to wrap
  }
  memset(e, 0, sizeof(*e));
  e->ctx = cc;
  e->frame = frame;
  e->pkt = pkt;
  // Snapshot the caller's forced-idr base (an av_dict option may have set
  // it at open). Per-picture Idr requests toggle around this value.
  {
    int64_t v = 0;
    if (av_opt_get_int(cc->priv_data, "forced-idr", 0, &v) >= 0)
      e->base_forced_idr = v;
  }
  return e;
}

// 0 = healthy, 1 = failed open (`errmsg` explains), -1 = NULL handle.
MOONBIT_FFI_EXPORT
int32_t x264enc_status(X264Enc *e) {
  if (!e)
    return -1;
  return e->failed ? 1 : 0;
}

// The failure message of a failed-open handle (NULL when healthy).
MOONBIT_FFI_EXPORT
moonbit_bytes_t x264enc_errmsg(X264Enc *e) {
  if (!e || !e->failed)
    return NULL;
  int32_t len = (int32_t)strnlen(e->errmsg, sizeof(e->errmsg));
  moonbit_bytes_t out = moonbit_make_bytes(len, 0);
  if (out)
    memcpy(out, e->errmsg, len);
  return out;
}

// Whether the named encoder lists the selected pixel format (used to
// capability-gate high bit-depth tests: distro x264 builds vary).
MOONBIT_FFI_EXPORT
int32_t x264enc_supports(moonbit_bytes_t codec_name, int32_t pix_sel) {
  enum AVPixelFormat fmt;
  if (sel_pix_fmt(pix_sel, &fmt) < 0)
    return 0;
  const AVCodec *enc = avcodec_find_encoder_by_name((const char *)codec_name);
  if (!enc)
    return 0;
  const enum AVPixelFormat *fmts = NULL;
  int n = 0;
  if (avcodec_get_supported_config(NULL, enc, AV_CODEC_CONFIG_PIX_FORMAT, 0,
                                   (const void **)&fmts, &n) < 0 ||
      !fmts || n <= 0)
    return 0;
  for (int i = 0; i < n; i++)
    if (fmts[i] == fmt)
      return 1;
  return 0;
}

// Copy tightly-packed planes into a fresh AVFrame buffer and push it.
// Returns 0 ok, 1 EAGAIN, -1 error. Plane lengths are validated against the
// opened geometry. Planar formats pass y/u/v separately; the semi-planar
// NV formats pass one interleaved U(+V) plane as `u` and an empty `v`;
// grayscale and the packed RGB formats (libx264rgb) pass empty `u` and `v`.
MOONBIT_FFI_EXPORT
int32_t x264enc_send_frame(X264Enc *e, int64_t pts, moonbit_bytes_t y,
                           moonbit_bytes_t u, moonbit_bytes_t v,
                           int32_t pict_sel, moonbit_bytes_t a53,
                           moonbit_bytes_t sei_unreg,
                           moonbit_bytes_t roi_blob,
                           int32_t stereo3d_sel, int32_t hint_type,
                           moonbit_bytes_t hint_blob) {
  if (!e || !e->ctx || e->failed)
    return -1;
  int w = e->ctx->width, h = e->ctx->height;
  const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(e->ctx->pix_fmt);
  int ch = AV_CEIL_RSHIFT(h, desc->log2_chroma_h);
  // Plane count comes from av_pix_fmt_count_planes, not desc->nb_components:
  // NV formats report three components sharing two planes, and packed RGB
  // reports three-four components on one plane.
  int planes = av_pix_fmt_count_planes(e->ctx->pix_fmt);
  // Row bytes straight from the descriptor math. This covers planar luma
  // (w samples), 10-bit samples (x2 bytes), the packed NV chroma rows
  // (cw*2 samples) and the packed RGB plane (w*3 or w*4 bytes) without
  // per-format arithmetic here.
  int row_y = av_image_get_linesize(e->ctx->pix_fmt, w, 0);
  int row_c = planes == 1 ? 0 : av_image_get_linesize(e->ctx->pix_fmt, w, 1);
  int64_t need_y = (int64_t)row_y * h;
  int64_t need_c = planes == 1 ? 0 : (int64_t)row_c * ch;
  int64_t need_v = planes == 3 ? need_c : 0;
  if ((int64_t)Moonbit_array_length(y) != need_y ||
      (int64_t)Moonbit_array_length(u) != need_c ||
      (int64_t)Moonbit_array_length(v) != need_v) {
    fprintf(stderr,
            "x264enc: plane size mismatch (y=%d want %lld, u=%d want %lld, "
            "v=%d want %lld)\n",
            Moonbit_array_length(y), (long long)need_y,
            Moonbit_array_length(u), (long long)need_c,
            Moonbit_array_length(v), (long long)need_v);
    return -1;
  }
  AVFrame *f = e->frame;
  av_frame_unref(f);
  f->format = e->ctx->pix_fmt;
  f->width = w;
  f->height = h;
  f->pts = pts;
  // libx264.c's X264_frame switch on frame->pict_type: I maps to
  // X264_TYPE_KEYFRAME (an I that is an IDR only when the forced-idr
  // option is set), P and B pin the slice type, everything else is
  // X264_TYPE_AUTO. av_frame_unref above resets pict_type so a request
  // cannot leak to the next picture; the forced-idr option is restored
  // to the open-time base around each Idr request so per-picture forcing
  // composes. Buffers remain call-scoped copies, including retries.
  if (pict_sel >= 1 && pict_sel <= 4) {
    // Only I pictures consult the forced-idr option; rewrite it around
    // every I request so per-picture IDR / non-IDR keyframes compose even
    // when the open-time base is 0 (a previous Idr request must not leak
    // into a later Keyframe).
    if (pict_sel == 1 || pict_sel == 2) {
      int ret = av_opt_set_int(e->ctx->priv_data, "forced-idr",
                               pict_sel == 2 ? 1 : e->base_forced_idr, 0);
      if (ret < 0)
        return ret;
    }
    switch (pict_sel) {
    case 1:
    case 2:
      f->pict_type = AV_PICTURE_TYPE_I;
      break;
    case 3:
      f->pict_type = AV_PICTURE_TYPE_P;
      break;
    case 4:
      f->pict_type = AV_PICTURE_TYPE_B;
      break;
    }
  }
  // libx264.c's SEI side-data path: AV_FRAME_DATA_A53_CC becomes a
  // registered (ITU-T T.35, GA94) payload when the a53cc option is on
  // (upstream default), AV_FRAME_DATA_SEI_UNREGISTERED passes through
  // verbatim but only when udu_sei is on (upstream default OFF - the
  // explicit payload here is the caller's intent, so flip the option on
  // demand; it only gates the copy, never the encoding itself).
  // av_frame_unref above drops any previous side data, so the attachment
  // is strictly per picture.
  if (Moonbit_array_length(a53) > 0) {
    AVFrameSideData *sd = av_frame_new_side_data(
        f, AV_FRAME_DATA_A53_CC, Moonbit_array_length(a53));
    if (!sd)
      return -1;
    memcpy(sd->data, a53, Moonbit_array_length(a53));
  }
  if (Moonbit_array_length(sei_unreg) > 0) {
    int ret = av_opt_set_int(e->ctx->priv_data, "udu_sei", 1, 0);
    if (ret < 0)
      return ret;
    AVFrameSideData *sd = av_frame_new_side_data(
        f, AV_FRAME_DATA_SEI_UNREGISTERED, Moonbit_array_length(sei_unreg));
    if (!sd)
      return -1;
    memcpy(sd->data, sei_unreg, Moonbit_array_length(sei_unreg));
  }
  // libx264.c's ROI path (setup_roi): AV_FRAME_DATA_REGIONS_OF_INTEREST
  // carrying AVRegionOfInterest records. The blob from MoonBit holds 24
  // bytes per region - six little-endian int32s in struct order (top,
  // bottom, left, right, qoffset.num, qoffset.den); self_size is filled
  // from the host's sizeof here so no struct-layout assumption crosses
  // the boundary. Upstream requires AQ on (else it warns once and skips
  // the ROI) and iterates the list in reverse, so the FIRST region wins
  // where regions overlap.
  if (Moonbit_array_length(roi_blob) > 0) {
    if (Moonbit_array_length(roi_blob) % 24 != 0)
      return -1;
    int nb = Moonbit_array_length(roi_blob) / 24;
    AVFrameSideData *sd = av_frame_new_side_data(
        f, AV_FRAME_DATA_REGIONS_OF_INTEREST,
        nb * sizeof(AVRegionOfInterest));
    if (!sd)
      return -1;
    AVRegionOfInterest *rs = (AVRegionOfInterest *)sd->data;
    for (int i = 0; i < nb; i++) {
      int32_t v[6];
      memcpy(v, roi_blob + i * 24, 24);
      rs[i].self_size = (uint32_t)sizeof(AVRegionOfInterest);
      rs[i].top = v[0];
      rs[i].bottom = v[1];
      rs[i].left = v[2];
      rs[i].right = v[3];
      rs[i].qoffset.num = v[4];
      rs[i].qoffset.den = v[5];
    }
  }
  // libx264.c's reconfig_encoder STEREO3D path: AV_FRAME_DATA_STEREO3D
  // carrying an AVStereo3D maps to x264's frame packing (i_frame_packing)
  // with a reconfig on change. Selector 0 = absent; 1..7 mirror
  // libx264.c's switch (checkerboard, columns, lines, side-by-side,
  // top-bottom, frame-sequence, 2D). The INVERT flag is upstream-
  // rejected (warning + no packing) and is therefore not exposed by the
  // binding.
  if (stereo3d_sel >= 1 && stereo3d_sel <= 7) {
    static const int stereo_types[7] = {
      AV_STEREO3D_CHECKERBOARD, AV_STEREO3D_COLUMNS,
      AV_STEREO3D_LINES,        AV_STEREO3D_SIDEBYSIDE,
      AV_STEREO3D_TOPBOTTOM,    AV_STEREO3D_FRAMESEQUENCE,
      AV_STEREO3D_2D,
    };
    AVStereo3D *stereo = av_stereo3d_create_side_data(f);
    if (!stereo)
      return -1;
    stereo->type = stereo_types[stereo3d_sel - 1];
  }
  // libx264.c's mb_info path (setup_mb_info): AV_FRAME_DATA_VIDEO_HINT
  // carrying an AVVideoHint of AVVideoRect records. hint_type 1 =
  // AV_VIDEO_HINT_TYPE_CONSTANT (rects delimit UNCHANGED areas, the rest
  // is assumed changed), 2 = AV_VIDEO_HINT_TYPE_CHANGED (rects delimit
  // CHANGED areas, the rest unchanged); 0 = absent. The blob holds 16
  // little-endian uint32s per rect (x, y, width, height); the AVVideoHint
  // and its rect array are built host-side via
  // av_video_hint_create_side_data, so no struct layout crosses the
  // boundary. x264 only acts on the array when the mb_info option is on
  // (analyse.b_mb_info), which the caller passes at open time.
  if (hint_type >= 1 && hint_type <= 2) {
    if (Moonbit_array_length(hint_blob) % 16 != 0)
      return -1;
    int nb = Moonbit_array_length(hint_blob) / 16;
    // FFmpeg 9.0.2's creator takes only (frame, nb_rects) - the kind is
    // assigned as a plain struct field afterwards.
    AVVideoHint *hint = av_video_hint_create_side_data(f, nb);
    if (!hint)
      return -1;
    hint->type = hint_type == 1 ? AV_VIDEO_HINT_TYPE_CONSTANT
                                : AV_VIDEO_HINT_TYPE_CHANGED;
    AVVideoRect *rs = av_video_hint_rects(hint);
    for (int i = 0; i < nb; i++) {
      uint32_t v[4];
      memcpy(v, hint_blob + i * 16, 16);
      rs[i].x = v[0];
      rs[i].y = v[1];
      rs[i].width = v[2];
      rs[i].height = v[3];
    }
  }
  if (av_frame_get_buffer(f, 0) < 0)
    return -1;
  const uint8_t *srcs[3] = {y, u, v};
  int pl_h[3] = {h, ch, ch};
  int rows[3] = {row_y, row_c, row_c};
  for (int p = 0; p < planes; p++) {
    for (int r = 0; r < pl_h[p]; r++)
      memcpy(f->data[p] + (ptrdiff_t)r * f->linesize[p],
             srcs[p] + (ptrdiff_t)r * rows[p], rows[p]);
  }
  int ret = avcodec_send_frame(e->ctx, f);
  av_frame_unref(f); // send_frame keeps its own reference
  if (ret == AVERROR(EAGAIN))
    return 1;
  if (ret < 0) {
    fprintf(stderr, "x264enc: send_frame: %s\n", av_err2str(ret));
    return -1;
  }
  return 0;
}

// Enter drain mode. Already draining is success. Returns 0 ok, 1 EAGAIN,
// -1 error; EAGAIN means EOF was NOT accepted and must be retried.
MOONBIT_FFI_EXPORT
int32_t x264enc_send_eof(X264Enc *e) {
  if (!e || !e->ctx || e->failed)
    return -1;
  int ret = avcodec_send_frame(e->ctx, NULL);
  if (ret == AVERROR_EOF)
    return 0;
  if (ret == AVERROR(EAGAIN))
    return 1;
  if (ret < 0) {
    fprintf(stderr, "x264enc: send_eof: %s\n", av_err2str(ret));
    return -1;
  }
  return 0;
}

// Pull one packet. Blob layout (little-endian):
//   status i32 (0 packet, 1 EAGAIN, 2 EOF, -1 error)
//   flags  i32 (bit0 = AV_PKT_FLAG_KEY)
//   pts    i64 (INT64_MIN = AV_NOPTS_VALUE)
//   dts    i64 (INT64_MIN = AV_NOPTS_VALUE)
//   size   i32, then `size` payload bytes
MOONBIT_FFI_EXPORT
moonbit_bytes_t x264enc_receive_packet(X264Enc *e) {
  if (!e || !e->ctx || e->failed)
    return NULL;
  int ret = avcodec_receive_packet(e->ctx, e->pkt);
  int status = ret == 0               ? 0
               : ret == AVERROR(EAGAIN) ? 1
               : ret == AVERROR_EOF     ? 2
                                        : -1;
  if (status < 0)
    fprintf(stderr, "x264enc: receive_packet: %s\n", av_err2str(ret));
  int32_t size = ret == 0 ? e->pkt->size : 0;
  moonbit_bytes_t out = moonbit_make_bytes(28 + size, 0);
  if (!out)
    return NULL;
  put_i32(out + 0, status);
  put_i32(out + 4, ret == 0 && (e->pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0);
  put_i64(out + 8, ret == 0 ? e->pkt->pts : INT64_MIN);
  put_i64(out + 16, ret == 0 ? e->pkt->dts : INT64_MIN);
  put_i32(out + 24, size);
  if (size > 0)
    memcpy(out + 28, e->pkt->data, size);
  if (ret == 0)
    av_packet_unref(e->pkt);
  return out;
}

// The global-header extradata (avcC when AV_CODEC_FLAG_GLOBAL_HEADER was
// requested; NULL / error otherwise). Valid right after a successful open.
MOONBIT_FFI_EXPORT
moonbit_bytes_t x264enc_extradata(X264Enc *e) {
  if (!e || !e->ctx || e->failed || !e->ctx->extradata ||
      e->ctx->extradata_size <= 0)
    return NULL;
  moonbit_bytes_t out = moonbit_make_bytes(e->ctx->extradata_size, 0);
  if (out)
    memcpy(out, e->ctx->extradata, e->ctx->extradata_size);
  return out;
}

// Explicit release; idempotent, and the external-object finalizer calls the
// same cleanup if the MoonBit side drops the encoder first.
MOONBIT_FFI_EXPORT
void x264enc_close(X264Enc *e) { x264enc_destroy(e); }

// ---- round-trip test support ----------------------------------------------

// Growable frame-plane sink.
typedef struct {
  uint8_t *pay;
  size_t cap, len;
} PlaneSink;

static int sink_planes(PlaneSink *s, const AVFrame *f, int bps) {
  const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(f->format);
  int cw = AV_CEIL_RSHIFT(f->width, desc->log2_chroma_w);
  int ch = AV_CEIL_RSHIFT(f->height, desc->log2_chroma_h);
  const uint8_t *data[3] = {f->data[0], f->data[1], f->data[2]};
  int pl_w[3] = {f->width, cw, cw}, pl_h[3] = {f->height, ch, ch};
  size_t need = s->len;
  for (int p = 0; p < 3; p++)
    need += (size_t)pl_w[p] * pl_h[p] * bps;
  if (need > s->cap) {
    size_t next = s->cap ? s->cap : (1 << 16);
    while (next < need)
      next *= 2;
    uint8_t *grown = realloc(s->pay, next);
    if (!grown)
      return -1;
    s->pay = grown;
    s->cap = next;
  }
  for (int p = 0; p < 3; p++) {
    int row = pl_w[p] * bps;
    for (int r = 0; r < pl_h[p]; r++) {
      memcpy(s->pay + s->len, data[p] + (ptrdiff_t)r * f->linesize[p], row);
      s->len += row;
    }
  }
  return 0;
}

// Decode a whole Annex B H.264 stream with the real FFmpeg decoder (single
// in-band packet, then drain, then flush) and pack every presentation-order
// frame exactly like the pure port's H264Frame::yuvp(): visible area only,
// planar Y/Cb/Cr with little-endian samples. Blob layout (LE):
//   n_frames i32, width i32, height i32, kind i32 (0 = yuv420p, 1 =
//   yuv420p10le, 2 = yuv420p9le, 3/4 = yuv422p/10le,
//   5/6 = yuv444p/10le, 7 = gbrp),
//   color_range i32, colorspace i32, color_primaries i32, color_trc i32,
//   chroma_location i32 (AVCOL_* / AVCHROMA_LOC_* of the first frame),
// then the per-frame planes concatenated.
typedef struct {
  PlaneSink sink;
  AVCodecContext *cc;
  AVFrame *frame;
  int n_frames, width, height, kind;
  int color_range, colorspace, color_primaries, color_trc, chroma_location;
} AnnexbDec;

// Accept one decoded frame: record geometry consistency and append the
// packed planes. Returns 0 ok, -1 failure.
static int annexb_take(AnnexbDec *d) {
  int bps, kind;
  // The deprecated full-range aliases (yuvj*) carry the same plane layout;
  // RGB sources make x264 signal full range, so libx264rgb streams decode
  // as yuvj420p.
  if (d->frame->format == AV_PIX_FMT_YUV420P ||
      d->frame->format == AV_PIX_FMT_YUVJ420P) {
    bps = 1;
    kind = 0;
  } else if (d->frame->format == AV_PIX_FMT_YUV420P10LE) {
    bps = 2;
    kind = 1;
  } else if (d->frame->format == AV_PIX_FMT_YUV420P9LE) {
    bps = 2;
    kind = 2;
  } else if (d->frame->format == AV_PIX_FMT_YUV422P ||
             d->frame->format == AV_PIX_FMT_YUVJ422P) {
    bps = 1;
    kind = 3;
  } else if (d->frame->format == AV_PIX_FMT_YUV422P10LE) {
    bps = 2;
    kind = 4;
  } else if (d->frame->format == AV_PIX_FMT_YUV444P ||
             d->frame->format == AV_PIX_FMT_YUVJ444P) {
    bps = 1;
    kind = 5;
  } else if (d->frame->format == AV_PIX_FMT_YUV444P10LE) {
    bps = 2;
    kind = 6;
  } else if (d->frame->format == AV_PIX_FMT_GBRP) {
    // x264 keeps RGB input in GBR plane order as 4:4:4 (libx264rgb).
    bps = 1;
    kind = 7;
  } else {
    fprintf(stderr, "x264dec: unsupported pix_fmt %d\n", d->frame->format);
    return -1;
  }
  if (d->n_frames == 0) {
    d->width = d->frame->width;
    d->height = d->frame->height;
    d->kind = kind;
    // First-frame VUI-derived colour metadata. A VUI absent from the
    // bitstream leaves these at the decoder's UNSPECIFIED defaults, which
    // is exactly what the range/primaries tests distinguish against.
    d->color_range = d->frame->color_range;
    d->colorspace = d->frame->colorspace;
    d->color_primaries = d->frame->color_primaries;
    d->color_trc = d->frame->color_trc;
    d->chroma_location = d->frame->chroma_location;
  } else if (d->width != d->frame->width || d->height != d->frame->height ||
             d->kind != kind) {
    fprintf(stderr, "x264dec: frame geometry changed\n");
    return -1;
  }
  if (sink_planes(&d->sink, d->frame, bps) < 0)
    return -1;
  d->n_frames++;
  av_frame_unref(d->frame);
  return 0;
}

static int annexb_drain(AnnexbDec *d) {
  for (;;) {
    if (d->n_frames >= 10000)
      return -1;
    int ret = avcodec_receive_frame(d->cc, d->frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
      return 0;
    if (ret < 0) {
      fprintf(stderr, "x264dec: receive_frame: %s\n", av_err2str(ret));
      return -1;
    }
    if (annexb_take(d) < 0)
      return -1;
  }
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t x264dec_annexb(moonbit_bytes_t data) {
  // Defensive ABI boundary: a NULL blob or an oversized packed output must
  // never reach moonbit_make_bytes, whose length is int32_t.
  if (!data)
    return NULL;
  const AVCodec *dec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_H264);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  AVFrame *frame = av_frame_alloc();
  AVPacket *pkt = av_packet_alloc();
  AnnexbDec d = {0};
  d.cc = cc;
  d.frame = frame;
  int failed = !cc || !frame || !pkt || !parser;
  if (!failed && avcodec_open2(cc, dec, NULL) < 0)
    failed = 1;
  // Split the byte stream into access units exactly like the raw H.264
  // demuxer does; the decoder itself only consumes one picture per packet.
  const uint8_t *cur = data;
  size_t left = (size_t)Moonbit_array_length(data);
  while (!failed && left > 0) {
    uint8_t *au;
    int au_size;
    int used = av_parser_parse2(parser, cc, &au, &au_size, cur, (int)left,
                                AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
    if (used < 0 || used > (int)left) {
      failed = 1;
      break;
    }
    cur += used;
    left -= (size_t)used;
    if (au_size > 0) {
      // `au` points into the parser's internal buffer: copy before sending.
      if (av_new_packet(pkt, au_size) < 0) {
        failed = 1;
        break;
      }
      memcpy(pkt->data, au, au_size);
      if (avcodec_send_packet(cc, pkt) < 0) {
        failed = 1;
        break;
      }
      av_packet_unref(pkt);
      if (annexb_drain(&d) < 0) {
        failed = 1;
        break;
      }
    }
  }
  if (!failed) {
    uint8_t *au;
    int au_size;
    av_parser_parse2(parser, cc, &au, &au_size, NULL, 0, AV_NOPTS_VALUE,
                     AV_NOPTS_VALUE, 0);
    if (au_size > 0) {
      if (av_new_packet(pkt, au_size) < 0)
        failed = 1;
      else {
        memcpy(pkt->data, au, au_size);
        if (avcodec_send_packet(cc, pkt) == 0)
          av_packet_unref(pkt);
        if (annexb_drain(&d) < 0)
          failed = 1;
      }
    }
  }
  if (!failed && avcodec_send_packet(cc, NULL) >= 0) {
    if (annexb_drain(&d) < 0)
      failed = 1;
  }

  moonbit_bytes_t out = NULL;
  if (!failed && d.n_frames > 0 && d.sink.len <= (size_t)(INT32_MAX - 36)) {
    out = moonbit_make_bytes((int32_t)(36 + d.sink.len), 0);
    if (out) {
      put_i32(out + 0, d.n_frames);
      put_i32(out + 4, d.width);
      put_i32(out + 8, d.height);
      put_i32(out + 12, d.kind);
      put_i32(out + 16, d.color_range);
      put_i32(out + 20, d.colorspace);
      put_i32(out + 24, d.color_primaries);
      put_i32(out + 28, d.color_trc);
      put_i32(out + 32, d.chroma_location);
      if (d.sink.len > 0)
        memcpy(out + 36, d.sink.pay, d.sink.len);
    }
  }
  free(d.sink.pay);
  av_packet_free(&pkt);
  av_frame_free(&frame);
  if (parser)
    av_parser_close(parser);
  avcodec_free_context(&cc);
  return out;
}

// ---------------------------------------------------------------------------
// Annex B layout / decoder-diagnostic probe (VBV/CBR streams)
// ---------------------------------------------------------------------------
// A second, C-side reader of the stream layout: it inventories NAL unit
// types from the raw start codes, records the access units FFmpeg's H.264
// parser actually split, decodes the stream with the real software decoder,
// and counts WARNING/ERROR diagnostics raised during that decode. The
// returned flat little-endian blob is
//   [n_frames i32][n_warn i32][n_err i32][n_nals i32][n_aus i32]
//   [nal_type u8 x n_nals][au_size i32 x n_aus]
// so the MoonBit side can compare its own NAL walk with the C parser's view
// and assert a warning-free decode without shelling out to the ffmpeg CLI.
//
// av_log's callback is process-global, so the probe installs its counting
// callback only for the duration of one decode and restores the previous
// one on every exit path. Tests using this entry point must be serial.

static int probe_warn, probe_err;
static void (*probe_prev_log)(void *, int, const char *, va_list);

static void probe_log_cb(void *avcl, int level, const char *fmt, va_list vl) {
  if (level <= AV_LOG_ERROR)
    probe_err++;
  else if (level <= AV_LOG_WARNING)
    probe_warn++;
  if (probe_prev_log) {
    va_list dup;
    va_copy(dup, vl);
    probe_prev_log(avcl, level, fmt, dup);
    va_end(dup);
  }
}

typedef struct {
  int32_t *v;
  int n, cap;
} I32Vec;

static int i32vec_push(I32Vec *a, int32_t x) {
  if (a->n == a->cap) {
    int next = a->cap ? a->cap * 2 : 32;
    int32_t *grown = (int32_t *)realloc(a->v, (size_t)next * sizeof(int32_t));
    if (!grown)
      return -1;
    a->v = grown;
    a->cap = next;
  }
  a->v[a->n++] = x;
  return 0;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t x264probe_annexb(moonbit_bytes_t data) {
  if (!data)
    return NULL;
  size_t len = (size_t)Moonbit_array_length(data);
  const uint8_t *buf = (const uint8_t *)data;
  I32Vec nals = {0}, aus = {0};
  int failed = 0, n_frames = 0;
  moonbit_bytes_t out = NULL;

  // Raw NAL inventory: both 3- and 4-byte start codes. Emulation prevention
  // guarantees 00 00 01 never occurs inside an RBSP payload.
  for (size_t i = 0; i + 3 <= len;) {
    int sc = 0;
    if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1)
      sc = 3;
    else if (i + 4 <= len && buf[i] == 0 && buf[i + 1] == 0 &&
             buf[i + 2] == 0 && buf[i + 3] == 1)
      sc = 4;
    if (!sc) {
      i++;
      continue;
    }
    if (i + (size_t)sc >= len)
      break;
    if (i32vec_push(&nals, buf[i + sc] & 0x1F) < 0) {
      failed = 1;
      break;
    }
    i += (size_t)sc + 1;
  }

  const AVCodec *dec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_H264);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  AVFrame *frame = av_frame_alloc();
  AVPacket *pkt = av_packet_alloc();
  if (!cc || !frame || !pkt || !parser)
    failed = 1;

  probe_warn = 0;
  probe_err = 0;
  // FFmpeg n9.0.2 has no av_log_get_callback() accessor (it was added in a
  // later libavutil), and nothing else in this binding installs a custom
  // callback, so the previous callback is the default one. Restore it on
  // every exit path below.
  probe_prev_log = av_log_default_callback;
  av_log_set_callback(probe_log_cb);

  if (!failed && avcodec_open2(cc, dec, NULL) < 0)
    failed = 1;

  if (!failed) {
    const uint8_t *cur = buf;
    size_t left = len;
    while (left > 0) {
      uint8_t *au;
      int au_size;
      int used = av_parser_parse2(parser, cc, &au, &au_size, cur, (int)left,
                                  AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
      if (used < 0 || used > (int)left) {
        failed = 1;
        break;
      }
      cur += used;
      left -= (size_t)used;
      if (au_size > 0) {
        if (i32vec_push(&aus, au_size) < 0 || av_new_packet(pkt, au_size) < 0) {
          failed = 1;
          break;
        }
        memcpy(pkt->data, au, au_size);
        if (avcodec_send_packet(cc, pkt) < 0) {
          failed = 1;
          break;
        }
        av_packet_unref(pkt);
        for (;;) {
          int ret = avcodec_receive_frame(cc, frame);
          if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            break;
          if (ret < 0) {
            failed = 1;
            break;
          }
          n_frames++;
          av_frame_unref(frame);
        }
        if (failed)
          break;
      }
    }
  }
  if (!failed) {
    uint8_t *au;
    int au_size;
    av_parser_parse2(parser, cc, &au, &au_size, NULL, 0, AV_NOPTS_VALUE,
                     AV_NOPTS_VALUE, 0);
    if (au_size > 0 && av_new_packet(pkt, au_size) == 0) {
      memcpy(pkt->data, au, au_size);
      if (avcodec_send_packet(cc, pkt) == 0) {
        av_packet_unref(pkt);
        if (i32vec_push(&aus, au_size) < 0)
          failed = 1;
        for (;;) {
          int ret = avcodec_receive_frame(cc, frame);
          if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            break;
          if (ret < 0) {
            failed = 1;
            break;
          }
          n_frames++;
          av_frame_unref(frame);
        }
      }
    }
  }
  if (!failed && avcodec_send_packet(cc, NULL) >= 0) {
    for (;;) {
      int ret = avcodec_receive_frame(cc, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
        break;
      if (ret < 0) {
        failed = 1;
        break;
      }
      n_frames++;
      av_frame_unref(frame);
    }
  }
  av_log_set_callback(probe_prev_log);

  if (!failed) {
    size_t total = 20 + (size_t)nals.n + 4 * (size_t)aus.n;
    if (total <= (size_t)(INT32_MAX - 1)) {
      out = moonbit_make_bytes((int32_t)total, 0);
      if (out) {
        put_i32(out + 0, n_frames);
        put_i32(out + 4, probe_warn);
        put_i32(out + 8, probe_err);
        put_i32(out + 12, nals.n);
        put_i32(out + 16, aus.n);
        for (int k = 0; k < nals.n; k++)
          out[20 + k] = (uint8_t)nals.v[k];
        for (int k = 0; k < aus.n; k++)
          put_i32(out + 20 + nals.n + 4 * k, aus.v[k]);
      }
    }
  }
  free(nals.v);
  free(aus.v);
  av_packet_free(&pkt);
  av_frame_free(&frame);
  if (parser)
    av_parser_close(parser);
  avcodec_free_context(&cc);
  return out;
}

// ---------------------------------------------------------------------------
// Frame-level arbitration probe (§403): decode an Annex B stream with the
// real FFmpeg H.264 decoder and report, per output picture, its picture
// type / key-frame and display-order metadata plus a stable FNV-1a digest
// of the visible-area planes. A pure-MoonBit B-slice stream can then be
// checked by an independent decoder for frame reordering and zero
// diagnostics without shelling out to the ffmpeg CLI.
//
// Blob layout (all little-endian int32):
//   [n_frames][warnings][errors][width][height][pix_fmt][8][0]
//   then n_frames * 8 records:
//   [pict_type][key_flag][flags][decode_error_flags]
//   [pts_lo][pts_hi][digest_lo][digest_hi]
// FFmpeg n9.0.2 removed AVFrame.key_frame / coded_picture_number /
// display_picture_number; the key flag lives in AV_FRAME_FLAG_KEY.
// ---------------------------------------------------------------------------

#define PROBE_FRAME_FIELDS 8

static uint64_t probe_frame_fnv(const AVFrame *f) {
  uint64_t h = 14695981039346656037ULL;
  enum AVPixelFormat fmt = (enum AVPixelFormat)f->format;
  const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(fmt);
  int planes = av_pix_fmt_count_planes(fmt);
  int hs = desc ? desc->log2_chroma_h : 1;
  int ws = desc ? desc->log2_chroma_w : 1;
  int bps = desc && desc->comp[0].depth > 8 ? 2 : 1;
  if (planes < 1 || planes > 4)
    return h;
  for (int p = 0; p < planes; p++) {
    int pw = p == 0 ? f->width : AV_CEIL_RSHIFT(f->width, ws);
    int ph = p == 0 ? f->height : AV_CEIL_RSHIFT(f->height, hs);
    if (!f->data[p])
      continue;
    for (int y = 0; y < ph; y++) {
      const uint8_t *row = f->data[p] + (size_t)y * f->linesize[p];
      for (int x = 0; x < pw * bps; x++) {
        h ^= row[x];
        h *= 1099511628211ULL;
      }
    }
  }
  return h;
}

static void probe_push_frame(I32Vec *v, const AVFrame *f, int *failed) {
  uint64_t digest = probe_frame_fnv(f);
  uint64_t pts = (uint64_t)f->pts;
  int32_t rec[PROBE_FRAME_FIELDS] = {
      (int32_t)f->pict_type,
      (f->flags & AV_FRAME_FLAG_KEY) ? 1 : 0,
      (int32_t)f->flags,
      (int32_t)f->decode_error_flags,
      (int32_t)(uint32_t)pts,
      (int32_t)(uint32_t)(pts >> 32),
      (int32_t)(uint32_t)digest,
      (int32_t)(uint32_t)(digest >> 32),
  };
  for (int i = 0; i < PROBE_FRAME_FIELDS; i++)
    if (i32vec_push(v, rec[i]) < 0)
      *failed = 1;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t x264probe_frames(moonbit_bytes_t data) {
  if (!data)
    return NULL;
  size_t len = (size_t)Moonbit_array_length(data);
  const uint8_t *buf = (const uint8_t *)data;
  I32Vec recs = {0};
  int failed = 0, n_frames = 0;
  int width = 0, height = 0, pix_fmt = -1;
  moonbit_bytes_t out = NULL;

  const AVCodec *dec = avcodec_find_decoder(AV_CODEC_ID_H264);
  AVCodecParserContext *parser = av_parser_init(AV_CODEC_ID_H264);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  AVFrame *frame = av_frame_alloc();
  AVPacket *pkt = av_packet_alloc();
  if (!cc || !frame || !pkt || !parser)
    failed = 1;

  probe_warn = 0;
  probe_err = 0;
  // av_log's callback is process-global: restore the default on every
  // exit path. Tests using either probe must be serial (see §391).
  probe_prev_log = av_log_default_callback;
  av_log_set_callback(probe_log_cb);

  if (!failed && avcodec_open2(cc, dec, NULL) < 0)
    failed = 1;

  if (!failed) {
    const uint8_t *cur = buf;
    size_t left = len;
    while (left > 0) {
      uint8_t *au;
      int au_size;
      int used = av_parser_parse2(parser, cc, &au, &au_size, cur, (int)left,
                                  AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
      if (used < 0 || used > (int)left) {
        failed = 1;
        break;
      }
      cur += used;
      left -= (size_t)used;
      if (au_size > 0) {
        if (av_new_packet(pkt, au_size) < 0) {
          failed = 1;
          break;
        }
        memcpy(pkt->data, au, au_size);
        if (avcodec_send_packet(cc, pkt) < 0) {
          av_packet_unref(pkt);
          failed = 1;
          break;
        }
        av_packet_unref(pkt);
        for (;;) {
          int ret = avcodec_receive_frame(cc, frame);
          if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            break;
          if (ret < 0) {
            failed = 1;
            break;
          }
          if (n_frames == 0) {
            width = frame->width;
            height = frame->height;
            pix_fmt = frame->format;
          }
          probe_push_frame(&recs, frame, &failed);
          n_frames++;
          av_frame_unref(frame);
          if (failed)
            break;
        }
      }
      if (failed)
        break;
    }
  }
  if (!failed) {
    uint8_t *au;
    int au_size;
    av_parser_parse2(parser, cc, &au, &au_size, NULL, 0, AV_NOPTS_VALUE,
                     AV_NOPTS_VALUE, 0);
    if (au_size > 0 && av_new_packet(pkt, au_size) == 0) {
      memcpy(pkt->data, au, au_size);
      if (avcodec_send_packet(cc, pkt) == 0) {
        av_packet_unref(pkt);
        for (;;) {
          int ret = avcodec_receive_frame(cc, frame);
          if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            break;
          if (ret < 0) {
            failed = 1;
            break;
          }
          if (n_frames == 0) {
            width = frame->width;
            height = frame->height;
            pix_fmt = frame->format;
          }
          probe_push_frame(&recs, frame, &failed);
          n_frames++;
          av_frame_unref(frame);
          if (failed)
            break;
        }
      } else {
        av_packet_unref(pkt);
      }
    }
  }
  if (!failed && avcodec_send_packet(cc, NULL) >= 0) {
    for (;;) {
      int ret = avcodec_receive_frame(cc, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
        break;
      if (ret < 0) {
        failed = 1;
        break;
      }
      if (n_frames == 0) {
        width = frame->width;
        height = frame->height;
        pix_fmt = frame->format;
      }
      probe_push_frame(&recs, frame, &failed);
      n_frames++;
      av_frame_unref(frame);
      if (failed)
        break;
    }
  }
  av_log_set_callback(probe_prev_log);

  if (!failed && recs.n == n_frames * PROBE_FRAME_FIELDS) {
    size_t total = 32 + 4 * (size_t)recs.n;
    if (total <= (size_t)(INT32_MAX - 1)) {
      out = moonbit_make_bytes((int32_t)total, 0);
      if (out) {
        put_i32(out + 0, n_frames);
        put_i32(out + 4, probe_warn);
        put_i32(out + 8, probe_err);
        put_i32(out + 12, width);
        put_i32(out + 16, height);
        put_i32(out + 20, pix_fmt);
        put_i32(out + 24, PROBE_FRAME_FIELDS);
        put_i32(out + 28, 0);
        for (int k = 0; k < recs.n; k++)
          put_i32(out + 32 + 4 * k, recs.v[k]);
      }
    }
  }
  free(recs.v);
  av_packet_free(&pkt);
  av_frame_free(&frame);
  if (parser)
    av_parser_close(parser);
  avcodec_free_context(&cc);
  return out;
}

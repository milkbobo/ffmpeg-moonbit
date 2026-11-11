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
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/frame.h"
#include "libavutil/log.h"
#include "libavutil/opt.h"
#include "libavutil/pixfmt.h"

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
  int bps; // bytes per luma sample: 1 for yuv420p, 2 for yuv420p10le
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
// 0 = yuv420p, 1 = yuv420p10le.
static int sel_pix_fmt(int sel, enum AVPixelFormat *out) {
  switch (sel) {
  case 0:
    *out = AV_PIX_FMT_YUV420P;
    return 0;
  case 1:
    *out = AV_PIX_FMT_YUV420P10LE;
    return 0;
  default:
    return -1;
  }
}

// flags: bit0 = AV_CODEC_FLAG_GLOBAL_HEADER, bit1 = AV_CODEC_FLAG_BITEXACT.
// `options` is a "key=value:key=value" list applied through avcodec_open2's
// dictionary (ctx options first, then the codec's private options: preset,
// tune, profile, crf, g, bf, ...). `rc_max_rate` / `rc_buffer_size` map onto
// libx264's VBV fields, which `nal-hrd=cbr` requires; zero leaves the
// existing flat/CRF configurations untouched. Always returns a handle; on
// failure it is a failed-open handle carrying the message (see
// `x264enc_status`).
MOONBIT_FFI_EXPORT
X264Enc *x264enc_open(moonbit_bytes_t codec_name, int32_t width, int32_t height,
                      int32_t pix_sel, int32_t tb_num, int32_t tb_den,
                      int32_t fps_num, int32_t fps_den, int32_t bit_rate,
                      int32_t flags, int32_t rc_max_rate,
                      int32_t rc_buffer_size, moonbit_bytes_t options) {
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
  // through the wrapped context (rather than x264-params, whose colons
  // collide with av_dict_parse_string's pair separator) is what makes
  // `nal-hrd=cbr` produce a real CBR HRD stream.
  if (rc_max_rate > 0)
    cc->rc_max_rate = rc_max_rate;
  if (rc_buffer_size > 0)
    cc->rc_buffer_size = rc_buffer_size;
  if (flags & 1)
    cc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  if (flags & 2)
    cc->flags |= AV_CODEC_FLAG_BITEXACT;
  cc->thread_count = 1; // deterministic output: no frame/slice threading
  AVDictionary *dict = NULL;
  if (Moonbit_array_length(options) > 0 &&
      av_dict_parse_string(&dict, (const char *)options, "=", ":", 0) < 0) {
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
  e->bps = pix_sel == 1 ? 2 : 1;
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

// Copy tightly-packed planes (y then u then v, row-major, `bps` bytes per
// sample) into a fresh AVFrame buffer and push it. Returns 0 ok, 1 EAGAIN,
// -1 error. Plane lengths are validated against the opened geometry.
MOONBIT_FFI_EXPORT
int32_t x264enc_send_frame(X264Enc *e, int64_t pts, moonbit_bytes_t y,
                           moonbit_bytes_t u, moonbit_bytes_t v) {
  if (!e || !e->ctx || e->failed)
    return -1;
  int w = e->ctx->width, h = e->ctx->height;
  int cw = (w + 1) / 2, ch = (h + 1) / 2, bps = e->bps;
  int64_t need_y = (int64_t)w * h * bps, need_c = (int64_t)cw * ch * bps;
  if ((int64_t)Moonbit_array_length(y) != need_y ||
      (int64_t)Moonbit_array_length(u) != need_c ||
      (int64_t)Moonbit_array_length(v) != need_c) {
    fprintf(stderr,
            "x264enc: plane size mismatch (y=%d want %lld, u=%d want %lld, "
            "v=%d)\n",
            Moonbit_array_length(y), (long long)need_y,
            Moonbit_array_length(u), (long long)need_c,
            Moonbit_array_length(v));
    return -1;
  }
  AVFrame *f = e->frame;
  av_frame_unref(f);
  f->format = e->ctx->pix_fmt;
  f->width = w;
  f->height = h;
  f->pts = pts;
  if (av_frame_get_buffer(f, 0) < 0)
    return -1;
  const uint8_t *srcs[3] = {y, u, v};
  int pl_w[3] = {w, cw, cw}, pl_h[3] = {h, ch, ch};
  for (int p = 0; p < 3; p++) {
    int row = pl_w[p] * bps;
    for (int r = 0; r < pl_h[p]; r++)
      memcpy(f->data[p] + (ptrdiff_t)r * f->linesize[p],
             srcs[p] + (ptrdiff_t)r * row, row);
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

// Enter drain mode. Returns 0 ok, 1 EAGAIN, -1 error.
MOONBIT_FFI_EXPORT
int32_t x264enc_send_eof(X264Enc *e) {
  if (!e || !e->ctx || e->failed)
    return -1;
  int ret = avcodec_send_frame(e->ctx, NULL);
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
  int cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
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
//   yuv420p10le), then the per-frame planes concatenated.
typedef struct {
  PlaneSink sink;
  AVCodecContext *cc;
  AVFrame *frame;
  int n_frames, width, height, kind;
} AnnexbDec;

// Accept one decoded frame: record geometry consistency and append the
// packed planes. Returns 0 ok, -1 failure.
static int annexb_take(AnnexbDec *d) {
  int bps, kind;
  if (d->frame->format == AV_PIX_FMT_YUV420P) {
    bps = 1;
    kind = 0;
  } else if (d->frame->format == AV_PIX_FMT_YUV420P10LE) {
    bps = 2;
    kind = 1;
  } else {
    fprintf(stderr, "x264dec: unsupported pix_fmt %d\n", d->frame->format);
    return -1;
  }
  if (d->n_frames == 0) {
    d->width = d->frame->width;
    d->height = d->frame->height;
    d->kind = kind;
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
  if (!failed && d.n_frames > 0 && d.sink.len <= (size_t)(INT32_MAX - 16)) {
    out = moonbit_make_bytes((int32_t)(16 + d.sink.len), 0);
    if (out) {
      put_i32(out + 0, d.n_frames);
      put_i32(out + 4, d.width);
      put_i32(out + 8, d.height);
      put_i32(out + 12, d.kind);
      if (d.sink.len > 0)
        memcpy(out + 16, d.sink.pay, d.sink.len);
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

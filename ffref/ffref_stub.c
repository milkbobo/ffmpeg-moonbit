// Reference-oracle bindings over the locally built FFmpeg n9.0.2 static
// libraries. The MoonBit demux/decode ports are differential-tested against
// this in-process oracle instead of docker ffprobe round-trips. Only the C
// ABI surface lives here; everything MoonBit-visible is wrapped safely in
// ffref.mbt.
//
// Every entry point returns a flat little-endian record blob as MoonBit
// Bytes (value-as-bytes pattern; no handles, no finalizers) or NULL on
// failure - the MoonBit side turns NULL into an error.

#include "moonbit.h"

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswresample/swresample.h"
#include "libavutil/cpu.h"
#include "libavutil/dict.h"
#include "libavutil/opt.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>

// Internal, pinned n9.0.2 oracle symbol from libavformat/url.h. This is not
// part of the portable MoonBit implementation or a public FFmpeg ABI promise.
extern int ff_make_absolute_url2(char *, int, const char *, const char *, int);

MOONBIT_FFI_EXPORT moonbit_bytes_t ffref_resolve_uri(moonbit_bytes_t base,
                                                    moonbit_bytes_t rel) {
  size_t a = Moonbit_array_length(base), b = Moonbit_array_length(rel);
  if (memchr(base, 0, a) || memchr(rel, 0, b) ||
      a > INT_MAX - 2 || b > INT_MAX - 2 - a)
    return NULL;
  int capacity = (int)(a + b + 2);
  char *out = malloc(capacity);
  if (!out) return NULL;
  int status = ff_make_absolute_url2(out, capacity, (const char *)base,
                                    (const char *)rel, 0);
  moonbit_bytes_t result = NULL;
  if (status >= 0) {
    size_t length = strlen(out);
    result = moonbit_make_bytes((int)length, 0);
    memcpy(result, out, length);
  }
  free(out);
  return result;
}

#define NA INT64_MIN

typedef struct {
  const uint8_t *data;
  int64_t pos;
  int64_t len;
} MemIO;

static int mem_read(void *opaque, uint8_t *buf, int buf_size) {
  MemIO *io = (MemIO *)opaque;
  int64_t left = io->len - io->pos;
  if (left <= 0)
    return AVERROR_EOF;
  int n = buf_size < left ? buf_size : (int)left;
  memcpy(buf, io->data + io->pos, n);
  io->pos += n;
  return n;
}

static int64_t mem_seek(void *opaque, int64_t offset, int whence) {
  MemIO *io = (MemIO *)opaque;
  if (whence == AVSEEK_SIZE)
    return io->len;
  if (whence == SEEK_CUR)
    offset += io->pos;
  else if (whence == SEEK_END)
    offset += io->len;
  if (offset < 0 || offset > io->len)
    return AVERROR(EIO);
  io->pos = offset;
  return io->pos;
}

// Open `data` through the real libavformat demuxer. Returns 0 on success.
static int open_input(moonbit_bytes_t data, AVFormatContext **out_fmt,
                      AVIOContext **out_avio) {
  // Heap-allocated: the AVIOContext (and thus the read/seek callbacks)
  // outlives this frame, so the callback state must not live on the stack
  // (a stack MemIO dangles once open_input returns and demuxers that seek
  // across phases then read through freed memory).
  MemIO *io = malloc(sizeof(MemIO));
  if (!io)
    return AVERROR(ENOMEM);
  io->data = data;
  io->pos = 0;
  io->len = (int64_t)Moonbit_array_length(data);
  int bufsize = 1 << 16;
  uint8_t *avbuf = av_malloc(bufsize);
  if (!avbuf)
    return AVERROR(ENOMEM);
  AVIOContext *avio =
      avio_alloc_context(avbuf, bufsize, 0, io, mem_read, NULL, mem_seek);
  if (!avio) {
    av_free(avbuf);
    free(io);
    return AVERROR(ENOMEM);
  }
  AVFormatContext *fmt = avformat_alloc_context();
  if (!fmt) {
    avio_context_free(&avio);
    free(io);
    return AVERROR(ENOMEM);
  }
  fmt->pb = avio;
  fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
  // Matroska and a few other demuxers refuse to probe on a non-seekable
  // AVIO context; the memory backend is fully seekable.
  avio->seekable |= AVIO_SEEKABLE_NORMAL;
  int ret = avformat_open_input(&fmt, NULL, NULL, NULL);
  if (ret < 0) {
    fprintf(stderr, "ffref: open_input avformat_open_input %s\n",
            av_err2str(ret));
    // On failure avformat_open_input frees the context itself.
    avio_context_free(&avio);
    free(io);
    return ret;
  }
  ret = avformat_find_stream_info(fmt, NULL);
  if (ret < 0) {
    fprintf(stderr, "ffref: open_input find_stream_info %s\n",
            av_err2str(ret));
    avformat_close_input(&fmt);
    avio_context_free(&avio);
    free(io);
    return ret;
  }
  *out_fmt = fmt;
  *out_avio = avio;
  return 0;
}

static void close_input(AVFormatContext *fmt, AVIOContext *avio) {
  MemIO *io = avio ? (MemIO *)avio->opaque : NULL;
  avformat_close_input(&fmt);
  avio_context_free(&avio);
  free(io);
}

static void put_i32(uint8_t *p, int32_t v) {
  memcpy(p, &v, 4);
}

static void put_i64(uint8_t *p, int64_t v) {
  memcpy(p, &v, 8);
}

MOONBIT_FFI_EXPORT
int32_t ffref_avformat_version(void) {
  return (int32_t)avformat_version();
}

// Blob layout (little-endian):
//   n_streams i32, n_packets i32
//   per stream: tb_num i32, tb_den i32
//   per packet: stream_index i32, keyframe i32, pts_us i64, dts_us i64,
//               size i32, unused i32
// pts/dts are AV_TIME_BASE microseconds; NA (INT64_MIN) marks N/A.

// Walk every packet of an open AVFormatContext into the probe blob above.
// Shared by the memory-backed ffref_packets and the path-backed
// ffref_probe_path; the caller owns the context and closes it.
static moonbit_bytes_t probe_common(AVFormatContext *fmt) {
  const int nstreams = (int)fmt->nb_streams;
  size_t cap = 64, n = 0;
  uint8_t *recs = malloc(cap * 32);
  int failed = recs == NULL;
  AVPacket *pkt = failed ? NULL : av_packet_alloc();
  while (!failed && av_read_frame(fmt, pkt) >= 0) {
    if (n == cap) {
      cap *= 2;
      uint8_t *grown = realloc(recs, cap * 32);
      if (!grown) {
        failed = 1;
        break;
      }
      recs = grown;
    }
    uint8_t *r = recs + n * 32;
    AVStream *st = fmt->streams[pkt->stream_index];
    int64_t pts = pkt->pts == AV_NOPTS_VALUE
                      ? NA
                      : av_rescale_q(pkt->pts, st->time_base, AV_TIME_BASE_Q);
    int64_t dts = pkt->dts == AV_NOPTS_VALUE
                      ? NA
                      : av_rescale_q(pkt->dts, st->time_base, AV_TIME_BASE_Q);
    put_i32(r + 0, pkt->stream_index);
    put_i32(r + 4, (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0);
    put_i64(r + 8, pts);
    put_i64(r + 16, dts);
    put_i32(r + 24, pkt->size);
    put_i32(r + 28, 0);
    n++;
    av_packet_unref(pkt);
  }
  av_packet_free(&pkt);

  moonbit_bytes_t out = NULL;
  if (!failed) {
    int32_t blob_len = (int32_t)(8 + (size_t)nstreams * 8 + n * 32);
    out = moonbit_make_bytes(blob_len, 0);
    if (out) {
      put_i32(out + 0, nstreams);
      put_i32(out + 4, (int32_t)n);
      for (int i = 0; i < nstreams; i++) {
        AVRational tb = fmt->streams[i]->time_base;
        put_i32(out + 8 + i * 8, tb.num);
        put_i32(out + 8 + i * 8 + 4, tb.den);
      }
      if (n > 0)
        memcpy(out + 8 + (size_t)nstreams * 8, recs, n * 32);
    }
  }
  free(recs);
  return out;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_packets(moonbit_bytes_t data) {
  AVFormatContext *fmt = NULL;
  AVIOContext *avio = NULL;
  if (open_input(data, &fmt, &avio) < 0)
    return NULL;
  moonbit_bytes_t out = probe_common(fmt);
  close_input(fmt, avio);
  return out;
}

// Same packet view as ffref_packets, but opened from a filesystem path so
// multi-file demuxers (hls, dash) can follow their own playlists and
// segment files the way a real player would. Pair with ffref_write_file:
// tests stage their fixtures under /tmp and hand the manifest path over.
MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_probe_path(moonbit_bytes_t path) {
  AVFormatContext *fmt = avformat_alloc_context();
  if (!fmt)
    return NULL;
  int ret = avformat_open_input(&fmt, (const char *)path, NULL, NULL);
  if (ret < 0) {
    fprintf(stderr, "ffref: probe_path avformat_open_input(%s) %s\n",
            (const char *)path, av_err2str(ret));
    return NULL; // avformat_open_input freed the context on failure
  }
  ret = avformat_find_stream_info(fmt, NULL);
  if (ret < 0) {
    fprintf(stderr, "ffref: probe_path find_stream_info %s\n",
            av_err2str(ret));
    avformat_close_input(&fmt);
    return NULL;
  }
  moonbit_bytes_t out = probe_common(fmt);
  avformat_close_input(&fmt);
  return out;
}

// Stage `data` at `path`, creating parent directories as needed. This is
// fixture staging for the path-backed oracle above, not a general file API:
// returns 0 on success, -1 on any failure.
MOONBIT_FFI_EXPORT
int32_t ffref_write_file(moonbit_bytes_t path, moonbit_bytes_t data) {
  const char *p = (const char *)path;
  size_t len = strlen(p);
  char *buf = malloc(len + 1);
  if (!buf)
    return -1;
  memcpy(buf, p, len + 1);
  for (size_t i = 1; i < len; i++) {
    if (buf[i] == '/') {
      buf[i] = 0;
      mkdir(buf, 0755); // EEXIST (or race) is fine, anything else fails fopen
      buf[i] = '/';
    }
  }
  free(buf);
  FILE *f = fopen(p, "wb");
  if (!f) {
    fprintf(stderr, "ffref: write_file fopen(%s) failed\n", p);
    return -1;
  }
  size_t n = (size_t)Moonbit_array_length(data);
  int ok = n == 0 || fwrite(data, 1, n, f) == n;
  ok = (fclose(f) == 0) && ok;
  return ok ? 0 : -1;
}

// Blob layout (little-endian):
//   sample_rate i32, channels i32, samples_per_channel i32
//   then interleaved s16le PCM
// Decodes the first audio stream with the real libavcodec decoder and
// converts through swresample to packed s16 at the stream's native rate
// (no dither), which is exactly what the MoonBit float pipeline should
// reproduce within rounding.
MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_decode_audio(moonbit_bytes_t data) {
  AVFormatContext *fmt = NULL;
  AVIOContext *avio = NULL;
  if (open_input(data, &fmt, &avio) < 0)
    return NULL;

  int aidx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  if (aidx < 0) {
    fprintf(stderr, "ffref: decode_audio no audio stream\n");
    close_input(fmt, avio);
    return NULL;
  }
  AVStream *st = fmt->streams[aidx];
  // The MoonBit MP3 port follows the fixed-point path (USE_FLOATS=0). FFmpeg
  // registers that decoder as "mp3"; the codec-id default is "mp3float"
  // (listed first in allcodecs.c), so the fixed twin is picked by name.
  const AVCodec *dec = st->codecpar->codec_id == AV_CODEC_ID_MP3
                           ? avcodec_find_decoder_by_name("mp3")
                           : avcodec_find_decoder(st->codecpar->codec_id);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  if (!cc || avcodec_parameters_to_context(cc, st->codecpar) < 0 ||
      avcodec_open2(cc, dec, NULL) < 0) {
    fprintf(stderr, "ffref: decode_audio codec open failed\n");
    avcodec_free_context(&cc);
    close_input(fmt, avio);
    return NULL;
  }

  AVChannelLayout out_layout;
  av_channel_layout_default(&out_layout, cc->ch_layout.nb_channels);
  SwrContext *swr = NULL;
  if (swr_alloc_set_opts2(&swr, &out_layout, AV_SAMPLE_FMT_S16,
                          cc->sample_rate, &cc->ch_layout, cc->sample_fmt,
                          cc->sample_rate, 0, NULL) < 0 ||
      swr_init(swr) < 0) {
    fprintf(stderr, "ffref: decode_audio swr setup failed\n");
    av_channel_layout_uninit(&out_layout);
    swr_free(&swr);
    avcodec_free_context(&cc);
    close_input(fmt, avio);
    return NULL;
  }

  size_t pcm_cap = 1 << 16, pcm_len = 0; // bytes
  uint8_t *pcm = malloc(pcm_cap);
  int failed = pcm == NULL;
  int64_t samples = 0;
  AVPacket *pkt = failed ? NULL : av_packet_alloc();
  AVFrame *frame = failed ? NULL : av_frame_alloc();
  while (!failed && av_read_frame(fmt, pkt) >= 0) {
    if (pkt->stream_index != aidx) {
      av_packet_unref(pkt);
      continue;
    }
    // Lenient like the ffmpeg CLI: a packet that trips the decoder (e.g.
    // RAW-AAC-in-WAV packets the parser cut at accidental sync words) is
    // skipped, not fatal.
    if (avcodec_send_packet(cc, pkt) < 0) {
      fprintf(stderr, "ffref: decode_audio send_packet failed, skipping\n");
      av_packet_unref(pkt);
      continue;
    }
    av_packet_unref(pkt);
    for (;;) {
      int ret = avcodec_receive_frame(cc, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
        break;
      if (ret < 0) {
        fprintf(stderr, "ffref: decode_audio receive_frame %d, continuing\n",
                ret);
        break;
      }
      int per_frame = frame->nb_samples * cc->ch_layout.nb_channels;
      size_t need = pcm_len + (size_t)per_frame * 2 + 4096;
      if (need > pcm_cap) {
        size_t next = pcm_cap;
        while (next < need)
          next *= 2;
        uint8_t *grown = realloc(pcm, next);
        if (!grown) {
          failed = 1;
          break;
        }
        pcm = grown;
        pcm_cap = next;
      }
      uint8_t *dst = pcm + pcm_len;
      uint8_t *pp[1] = { dst };
      int got = swr_convert(swr, pp, frame->nb_samples,
                            (const uint8_t **)frame->extended_data,
                            frame->nb_samples);
      av_frame_unref(frame);
      if (got < 0) {
        failed = 1;
        break;
      }
      pcm_len += (size_t)got * cc->ch_layout.nb_channels * 2;
      samples += got;
    }
    if (failed)
      break;
  }
  // Drain the decoder.
  if (!failed) {
    avcodec_send_packet(cc, NULL);
    for (;;) {
      int ret = avcodec_receive_frame(cc, frame);
      if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
        break;
      if (ret < 0) {
        failed = 1;
        break;
      }
      size_t need = pcm_len + (size_t)frame->nb_samples *
                                  cc->ch_layout.nb_channels * 2 + 4096;
      if (need > pcm_cap) {
        size_t next = pcm_cap;
        while (next < need)
          next *= 2;
        uint8_t *grown = realloc(pcm, next);
        if (!grown) {
          failed = 1;
          break;
        }
        pcm = grown;
        pcm_cap = next;
      }
      uint8_t *dst = pcm + pcm_len;
      uint8_t *pp[1] = { dst };
      int got = swr_convert(swr, pp, frame->nb_samples,
                            (const uint8_t **)frame->extended_data,
                            frame->nb_samples);
      av_frame_unref(frame);
      if (got < 0) {
        failed = 1;
        break;
      }
      pcm_len += (size_t)got * cc->ch_layout.nb_channels * 2;
      samples += got;
    }
  }

  moonbit_bytes_t out = NULL;
  if (!failed) {
    out = moonbit_make_bytes((int32_t)(12 + pcm_len), 0);
    if (out) {
      put_i32(out + 0, cc->sample_rate);
      put_i32(out + 4, cc->ch_layout.nb_channels);
      put_i32(out + 8, (int32_t)(samples > 0x7fffffff ? 0x7fffffff : samples));
      if (pcm_len > 0)
        memcpy(out + 12, pcm, pcm_len);
    }
  }
  av_frame_free(&frame);
  av_packet_free(&pkt);
  free(pcm);
  swr_free(&swr);
  av_channel_layout_uninit(&out_layout);
  avcodec_free_context(&cc);
  close_input(fmt, avio);
  return out;
}

// ---- video oracle ---------------------------------------------------------

// Map a pixel format to its frame kind: 0 = planar 4:2:0, 1 = planar 4:2:2,
// 2 = planar 4:4:4, 3 = packed rgb24, 4 = packed rgba, 5 = gray8;
// -1 for anything else (high bit depth, other packed layouts...).
// Full-range legacy variants (yuvj420p and friends) map the same way -
// their plane layout is identical, which is all byte-level differential
// testing needs.
static int frame_kind(int format) {
  switch (format) {
  case AV_PIX_FMT_YUV420P:
  case AV_PIX_FMT_YUVJ420P:
    return 0;
  case AV_PIX_FMT_YUV422P:
  case AV_PIX_FMT_YUVJ422P:
    return 1;
  case AV_PIX_FMT_YUV444P:
  case AV_PIX_FMT_YUVJ444P:
    return 2;
  case AV_PIX_FMT_RGB24:
    return 3;
  case AV_PIX_FMT_RGBA:
    return 4;
  case AV_PIX_FMT_GRAY8:
    return 5;
  default:
    return -1;
  }
}

// Chroma plane dimensions for a planar chroma mode.
static void chroma_dims(int mode, int w, int h, int *cw, int *ch) {
  if (mode == 0) {
    *cw = (w + 1) / 2;
    *ch = (h + 1) / 2;
  } else if (mode == 1) {
    *cw = (w + 1) / 2;
    *ch = h;
  } else {
    *cw = w;
    *ch = h;
  }
}

// Bytes per pixel for the packed kinds.
static int packed_bpp(int kind) { return kind == 3 ? 3 : 4; }

// Append one decoded frame as compact bytes to *buf (growing it as needed).
// Planar YUV kinds pack Y, then Cb, then Cr; rgb24/rgba pack rows of
// w*bpp; gray8 packs the single plane. Returns 0 on success; the first
// frame fixes the geometry.
static int append_frame(uint8_t **buf, size_t *cap, size_t *len,
                        AVFrame *frame, int *out_kind, int *out_w,
                        int *out_h) {
  int kind = frame_kind(frame->format);
  if (kind < 0 || frame->width <= 0 || frame->height <= 0 ||
      frame->width > 8192 || frame->height > 8192) {
    return -1;
  }
  if (*len == 0) {
    *out_kind = kind;
    *out_w = frame->width;
    *out_h = frame->height;
  } else if (frame->width != *out_w || frame->height != *out_h ||
             kind != *out_kind) {
    return -1; // geometry changes are out of scope
  }
  int w = frame->width, h = frame->height, cw, ch;
  size_t frame_len;
  if (kind <= 2) {
    chroma_dims(kind, w, h, &cw, &ch);
    frame_len = (size_t)w * h + 2 * (size_t)cw * ch;
  } else if (kind <= 4) {
    frame_len = (size_t)w * h * packed_bpp(kind);
  } else {
    frame_len = (size_t)w * h;
  }
  size_t need = *len + frame_len + 4096;
  if (need > *cap) {
    size_t next = *cap;
    while (next < need)
      next *= 2;
    uint8_t *grown = realloc(*buf, next);
    if (!grown)
      return -1;
    *buf = grown;
    *cap = next;
  }
  uint8_t *dst = *buf + *len;
  if (kind <= 2) {
    for (int row = 0; row < h; row++)
      memcpy(dst + (size_t)row * w,
             frame->data[0] + (size_t)row * frame->linesize[0], w);
    dst += (size_t)w * h;
    for (int row = 0; row < ch; row++)
      memcpy(dst + (size_t)row * cw,
             frame->data[1] + (size_t)row * frame->linesize[1], cw);
    dst += (size_t)cw * ch;
    for (int row = 0; row < ch; row++)
      memcpy(dst + (size_t)row * cw,
             frame->data[2] + (size_t)row * frame->linesize[2], cw);
  } else if (kind <= 4) {
    int bpp = packed_bpp(kind);
    size_t row_bytes = (size_t)w * bpp;
    for (int row = 0; row < h; row++)
      memcpy(dst + (size_t)row * row_bytes,
             frame->data[0] + (size_t)row * frame->linesize[0], row_bytes);
  } else {
    for (int row = 0; row < h; row++)
      memcpy(dst + (size_t)row * w,
             frame->data[0] + (size_t)row * frame->linesize[0], w);
  }
  *len += frame_len;
  return 0;
}

// Decode every frame currently available from the codec context.
static int drain_frames(AVCodecContext *cc, uint8_t **buf, size_t *cap,
                        size_t *len, int *n_frames, int *out_kind, int *out_w,
                        int *out_h) {
  AVFrame *frame = av_frame_alloc();
  if (!frame)
    return -1;
  for (;;) {
    int ret = avcodec_receive_frame(cc, frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
      break;
    if (ret < 0 || *n_frames >= 10000 ||
        append_frame(buf, cap, len, frame, out_kind, out_w, out_h) < 0) {
      fprintf(stderr,
              "ffref: video frame rejected (ret=%d pix_fmt=%d %dx%d)\n", ret,
              frame->format, frame->width, frame->height);
      av_frame_free(&frame);
      return -1;
    }
    (*n_frames)++;
    av_frame_unref(frame);
  }
  av_frame_free(&frame);
  return 0;
}

// Blob layout (little-endian): n_frames i32, width i32, height i32,
// chroma_mode i32 (0 = 4:2:0, 1 = 4:2:2, 2 = 4:4:4, 3 = packed rgb24,
// 4 = packed rgba, 5 = gray8), then per frame the kind's compact bytes
// (planar kinds: Y, then Cb, then Cr; packed: w*bpp rows; gray: w*h).
MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_decode_video(moonbit_bytes_t data) {
  AVFormatContext *fmt = NULL;
  AVIOContext *avio = NULL;
  if (open_input(data, &fmt, &avio) < 0)
    return NULL;
  int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (vidx < 0) {
    fprintf(stderr, "ffref: decode_video no video stream\n");
    close_input(fmt, avio);
    return NULL;
  }
  AVStream *st = fmt->streams[vidx];
  const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  if (!cc || avcodec_parameters_to_context(cc, st->codecpar) < 0 ||
      avcodec_open2(cc, dec, NULL) < 0) {
    fprintf(stderr, "ffref: decode_video codec open failed (dec=%p id=%d)\n",
            (const void *)dec, (int)st->codecpar->codec_id);
    avcodec_free_context(&cc);
    close_input(fmt, avio);
    return NULL;
  }

  size_t cap = 1 << 22, len = 0;
  uint8_t *buf = malloc(cap);
  int failed = buf == NULL;
  int n_frames = 0, kind = -1, width = 0, height = 0;
  AVPacket *pkt = failed ? NULL : av_packet_alloc();
  while (!failed && av_read_frame(fmt, pkt) >= 0) {
    if (pkt->stream_index != vidx) {
      av_packet_unref(pkt);
      continue;
    }
    if (avcodec_send_packet(cc, pkt) < 0) {
      failed = 1;
      break;
    }
    av_packet_unref(pkt);
    if (drain_frames(cc, &buf, &cap, &len, &n_frames, &kind, &width,
                     &height) < 0) {
      failed = 1;
      break;
    }
  }
  if (!failed && avcodec_send_packet(cc, NULL) >= 0) {
    if (drain_frames(cc, &buf, &cap, &len, &n_frames, &kind, &width, &height) <
        0)
      failed = 1;
  }

  moonbit_bytes_t out = NULL;
  if (!failed && n_frames > 0) {
    out = moonbit_make_bytes((int32_t)(16 + len), 0);
    if (out) {
      put_i32(out + 0, n_frames);
      put_i32(out + 4, width);
      put_i32(out + 8, height);
      put_i32(out + 12, kind);
      if (len > 0)
        memcpy(out + 16, buf, len);
    }
  }
  av_packet_free(&pkt);
  free(buf);
  avcodec_free_context(&cc);
  close_input(fmt, avio);
  return out;
}

// ---- audio encode oracle --------------------------------------------------

// Growable packet sink: the packet sizes and their concatenated payloads, in
// emission order.
typedef struct {
  uint8_t *pay;
  size_t pay_cap, pay_len;
  uint32_t *sizes;
  size_t size_cap, n;
} PacketSink;

static int sink_push(PacketSink *s, const AVPacket *pkt) {
  if (s->n == s->size_cap) {
    size_t next = s->size_cap * 2;
    uint32_t *grown = realloc(s->sizes, next * 4);
    if (!grown)
      return -1;
    s->sizes = grown;
    s->size_cap = next;
  }
  size_t need = s->pay_len + (size_t)pkt->size;
  if (need > s->pay_cap) {
    size_t next = s->pay_cap;
    while (next < need)
      next *= 2;
    uint8_t *grown = realloc(s->pay, next);
    if (!grown)
      return -1;
    s->pay = grown;
    s->pay_cap = next;
  }
  memcpy(s->pay + s->pay_len, pkt->data, (size_t)pkt->size);
  s->pay_len += (size_t)pkt->size;
  s->sizes[s->n++] = (uint32_t)pkt->size;
  return 0;
}

// Move every packet the encoder has ready into the sink.
static int drain_packets(AVCodecContext *cc, AVPacket *pkt, PacketSink *s) {
  for (;;) {
    int ret = avcodec_receive_packet(cc, pkt);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
      return 0;
    if (ret < 0)
      return ret;
    ret = sink_push(s, pkt);
    av_packet_unref(pkt);
    if (ret < 0)
      return ret;
  }
}

// Blob layout (little-endian): n_packets i32, then n_packets i32 sizes,
// then every packet payload concatenated in emission order.
//
// `pcm` is interleaved s16le; swresample converts it into whatever sample
// format the named encoder wants, and fixed-size frames are fed through the
// real encoder (this is how the MoonBit AAC / shine-MP3 / Opus encoder ports
// are byte-diffed against their C references in-process). `options` is a
// "key=value:key=value" list for avcodec_open2, empty for the defaults.
//
// The reference runs scalar and BITEXACT: the ports follow the C code paths,
// and BITEXACT also drops the version string aacenc would otherwise embed.
// Experimental compliance unlocks the native "opus" encoder.
MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_encode_audio(moonbit_bytes_t pcm,
                                   moonbit_bytes_t codec_name,
                                   moonbit_bytes_t options, int32_t sample_rate,
                                   int32_t channels, int32_t bitrate) {
  const AVCodec *enc = avcodec_find_encoder_by_name((const char *)codec_name);
  if (!enc) {
    fprintf(stderr, "ffref: encode_audio no encoder '%s'\n",
            (const char *)codec_name);
    return NULL;
  }
  const enum AVSampleFormat *fmts = NULL;
  int n_fmts = 0;
  if (avcodec_get_supported_config(NULL, enc, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0,
                                   (const void **)&fmts, &n_fmts) < 0 ||
      n_fmts <= 0 || !fmts)
    return NULL;

  AVCodecContext *cc = avcodec_alloc_context3(enc);
  if (!cc)
    return NULL;
  av_channel_layout_default(&cc->ch_layout, channels);
  cc->sample_rate = sample_rate;
  cc->bit_rate = bitrate;
  cc->sample_fmt = fmts[0];
  cc->time_base = (AVRational){1, sample_rate};
  cc->flags |= AV_CODEC_FLAG_BITEXACT;
  cc->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
  AVDictionary *dict = NULL;
  if (Moonbit_array_length(options) > 0 &&
      av_dict_parse_string(&dict, (const char *)options, "=", ":", 0) < 0) {
    avcodec_free_context(&cc);
    return NULL;
  }
  // "ffref_simd=1" keeps the host's SIMD kernels; by default the reference
  // runs the scalar C paths the ports follow.
  av_force_cpu_flags(av_dict_get(dict, "ffref_simd", NULL, 0) ? -1 : 0);
  av_dict_set(&dict, "ffref_simd", NULL, 0);
  int open_ret = avcodec_open2(cc, enc, &dict);
  av_dict_free(&dict);
  if (open_ret < 0) {
    fprintf(stderr, "ffref: encode_audio open %s\n", av_err2str(open_ret));
    avcodec_free_context(&cc);
    return NULL;
  }
  int frame_size = cc->frame_size > 0 ? cc->frame_size : 1024;

  // s16 packed -> encoder format, same layout, same rate.
  SwrContext *swr = NULL;
  if (swr_alloc_set_opts2(&swr, &cc->ch_layout, cc->sample_fmt, sample_rate,
                          &cc->ch_layout, AV_SAMPLE_FMT_S16, sample_rate, 0,
                          NULL) < 0 ||
      swr_init(swr) < 0) {
    swr_free(&swr);
    avcodec_free_context(&cc);
    return NULL;
  }

  PacketSink sink = {0};
  sink.pay_cap = 1 << 16;
  sink.pay = malloc(sink.pay_cap);
  sink.size_cap = 64;
  sink.sizes = malloc(sink.size_cap * 4);
  AVFrame *frame = av_frame_alloc();
  AVPacket *pkt = av_packet_alloc();
  int failed = !sink.pay || !sink.sizes || !frame || !pkt;

  int64_t total_samples =
      (int64_t)Moonbit_array_length(pcm) / 2 / channels; // per channel
  int64_t done = 0;
  while (!failed && done < total_samples) {
    int n = total_samples - done >= frame_size ? frame_size
                                               : (int)(total_samples - done);
    frame->format = cc->sample_fmt;
    frame->sample_rate = sample_rate;
    frame->nb_samples = n;
    frame->pts = done;
    if (av_channel_layout_copy(&frame->ch_layout, &cc->ch_layout) < 0 ||
        av_frame_get_buffer(frame, 0) < 0) {
      failed = 1;
      break;
    }
    const uint8_t *src = pcm + done * channels * 2;
    if (swr_convert(swr, frame->data, n, &src, n) < 0 ||
        avcodec_send_frame(cc, frame) < 0 ||
        drain_packets(cc, pkt, &sink) < 0)
      failed = 1;
    av_frame_unref(frame);
    done += n;
  }
  // Flush the encoder.
  if (!failed && (avcodec_send_frame(cc, NULL) < 0 ||
                  drain_packets(cc, pkt, &sink) < 0))
    failed = 1;

  moonbit_bytes_t out = NULL;
  if (!failed) {
    out = moonbit_make_bytes((int32_t)(4 + sink.n * 4 + sink.pay_len), 0);
    if (out) {
      put_i32(out + 0, (int32_t)sink.n);
      for (size_t i = 0; i < sink.n; i++)
        put_i32(out + 4 + i * 4, (int32_t)sink.sizes[i]);
      if (sink.pay_len > 0)
        memcpy(out + 4 + sink.n * 4, sink.pay, sink.pay_len);
    }
  }
  av_packet_free(&pkt);
  av_frame_free(&frame);
  free(sink.pay);
  free(sink.sizes);
  swr_free(&swr);
  avcodec_free_context(&cc);
  return out;
}

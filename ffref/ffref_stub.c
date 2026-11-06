// Reference-oracle bindings over the locally built FFmpeg n9.0.2 static
// libraries. The MoonBit demux/decode ports are differential-tested against
// this in-process oracle instead of docker ffprobe round-trips. Only the C
// ABI surface lives here; everything MoonBit-visible is wrapped safely in
// ffref.mbt.
//
// Both entry points return a flat little-endian record blob as MoonBit
// Bytes (value-as-bytes pattern; no handles, no finalizers) or NULL on
// failure - the MoonBit side turns NULL into an error.

#include "moonbit.h"

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  int n = buf_size < left ? (int)left : buf_size;
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
    // On failure avformat_open_input frees the context itself.
    avio_context_free(&avio);
    free(io);
    return ret;
  }
  ret = avformat_find_stream_info(fmt, NULL);
  if (ret < 0) {
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
MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_packets(moonbit_bytes_t data) {
  AVFormatContext *fmt = NULL;
  AVIOContext *avio = NULL;
  if (open_input(data, &fmt, &avio) < 0)
    return NULL;

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
  close_input(fmt, avio);
  return out;
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
    close_input(fmt, avio);
    return NULL;
  }
  AVStream *st = fmt->streams[aidx];
  const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  if (!cc || avcodec_parameters_to_context(cc, st->codecpar) < 0 ||
      avcodec_open2(cc, dec, NULL) < 0) {
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

// Map an 8-bit planar YUV pixel format to its chroma mode: 0 = 4:2:0,
// 1 = 4:2:2, 2 = 4:4:4; -1 for anything else (high bit depth, packed,
// grayscale...). Full-range legacy variants (yuvj420p and friends) map the
// same way - their plane layout is identical, which is all byte-level
// differential testing needs.
static int planar_chroma_mode(int format) {
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
  default:
    return -1;
  }
}

// Chroma plane dimensions for a chroma mode.
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

// Append one decoded frame as compact planar YUV to *buf (growing it as
// needed). Returns 0 on success; the first frame fixes the geometry.
static int append_planar(uint8_t **buf, size_t *cap, size_t *len,
                         AVFrame *frame, int *out_mode, int *out_w,
                         int *out_h) {
  int mode = planar_chroma_mode(frame->format);
  if (mode < 0 || frame->width <= 0 || frame->height <= 0 ||
      frame->width > 8192 || frame->height > 8192) {
    return -1;
  }
  if (*len == 0) {
    *out_mode = mode;
    *out_w = frame->width;
    *out_h = frame->height;
  } else if (frame->width != *out_w || frame->height != *out_h ||
             mode != *out_mode) {
    return -1; // geometry changes are out of scope
  }
  int w = frame->width, h = frame->height, cw, ch;
  chroma_dims(mode, w, h, &cw, &ch);
  size_t frame_len = (size_t)w * h + 2 * (size_t)cw * ch;
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
  *len += frame_len;
  return 0;
}

// Decode every frame currently available from the codec context.
static int drain_frames(AVCodecContext *cc, uint8_t **buf, size_t *cap,
                        size_t *len, int *n_frames, int *out_mode, int *out_w,
                        int *out_h) {
  AVFrame *frame = av_frame_alloc();
  if (!frame)
    return -1;
  for (;;) {
    int ret = avcodec_receive_frame(cc, frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
      break;
    if (ret < 0 || *n_frames >= 10000 ||
        append_planar(buf, cap, len, frame, out_mode, out_w, out_h) < 0) {
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
// chroma_mode i32 (0 = 4:2:0, 1 = 4:2:2, 2 = 4:4:4), then per frame
// w*h + 2*cw*ch bytes of compact planar YUV (Y, then Cb, then Cr).
MOONBIT_FFI_EXPORT
moonbit_bytes_t ffref_decode_video(moonbit_bytes_t data) {
  AVFormatContext *fmt = NULL;
  AVIOContext *avio = NULL;
  if (open_input(data, &fmt, &avio) < 0)
    return NULL;
  int vidx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (vidx < 0) {
    close_input(fmt, avio);
    return NULL;
  }
  AVStream *st = fmt->streams[vidx];
  const AVCodec *dec = avcodec_find_decoder(st->codecpar->codec_id);
  AVCodecContext *cc = dec ? avcodec_alloc_context3(dec) : NULL;
  if (!cc || avcodec_parameters_to_context(cc, st->codecpar) < 0 ||
      avcodec_open2(cc, dec, NULL) < 0) {
    avcodec_free_context(&cc);
    close_input(fmt, avio);
    return NULL;
  }

  size_t cap = 1 << 22, len = 0;
  uint8_t *buf = malloc(cap);
  int failed = buf == NULL;
  int n_frames = 0, mode = -1, width = 0, height = 0;
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
    if (drain_frames(cc, &buf, &cap, &len, &n_frames, &mode, &width,
                     &height) < 0) {
      failed = 1;
      break;
    }
  }
  if (!failed && avcodec_send_packet(cc, NULL) >= 0) {
    if (drain_frames(cc, &buf, &cap, &len, &n_frames, &mode, &width, &height) <
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
      put_i32(out + 12, mode);
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

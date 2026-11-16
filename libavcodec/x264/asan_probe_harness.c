// Standalone AddressSanitizer harness for the libavcodec/x264 FFI stub.
//
// The official run-asan.py does not fit this toolchain: MoonBit's
// libruntime.a is built on mimalloc and is not ASan-compatible. Instead this
// harness supplies the three runtime symbols the stub links against, so the
// C side (semi-planar encoder open/send/drain/close, Annex B decode, NAL/AU
// probe, frame-level probe, log-callback install/restore, growable vectors,
// blob packing) can be checked for out-of-bounds writes, use-after-free and
// leaks while still calling the real FFmpeg libraries.
//
// Build inside ffmpeg-moonbit-ffref:nine-x264:
//   cc -fsanitize=address -g -O1 -I/root/.moon/include \
//     -I/usr/local/include libavcodec/x264/libx264_stub.c \
//     libavcodec/x264/asan_probe_harness.c \
//     -L/usr/local/lib -lavcodec -lswresample -lavutil -lx264 -lz \
//     -ldav1d -llzma -lshine -lpthread -lm -o /tmp/asan_probe
//   ASAN_OPTIONS=detect_leaks=1 /tmp/asan_probe stream.264

#include "moonbit.h"

#include "libavcodec/avcodec.h"
#include "libavutil/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The object header is exactly one struct moonbit_object before the payload;
// Moonbit_array_length() reads its `meta` field as the byte count.
static void *mock_object(int32_t size) {
  struct moonbit_object *h = (struct moonbit_object *)malloc(
    sizeof(struct moonbit_object) + (size_t)size + 1
  );
  if (!h)
    return NULL;
  memset(h, 0, sizeof(*h));
  h->meta = (uint32_t)size;
  uint8_t *payload = (uint8_t *)(h + 1);
  payload[size] = 0; // Bytes are null-terminated by the real runtime.
  return payload;
}

moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  uint8_t *p = (uint8_t *)mock_object(size);
  if (p)
    memset(p, value, (size_t)size);
  return p;
}

void *moonbit_make_external_object(
  void (*finalize)(void *self),
  uint32_t payload_size
) {
  (void)finalize; // encoder_section calls x264enc_close and frees explicitly
  return mock_object((int32_t)payload_size);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t x264probe_annexb(moonbit_bytes_t data);
MOONBIT_FFI_EXPORT moonbit_bytes_t x264probe_frames(moonbit_bytes_t data);
MOONBIT_FFI_EXPORT moonbit_bytes_t x264dec_annexb(moonbit_bytes_t data);

// Encoder surface (exercised since the semi-planar send path landed).
typedef struct X264Enc X264Enc;
MOONBIT_FFI_EXPORT X264Enc *x264enc_open(
  moonbit_bytes_t codec_name, int32_t width, int32_t height, int32_t pix_sel,
  int32_t tb_num, int32_t tb_den, int32_t fps_num, int32_t fps_den,
  int32_t bit_rate, int32_t flags, int32_t rc_max_rate, int32_t rc_buffer_size,
  int32_t color_range, int32_t colorspace, int32_t color_primaries,
  int32_t color_trc, int32_t chroma_sample_location, moonbit_bytes_t options
);
MOONBIT_FFI_EXPORT int32_t x264enc_status(X264Enc *e);
MOONBIT_FFI_EXPORT int32_t x264enc_send_frame(
  X264Enc *e, int64_t pts, moonbit_bytes_t y, moonbit_bytes_t u,
  moonbit_bytes_t v, int32_t force_idr
);
MOONBIT_FFI_EXPORT int32_t x264enc_send_eof(X264Enc *e);
MOONBIT_FFI_EXPORT moonbit_bytes_t x264enc_receive_packet(X264Enc *e);
MOONBIT_FFI_EXPORT void x264enc_close(X264Enc *e);

static void release(moonbit_bytes_t b) {
  if (b)
    free(Moonbit_object_header(b));
}

static int32_t rd_i32(const uint8_t *p) {
  int32_t v;
  memcpy(&v, p, 4);
  return v;
}

static int run(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "asan: cannot open %s\n", path);
    return 1;
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (n <= 8 || n > 64 * 1024 * 1024) {
    fclose(f);
    fprintf(stderr, "asan: implausible stream size %ld\n", n);
    return 1;
  }
  moonbit_bytes_t stream = (moonbit_bytes_t)mock_object((int32_t)n);
  if (!stream) {
    fclose(f);
    return 1;
  }
  if (fread(stream, 1, (size_t)n, f) != (size_t)n) {
    fclose(f);
    return 1;
  }
  fclose(f);

  // Exercise the probe twice: the av_log callback must be restored on every
  // exit path, so a second call is part of the memory/state check.
  for (int pass = 0; pass < 2; pass++) {
    moonbit_bytes_t probe = x264probe_annexb(stream);
    if (!probe) {
      fprintf(stderr, "asan: probe returned NULL on pass %d\n", pass);
      return 1;
    }
    int32_t frames = rd_i32(probe);
    int32_t warn = rd_i32(probe + 4);
    int32_t err = rd_i32(probe + 8);
    int32_t nals = rd_i32(probe + 12);
    int32_t aus = rd_i32(probe + 16);
    int32_t len = (int32_t)Moonbit_array_length(probe);
    printf(
      "asan pass %d probe: frames=%d warn=%d err=%d nals=%d aus=%d len=%d\n",
      pass, frames, warn, err, nals, aus, len
    );
    if (len != 20 + nals + 4 * aus) {
      fprintf(stderr, "asan: probe blob length mismatch\n");
      return 1;
    }
    // Read every byte we claim to have written (ASan guards the bounds).
    volatile int sink = 0;
    for (int i = 0; i < len; i++)
      sink += probe[i];
    (void)sink;
    release(probe);

    // Frame-level probe: 8 int32 records per decoded picture. Check the
    // claimed shape against the real blob length, then touch every byte so
    // ASan guards the full packed range (including the FNV digest halves).
    moonbit_bytes_t fprobe = x264probe_frames(stream);
    if (!fprobe) {
      fprintf(stderr, "asan: frame probe returned NULL on pass %d\n", pass);
      return 1;
    }
    int32_t fn = rd_i32(fprobe);
    int32_t fw = rd_i32(fprobe + 4);
    int32_t fe = rd_i32(fprobe + 8);
    int32_t fields = rd_i32(fprobe + 24);
    int32_t flen = (int32_t)Moonbit_array_length(fprobe);
    printf(
      "asan pass %d frames: n=%d warn=%d err=%d fields=%d len=%d\n",
      pass, fn, fw, fe, fields, flen
    );
    if (fields != 8 || fn < 0 || flen != 32 + 32 * fn) {
      fprintf(stderr, "asan: frame probe blob shape mismatch\n");
      return 1;
    }
    volatile int fsink = 0;
    for (int i = 0; i < flen; i++)
      fsink += fprobe[i];
    (void)fsink;
    release(fprobe);
  }

  moonbit_bytes_t dec = x264dec_annexb(stream);
  if (!dec) {
    fprintf(stderr, "asan: decode returned NULL\n");
    return 1;
  }
  int32_t dec_len = (int32_t)Moonbit_array_length(dec);
  printf(
    "asan decode: frames=%d %dx%d kind=%d len=%d\n",
    rd_i32(dec), rd_i32(dec + 4), rd_i32(dec + 8), rd_i32(dec + 12), dec_len
  );
  release(dec);
  release(stream);

  // A deliberately short blob must be rejected without reading past its end.
  moonbit_bytes_t tiny = (moonbit_bytes_t)mock_object(4);
  if (tiny) {
    tiny[0] = 0;
    tiny[1] = 0;
    tiny[2] = 0;
    tiny[3] = 1;
    moonbit_bytes_t r = x264probe_annexb(tiny);
    printf("asan short-blob probe: %s\n", r ? "blob" : "NULL");
    release(r);
    moonbit_bytes_t fr = x264probe_frames(tiny);
    printf("asan short-blob frame probe: %s\n", fr ? "blob" : "NULL");
    release(fr);
    release(tiny);
  }
  return 0;
}

// The semi-planar encoder path: three NV12 frames through open/send/drain/
// close, plus both shape rejections, all under ASan with the mock runtime.
static int encoder_section(void) {
  moonbit_bytes_t name = (moonbit_bytes_t)mock_object(8);
  memcpy(name, "libx264", 8);
  moonbit_bytes_t opts = (moonbit_bytes_t)mock_object(1);
  opts[0] = 0;
  X264Enc *e = x264enc_open(
    name, 32, 16, 8 /* NV12 */, 1, 25, 25, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, opts
  );
  if (!e || x264enc_status(e) != 0) {
    fprintf(stderr, "asan: NV12 encoder open failed\n");
    return 1;
  }
  // Shape rejections must not read out of bounds.
  moonbit_bytes_t y = (moonbit_bytes_t)mock_object(32 * 16);
  moonbit_bytes_t uv = (moonbit_bytes_t)mock_object(16 * 8 * 2);
  moonbit_bytes_t empty = (moonbit_bytes_t)mock_object(0);
  moonbit_bytes_t one = (moonbit_bytes_t)mock_object(1);
  for (int i = 0; i < 32 * 16; i++)
    y[i] = (uint8_t)(i * 7 + 3);
  for (int i = 0; i < 16 * 8 * 2; i++)
    uv[i] = (uint8_t)(i * 11 + 90);
  if (x264enc_send_frame(e, 0, y, uv, one, 0) != -1) {
    fprintf(stderr, "asan: non-empty v accepted\n");
    return 1;
  }
  if (x264enc_send_frame(e, 0, y, empty, empty, 0) != -1) {
    fprintf(stderr, "asan: short interleaved plane accepted\n");
    return 1;
  }
  // Three real frames; drain on EAGAIN exactly like the MoonBit flush.
  for (int f = 0; f < 3; f++) {
    int ret = x264enc_send_frame(e, f, y, uv, empty, f == 0);
    while (ret == 1) {
      moonbit_bytes_t pkt = x264enc_receive_packet(e);
      if (pkt) {
        release(pkt);
        ret = x264enc_send_frame(e, f, y, uv, empty, f == 0);
      } else {
        fprintf(stderr, "asan: receive failed during backpressure\n");
        return 1;
      }
    }
    if (ret != 0) {
      fprintf(stderr, "asan: send_frame failed (%d)\n", ret);
      return 1;
    }
  }
  while (x264enc_send_eof(e) == 1) {
    moonbit_bytes_t pkt = x264enc_receive_packet(e);
    if (!pkt) {
      fprintf(stderr, "asan: receive failed during EOF retry\n");
      return 1;
    }
    release(pkt);
  }
  int packets = 0;
  for (;;) {
    moonbit_bytes_t pkt = x264enc_receive_packet(e);
    if (!pkt) {
      fprintf(stderr, "asan: receive failed during drain\n");
      return 1;
    }
    int32_t status = rd_i32(pkt);
    int32_t len = rd_i32(pkt + 24);
    volatile int sink = 0;
    for (int i = 0; i < 28 + len; i++)
      sink += pkt[i];
    (void)sink;
    release(pkt);
    if (status == 2)
      break;
    packets++;
  }
  printf("asan encoder: NV12 3-frame drain ok, %d packets\n", packets);
  x264enc_close(e);
  free(Moonbit_object_header(e)); // mock runtime: no finalizer wired
  release(y);
  release(uv);
  release(empty);
  release(one);
  release(name);
  release(opts);
  return 0;
}

// Packed RGB leg: BGR24 through libx264rgb, one plane of w*h*3 bytes.
static int encoder_rgb_leg(void) {
  moonbit_bytes_t name = (moonbit_bytes_t)mock_object(11);
  memcpy(name, "libx264rgb", 11);
  moonbit_bytes_t opts = (moonbit_bytes_t)mock_object(1);
  opts[0] = 0;
  X264Enc *e = x264enc_open(
    name, 32, 16, 13 /* BGR24 */, 1, 25, 25, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, opts
  );
  if (!e || x264enc_status(e) != 0) {
    fprintf(stderr, "asan: libx264rgb open failed\n");
    return 1;
  }
  moonbit_bytes_t bgr = (moonbit_bytes_t)mock_object(32 * 16 * 3);
  moonbit_bytes_t empty = (moonbit_bytes_t)mock_object(0);
  for (int i = 0; i < 32 * 16 * 3; i++)
    bgr[i] = (uint8_t)(i * 5 + 40);
  if (x264enc_send_frame(e, 0, bgr, empty, empty, 1) != 0) {
    fprintf(stderr, "asan: BGR24 send_frame failed\n");
    return 1;
  }
  // A chroma plane must be rejected without reading out of bounds.
  if (x264enc_send_frame(e, 1, bgr, bgr, empty, 0) != -1) {
    fprintf(stderr, "asan: chroma plane accepted for packed input\n");
    return 1;
  }
  while (x264enc_send_eof(e) == 1) {
    moonbit_bytes_t pkt = x264enc_receive_packet(e);
    if (!pkt) {
      fprintf(stderr, "asan: receive failed during RGB EOF retry\n");
      return 1;
    }
    release(pkt);
  }
  int packets = 0;
  for (;;) {
    moonbit_bytes_t pkt = x264enc_receive_packet(e);
    if (!pkt) {
      fprintf(stderr, "asan: receive failed during RGB drain\n");
      return 1;
    }
    int32_t status = rd_i32(pkt);
    int32_t len = rd_i32(pkt + 24);
    volatile int sink = 0;
    for (int i = 0; i < 28 + len; i++)
      sink += pkt[i];
    (void)sink;
    release(pkt);
    if (status == 2)
      break;
    packets++;
  }
  printf("asan encoder: BGR24 drain ok, %d packets\n", packets);
  x264enc_close(e);
  free(Moonbit_object_header(e));
  release(bgr);
  release(empty);
  release(name);
  release(opts);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s stream.264\n", argv[0]);
    return 2;
  }
  av_log_set_level(AV_LOG_ERROR);
  if (encoder_section() != 0)
    return 1;
  if (encoder_rgb_leg() != 0)
    return 1;
  return run(argv[1]);
}

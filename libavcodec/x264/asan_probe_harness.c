// Standalone AddressSanitizer harness for the libavcodec/x264 FFI stub.
//
// The official run-asan.py does not fit this toolchain: MoonBit's
// libruntime.a is built on mimalloc and is not ASan-compatible. Instead this
// harness supplies the three runtime symbols the stub links against, so the
// C side (Annex B decode, NAL/AU probe, log-callback install/restore,
// growable vectors, blob packing) can be checked for out-of-bounds writes,
// use-after-free and leaks while still calling the real FFmpeg libraries.
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
  (void)finalize; // the encoder path is not exercised by this harness
  return mock_object((int32_t)payload_size);
}

MOONBIT_FFI_EXPORT moonbit_bytes_t x264probe_annexb(moonbit_bytes_t data);
MOONBIT_FFI_EXPORT moonbit_bytes_t x264dec_annexb(moonbit_bytes_t data);

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
    release(tiny);
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s stream.264\n", argv[0]);
    return 2;
  }
  av_log_set_level(AV_LOG_ERROR);
  return run(argv[1]);
}

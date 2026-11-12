// Standalone AddressSanitizer harness for the encode-h264 host I/O stub.
//
// Same trick as libavcodec/x264/asan_probe_harness.c (§391): MoonBit's
// libruntime.a is mimalloc-based and ASan-incompatible, so this harness
// supplies the runtime symbols the stub links against. Unlike the x264
// harness, the external-object finalizers matter here — reader/writer
// handles close their FILE* from the finalizer — so mock_gc() replays them
// explicitly and LSan checks that every fopen got an fclose.
//
// Build inside ffmpeg-moonbit-ffref:nine-x264:
//   cc -fsanitize=address -g -O1 -I/root/.moon/include \
//     cmd/encode-h264/host_io_stub.c cmd/encode-h264/asan_host_io_probe.c \
//     -o /tmp/asan_host_io
//   ASAN_OPTIONS=detect_leaks=1 /tmp/asan_host_io

#include "moonbit.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- mock MoonBit runtime -------------------------------------------------

struct moonbit_object;

// Every mock_object allocation is tracked so mock_gc can free it; the real
// runtime GC-owns Bytes and external objects, so an unfreed Bytes in the
// harness is bookkeeping, not a stub leak.
struct alloc_reg {
  struct moonbit_object *header;
  struct alloc_reg *next;
};

struct ext_reg {
  void *payload;
  void (*finalize)(void *self);
  struct ext_reg *next;
};

static struct alloc_reg *alloc_head = NULL;
static struct ext_reg *ext_head = NULL;

static void *mock_object(int32_t size) {
  struct moonbit_object *h = (struct moonbit_object *)malloc(
    sizeof(struct moonbit_object) + (size_t)size + 1
  );
  if (!h)
    return NULL;
  memset(h, 0, sizeof(*h));
  h->meta = (uint32_t)size;
  uint8_t *payload = (uint8_t *)(h + 1);
  payload[size] = 0;
  struct alloc_reg *reg = (struct alloc_reg *)malloc(sizeof(struct alloc_reg));
  if (reg) {
    reg->header = h;
    reg->next = alloc_head;
    alloc_head = reg;
  }
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
  void *payload = mock_object((int32_t)payload_size);
  if (!payload)
    return NULL;
  struct ext_reg *reg =
    (struct ext_reg *)malloc(sizeof(struct ext_reg));
  if (!reg)
    return NULL;
  reg->payload = payload;
  reg->finalize = finalize;
  reg->next = ext_head;
  ext_head = reg;
  return payload;
}

// Replay every registered finalizer ("the GC dropped the handles"), then
// free the mock allocations. A FILE* that neither close() nor the finalizer
// released shows up as an LSan leak.
static void mock_gc(void) {
  while (ext_head) {
    struct ext_reg *reg = ext_head;
    ext_head = reg->next;
    if (reg->finalize)
      reg->finalize(reg->payload);
    free(reg);
  }
  while (alloc_head) {
    struct alloc_reg *reg = alloc_head;
    alloc_head = reg->next;
    free(reg->header);
    free(reg);
  }
}

// --- helpers ---------------------------------------------------------------

static int failures = 0;

static void check(int cond, const char *what) {
  if (!cond) {
    fprintf(stderr, "FAIL: %s\n", what);
    failures++;
  }
}

static moonbit_bytes_t cstr_bytes(const char *s) {
  size_t len = strlen(s);
  moonbit_bytes_t b = moonbit_make_bytes((int32_t)len, 0);
  memcpy(b, s, len);
  return b;
}

typedef struct {
  FILE *fp;
  char errmsg[256];
} H264HostHandle;

MOONBIT_FFI_EXPORT H264HostHandle *h264cli_reader_open(moonbit_bytes_t path);
MOONBIT_FFI_EXPORT moonbit_bytes_t h264cli_reader_error(H264HostHandle *r);
MOONBIT_FFI_EXPORT int64_t h264cli_reader_size(H264HostHandle *r);
MOONBIT_FFI_EXPORT int32_t h264cli_reader_read(
  H264HostHandle *r,
  moonbit_bytes_t buf
);
MOONBIT_FFI_EXPORT void h264cli_reader_close(H264HostHandle *r);
MOONBIT_FFI_EXPORT H264HostHandle *h264cli_writer_open(moonbit_bytes_t path);
MOONBIT_FFI_EXPORT moonbit_bytes_t h264cli_writer_error(H264HostHandle *w);
MOONBIT_FFI_EXPORT int32_t h264cli_writer_write(
  H264HostHandle *w,
  moonbit_bytes_t buf
);
MOONBIT_FFI_EXPORT int32_t h264cli_writer_close(H264HostHandle *w);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <scratch-dir>\n", argv[0]);
    return 2;
  }
  char in_path[512], out_path[512], bad_path[512];
  snprintf(in_path, sizeof(in_path), "%s/asan_in.bin", argv[1]);
  snprintf(out_path, sizeof(out_path), "%s/asan_out.bin", argv[1]);
  snprintf(bad_path, sizeof(bad_path), "%s/no/such/dir/out.bin", argv[1]);

  // Test input: exactly three 64-byte frames.
  const int frame = 64;
  uint8_t input[frame * 3];
  for (int i = 0; i < (int)sizeof(input); i++)
    input[i] = (uint8_t)i;

  // A scratch file truncated to 2.5 frames exercises the short-read path.
  char trunc_path[512];
  snprintf(trunc_path, sizeof(trunc_path), "%s/asan_trunc.bin", argv[1]);
  FILE *seed = fopen(trunc_path, "wb");
  check(seed != NULL, "seed truncated file");
  fwrite(input, 1, frame * 2 + frame / 2, seed);
  fclose(seed);
  // Full input goes through the writer under test itself.
  {
    H264HostHandle *w = h264cli_writer_open(cstr_bytes(in_path));
    check(w != NULL, "writer open scratch");
    check(h264cli_writer_error(w) == NULL, "writer open clean");
    moonbit_bytes_t payload = moonbit_make_bytes((int32_t)sizeof(input), 0);
    memcpy(payload, input, sizeof(input));
    check(h264cli_writer_write(w, payload) == 0, "writer write input");
    check(h264cli_writer_close(w) == 0, "writer close scratch");
  }

  // Reader: size + three full frames + clean EOF.
  {
    H264HostHandle *r = h264cli_reader_open(cstr_bytes(in_path));
    check(r != NULL, "reader open");
    check(h264cli_reader_error(r) == NULL, "reader open clean");
    check(h264cli_reader_size(r) == (int64_t)sizeof(input), "reader size");
    moonbit_bytes_t buf = moonbit_make_bytes(frame, 0xAA);
    for (int f = 0; f < 3; f++) {
      check(h264cli_reader_read(r, buf) == frame, "reader full frame");
      check(memcmp(buf, input + f * frame, frame) == 0, "reader frame data");
    }
    check(h264cli_reader_read(r, buf) == 0, "reader clean EOF");
    h264cli_reader_close(r);
  }

  // Reader on a truncated tail frame: 0 < n < frame_size.
  {
    H264HostHandle *r = h264cli_reader_open(cstr_bytes(trunc_path));
    check(r != NULL, "trunc reader open");
    moonbit_bytes_t buf = moonbit_make_bytes(frame, 0);
    check(h264cli_reader_read(r, buf) == frame, "trunc frame 1");
    check(h264cli_reader_read(r, buf) == frame, "trunc frame 2");
    int n = h264cli_reader_read(r, buf);
    check(n == frame / 2, "trunc short tail");
    check(memcmp(buf, input + frame * 2, frame / 2) == 0, "trunc tail data");
    check(h264cli_reader_read(r, buf) == 0, "trunc EOF after short");
    h264cli_reader_close(r);
  }

  // Reader on a missing file: handle comes back, error bytes carry errno.
  {
    H264HostHandle *r = h264cli_reader_open(cstr_bytes(bad_path));
    check(r != NULL, "missing-file handle exists");
    moonbit_bytes_t err = h264cli_reader_error(r);
    check(err != NULL, "missing-file error bytes");
    check(h264cli_reader_size(r) < 0, "missing-file size fails");
    check(h264cli_reader_read(r, moonbit_make_bytes(4, 0)) < 0, "missing-file read fails");
    h264cli_reader_close(r);
  }

  // Writer to an unwritable path: error bytes, write fails.
  {
    H264HostHandle *w = h264cli_writer_open(cstr_bytes(bad_path));
    check(w != NULL, "bad-path handle exists");
    check(h264cli_writer_error(w) != NULL, "bad-path error bytes");
    check(
      h264cli_writer_write(w, moonbit_make_bytes(8, 0)) < 0,
      "bad-path write fails"
    );
    h264cli_writer_close(w);
  }

  // Finalizer path: drop handles without close — mock_gc must close both
  // FILE* handles or LSan reports a leak. The writer gets a real AU first
  // so the flushed output can be verified afterwards.
  {
    H264HostHandle *r = h264cli_reader_open(cstr_bytes(in_path));
    H264HostHandle *w = h264cli_writer_open(cstr_bytes(out_path));
    check(r != NULL && w != NULL, "finalizer handles");
    check(h264cli_writer_error(w) == NULL, "finalizer writer clean");
    moonbit_bytes_t payload = moonbit_make_bytes((int32_t)sizeof(input), 0);
    memcpy(payload, input, sizeof(input));
    check(h264cli_writer_write(w, payload) == 0, "finalizer writer write");
    (void)h264cli_reader_read(r, moonbit_make_bytes(16, 0));
  }

  mock_gc();

  // Output written via the writer round-trips.
  FILE *verify = fopen(out_path, "rb");
  check(verify != NULL, "finalizer output exists");
  if (verify) {
    uint8_t got[sizeof(input)];
    size_t n = fread(got, 1, sizeof(input), verify);
    check(n == sizeof(input), "finalizer output length");
    check(memcmp(got, input, sizeof(input)) == 0, "finalizer output data");
    fclose(verify);
  }

  if (failures) {
    fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  printf("host_io asan probe: all checks passed\n");
  return 0;
}

// Chunked host file I/O for the encode-h264 `--stream` path.
//
// The reader hands the MoonBit encoder one YUV420P frame per call and the
// writer appends one finished access unit per call, so a native run never
// holds the whole input or output in memory. Handles are GC-tracked
// external objects; their finalizers close a still-open FILE* when the
// MoonBit side drops the handle, while the explicit close entry points let
// the CLI flush the writer before printing its summary.
//
// The wasm build has no chunked host filesystem and uses the whole-file
// fallback in host_io_wasm.mbt instead; this file is only compiled for
// native targets (see moon.pkg `native-stub` / `targets`).

#include "moonbit.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#define H264_FSEEK _fseeki64
#define H264_FTELL _ftelli64
#else
#define H264_FSEEK fseek
#define H264_FTELL ftell
#endif

typedef struct {
  FILE *fp;
  char errmsg[256];
} H264HostReader;

typedef struct {
  FILE *fp;
  char errmsg[256];
} H264HostWriter;

static void h264_host_close(FILE **fp) {
  if (*fp) {
    fclose(*fp);
    *fp = NULL;
  }
}

static void h264_host_reader_destroy(void *ptr) {
  H264HostReader *reader = (H264HostReader *)ptr;
  if (reader)
    h264_host_close(&reader->fp);
}

static void h264_host_writer_destroy(void *ptr) {
  H264HostWriter *writer = (H264HostWriter *)ptr;
  if (writer)
    h264_host_close(&writer->fp);
}

static void h264_host_error(char *errmsg, const char *what, const char *path) {
  int code = errno;
  if (path)
    snprintf(errmsg, 256, "%s '%s': %s", what, path, strerror(code));
  else
    snprintf(errmsg, 256, "%s: %s", what, strerror(code));
}

static moonbit_bytes_t h264_host_error_bytes(const char *errmsg) {
  if (errmsg[0] == '\0')
    return NULL;
  size_t len = strlen(errmsg);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)len, 0);
  if (out)
    memcpy(out, errmsg, len);
  return out;
}

MOONBIT_FFI_EXPORT
H264HostReader *h264cli_reader_open(moonbit_bytes_t path) {
  H264HostReader *reader = (H264HostReader *)moonbit_make_external_object(
    h264_host_reader_destroy, sizeof(H264HostReader));
  if (!reader)
    return NULL;
  memset(reader, 0, sizeof(*reader));
  errno = 0;
  reader->fp = fopen((const char *)path, "rb");
  if (!reader->fp)
    h264_host_error(reader->errmsg, "cannot open input", (const char *)path);
  return reader;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t h264cli_reader_error(H264HostReader *reader) {
  return reader ? h264_host_error_bytes(reader->errmsg) : NULL;
}

MOONBIT_FFI_EXPORT
int64_t h264cli_reader_size(H264HostReader *reader) {
  if (!reader || !reader->fp)
    return -1;
  errno = 0;
  if (H264_FSEEK(reader->fp, 0, SEEK_END) != 0) {
    h264_host_error(reader->errmsg, "cannot size input", NULL);
    return -1;
  }
  long long size = (long long)H264_FTELL(reader->fp);
  if (size < 0 || H264_FSEEK(reader->fp, 0, SEEK_SET) != 0) {
    h264_host_error(reader->errmsg, "cannot size input", NULL);
    return -1;
  }
  return (int64_t)size;
}

MOONBIT_FFI_EXPORT
int32_t h264cli_reader_read(H264HostReader *reader, moonbit_bytes_t buf) {
  if (!reader || !reader->fp)
    return -1;
  int32_t len = Moonbit_array_length(buf);
  size_t got = 0;
  errno = 0;
  while (got < (size_t)len) {
    size_t n = fread((uint8_t *)buf + got, 1, (size_t)len - got, reader->fp);
    got += n;
    if (n == 0) {
      if (ferror(reader->fp)) {
        h264_host_error(reader->errmsg, "input read failed", NULL);
        return -1;
      }
      break;
    }
  }
  return (int32_t)got;
}

MOONBIT_FFI_EXPORT
void h264cli_reader_close(H264HostReader *reader) {
  if (reader)
    h264_host_close(&reader->fp);
}

MOONBIT_FFI_EXPORT
H264HostWriter *h264cli_writer_open(moonbit_bytes_t path) {
  H264HostWriter *writer = (H264HostWriter *)moonbit_make_external_object(
    h264_host_writer_destroy, sizeof(H264HostWriter));
  if (!writer)
    return NULL;
  memset(writer, 0, sizeof(*writer));
  errno = 0;
  writer->fp = fopen((const char *)path, "wb");
  if (!writer->fp)
    h264_host_error(writer->errmsg, "cannot open output", (const char *)path);
  return writer;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t h264cli_writer_error(H264HostWriter *writer) {
  return writer ? h264_host_error_bytes(writer->errmsg) : NULL;
}

MOONBIT_FFI_EXPORT
int32_t h264cli_writer_write(H264HostWriter *writer, moonbit_bytes_t buf) {
  if (!writer || !writer->fp)
    return -1;
  int32_t len = Moonbit_array_length(buf);
  size_t put = 0;
  errno = 0;
  while (put < (size_t)len) {
    size_t n = fwrite((const uint8_t *)buf + put, 1, (size_t)len - put,
                      writer->fp);
    if (n == 0) {
      h264_host_error(writer->errmsg, "output write failed", NULL);
      return -1;
    }
    put += n;
  }
  if (fflush(writer->fp) != 0) {
    h264_host_error(writer->errmsg, "output flush failed", NULL);
    return -1;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t h264cli_writer_close(H264HostWriter *writer) {
  if (!writer || !writer->fp)
    return 0;
  errno = 0;
  if (fclose(writer->fp) != 0) {
    writer->fp = NULL;
    h264_host_error(writer->errmsg, "output close failed", NULL);
    return -1;
  }
  writer->fp = NULL;
  return 0;
}

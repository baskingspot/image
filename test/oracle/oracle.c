// The oracle's protocol, little endian. Requests on stdin, each
//
//   u8 name length, name (an op from a format's table, such as "qoi-wuffs"),
//   u8 pixel format (image.PixelFormat), u64 pixel limit, u32 length, bytes
//
// where a length of 0xffffffff, with no bytes, means the previous request's
// input again, so an input asked for in many formats and of many oracles
// crosses the pipe once;
//
// and one response per request on stdout, after all of stdin is read:
//
//   u8 status (enum status), u32 width, u32 height, u32 length, pixels
//
// An unknown name is a fatal error. test/oracle/Oracle.zig is the client.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "oracle.h"

static const struct op *const formats[] = {
#define FORMAT(name) name##_ops,
#include "formats.def"
#undef FORMAT
};

size_t pixel_bytes(enum pixel_format f) {
  switch (f) {
    case PF_GRAY8: return 1;
    case PF_GRAY_ALPHA8: case PF_GRAY_ALPHA8_PREMUL: case PF_GRAY16: return 2;
    case PF_RGB8: case PF_BGR8: return 3;
    case PF_RGBA8: case PF_RGBA8_PREMUL: case PF_BGRA8: case PF_BGRA8_PREMUL: return 4;
    case PF_GRAY_ALPHA16: case PF_GRAY_ALPHA16_PREMUL: return 4;
    case PF_RGB16: case PF_BGR16: return 6;
    case PF_RGBA16: case PF_RGBA16_PREMUL: case PF_BGRA16: case PF_BGRA16_PREMUL: return 8;
    case PF_RGBA_F32: case PF_RGBA_F32_PREMUL: return 16;
  }
  return 0;
}

static const struct op *find(const char *name) {
  for (size_t i = 0; i < sizeof formats / sizeof formats[0]; i++) {
    for (const struct op *op = formats[i]; op->name; op++) {
      if (strcmp(op->name, name) == 0) return op;
    }
  }
  return NULL;
}

static uint8_t *input;
static size_t input_len, input_at;

static int take(void *dst, size_t n) {
  if (input_len - input_at < n) return 0;
  memcpy(dst, input + input_at, n);
  input_at += n;
  return 1;
}

static void put32(FILE *f, uint32_t v) {
  uint8_t b[4] = {v, v >> 8, v >> 16, v >> 24};
  fwrite(b, 1, 4, f);
}

int main(void) {
  // All of stdin first, so a client can write a whole batch, then read.
  size_t cap = 1 << 20;
  input = malloc(cap);
  for (size_t n; (n = fread(input + input_len, 1, cap - input_len, stdin)) > 0;) {
    input_len += n;
    if (input_len == cap) input = realloc(input, cap *= 2);
  }
  const uint8_t *last = NULL;
  size_t last_len = 0;
  while (input_at < input_len) {
    uint8_t name_len, format, limit_bytes[8], len_bytes[4];
    char name[256];
    if (!take(&name_len, 1) || !take(name, name_len) || !take(&format, 1) ||
        !take(limit_bytes, 8) || !take(len_bytes, 4)) {
      fprintf(stderr, "oracle: truncated request\n");
      return 1;
    }
    name[name_len] = 0;
    uint64_t limit = 0;
    for (int i = 7; i >= 0; i--) limit = limit << 8 | limit_bytes[i];
    uint32_t len = len_bytes[0] | len_bytes[1] << 8 | len_bytes[2] << 16 | (uint32_t)len_bytes[3] << 24;
    if (len == UINT32_MAX) {
      if (!last) {
        fprintf(stderr, "oracle: no previous input\n");
        return 1;
      }
    } else if (input_len - input_at < len) {
      fprintf(stderr, "oracle: truncated request\n");
      return 1;
    } else {
      last = input + input_at;
      last_len = len;
      input_at += len;
    }
    const struct op *op = find(name);
    if (!op) {
      fprintf(stderr, "oracle: no op %s\n", name);
      return 1;
    }
    struct image img = {0};
    enum status s = format <= PF_RGBA_F32_PREMUL ? op->decode(last, last_len, format, limit, &img)
                                                 : STATUS_SKIPPED;
    if (s != STATUS_OK) img.width = img.height = img.len = 0;
    fputc(s, stdout);
    put32(stdout, img.width);
    put32(stdout, img.height);
    put32(stdout, img.len);
    fwrite(img.pixels, 1, img.len, stdout);
    free(img.pixels);
  }
  return fflush(stdout) == 0 ? 0 : 1;
}

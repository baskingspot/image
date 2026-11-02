// The oracle's protocol, little endian. On stdin, the u64 length of the
// batch of requests that follows, each
//
//   u8 name length, name (an op from a format's table, such as "qoi-wuffs"),
//   u8 pixel format (image.PixelFormat), u64 pixel limit, u32 length, bytes
//
// where a length of 0xffffffff, with no bytes, means the previous request's
// input again, so an input asked for in many formats and of an oracle
// crosses the pipe once;
//
// and one response per request on stdout, after all of stdin is read:
//
//   u8 status (enum status), u32 width, u32 height, u32 length, u64 hash
//
// where the hash is XXH64, seed 0, of the pixels, tightly packed in the
// requested format: the harness only asks whether two answers are the same,
// and gigabytes of pixels need not cross the pipe to say so.
//
// An encode op's input is the source's width and height, u32 each, then
// its pixels, tightly packed in the pixel format; its response's length
// and hash are the encoded file's. An unknown name, or an encode op's
// pixels that do not fill its size, is a fatal error.
// test/oracle/Oracle.zig is the client.
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
    case PF_RGBA8: case PF_RGBA8_PREMUL: case PF_BGRA8: case PF_BGRA8_PREMUL: case PF_CMYK8: return 4;
    case PF_GRAY_ALPHA16: case PF_GRAY_ALPHA16_PREMUL: return 4;
    case PF_RGB16: case PF_BGR16: return 6;
    case PF_RGBA16: case PF_RGBA16_PREMUL: case PF_BGRA16: case PF_BGRA16_PREMUL: case PF_CMYK16: return 8;
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

static uint32_t get32(const uint8_t *b) {
  return b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24;
}

static void put32(FILE *f, uint32_t v) {
  uint8_t b[4] = {v, v >> 8, v >> 16, v >> 24};
  fwrite(b, 1, 4, f);
}

static void put64(FILE *f, uint64_t v) {
  put32(f, (uint32_t)v);
  put32(f, (uint32_t)(v >> 32));
}

// XXH64 (github.com/Cyan4973/xxHash, doc/xxhash_spec.md), as Zig's
// std.hash.XxHash64 computes it.
#define P1 0x9E3779B185EBCA87ull
#define P2 0xC2B2AE3D27D4EB4Full
#define P3 0x165667B19E3779F9ull
#define P4 0x85EBCA77C2B2AE63ull
#define P5 0x27D4EB2F165667C5ull

static uint64_t rotl(uint64_t x, int r) { return x << r | x >> (64 - r); }

static uint64_t read64(const uint8_t *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return v;
}

static uint64_t xxh_round(uint64_t acc, uint64_t lane) { return rotl(acc + lane * P2, 31) * P1; }

static uint64_t xxh_merge(uint64_t h, uint64_t v) { return (h ^ xxh_round(0, v)) * P1 + P4; }

static uint64_t xxh64(const uint8_t *p, size_t len) {
  const uint8_t *end = p + len;
  uint64_t h;
  if (len >= 32) {
    uint64_t v1 = P1 + P2, v2 = P2, v3 = 0, v4 = -P1;
    for (; end - p >= 32; p += 32) {
      v1 = xxh_round(v1, read64(p));
      v2 = xxh_round(v2, read64(p + 8));
      v3 = xxh_round(v3, read64(p + 16));
      v4 = xxh_round(v4, read64(p + 24));
    }
    h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
    h = xxh_merge(xxh_merge(xxh_merge(xxh_merge(h, v1), v2), v3), v4);
  } else {
    h = P5;
  }
  h += len;
  for (; end - p >= 8; p += 8) h = rotl(h ^ xxh_round(0, read64(p)), 27) * P1 + P4;
  if (end - p >= 4) {
    h = rotl(h ^ (uint64_t)get32(p) * P1, 23) * P2 + P3;
    p += 4;
  }
  for (; p < end; p++) h = rotl(h ^ *p * P5, 11) * P1;
  h ^= h >> 33;
  h *= P2;
  h ^= h >> 29;
  h *= P3;
  return h ^ h >> 32;
}

int main(void) {
  // All of stdin first, so a client can write a whole batch, then read:
  // its length, then the batch, read into one allocation of that size.
  uint8_t total_bytes[8];
  if (fread(total_bytes, 1, 8, stdin) != 8) {
    fprintf(stderr, "oracle: no batch length\n");
    return 1;
  }
  uint64_t total = 0;
  for (int i = 7; i >= 0; i--) total = total << 8 | total_bytes[i];
  input = malloc(total ? total : 1);
  if (!input) {
    fprintf(stderr, "oracle: cannot allocate a batch of %llu bytes\n", (unsigned long long)total);
    return 1;
  }
  input_len = fread(input, 1, total, stdin);
  if (input_len != total || fgetc(stdin) != EOF) {
    fprintf(stderr, "oracle: the batch is not %llu bytes\n", (unsigned long long)total);
    return 1;
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
    uint32_t len = get32(len_bytes);
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
    enum status s = STATUS_SKIPPED;
    int known = format <= PF_CMYK16;
    if (known && op->encode) {
      if (last_len < 8) {
        fprintf(stderr, "oracle: %s: no size\n", name);
        return 1;
      }
      uint32_t w = get32(last), h = get32(last + 4);
      if ((uint64_t)w * h > limit) {
        s = STATUS_TOO_LARGE;
      } else if ((uint64_t)w * h * pixel_bytes(format) != last_len - 8) {
        fprintf(stderr, "oracle: %s: pixels do not fill %ux%u\n", name, w, h);
        return 1;
      } else if ((s = op->encode(last + 8, format, w, h, &img)) == STATUS_OK) {
        img.width = w;
        img.height = h;
      }
    } else if (known) {
      s = op->decode(last, last_len, format, limit, &img);
    }
    if (s != STATUS_OK) img.width = img.height = img.len = 0;
    fputc(s, stdout);
    put32(stdout, img.width);
    put32(stdout, img.height);
    put32(stdout, img.len);
    put64(stdout, xxh64(img.pixels, img.len));
    free(img.pixels);
  }
  return fflush(stdout) == 0 ? 0 : 1;
}

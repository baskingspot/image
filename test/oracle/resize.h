// The resize oracles' requests (test/fuzz/resize.zig): the header, and the
// source's samples made from the bytes after it. Shared by resize.c and
// resize_stb097.c.
#ifndef RESIZE_H
#define RESIZE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "oracle.h"

enum { FILTER_DEFAULT, FILTER_POINT, FILTER_BOX, FILTER_TRIANGLE, FILTER_B_SPLINE,
       FILTER_CATMULL_ROM, FILTER_MITCHELL, FILTER_LANCZOS3, FILTERS };
enum { EDGE_CLAMP, EDGE_REFLECT, EDGE_WRAP, EDGE_ZERO, EDGES };

#define HEADER_LEN 10
#define MAX_SIDE 1024
#define MAX_PIXELS (1 << 16)

struct request {
  int filter, edge, srgb;
  uint32_t sw, sh, dw, dh;
  const uint8_t *samples;
  size_t samples_len;
};

static inline uint32_t side(const uint8_t *b) { return 1 + (uint32_t)(b[0] | b[1] << 8) % MAX_SIDE; }

static inline int parse(const uint8_t *in, size_t len, struct request *r) {
  if (len < HEADER_LEN) return 0;
  r->filter = in[0] % FILTERS;
  r->edge = (in[1] & 0x7f) % EDGES;
  r->srgb = (in[1] & 0x80) != 0;
  r->sw = side(in + 2);
  r->sh = side(in + 4);
  r->dw = side(in + 6);
  r->dh = side(in + 8);
  r->samples = in + HEADER_LEN;
  r->samples_len = len - HEADER_LEN;
  return r->sw * r->sh <= MAX_PIXELS && r->dw * r->dh <= MAX_PIXELS;
}

static inline uint8_t next_byte(const struct request *r, size_t *at) {
  if (!r->samples_len) return 0;
  return r->samples[(*at)++ % r->samples_len];
}

enum sample { S_U8, S_U16, S_F32 };

static inline enum sample sample_of(enum pixel_format f) {
  switch (f) {
    case PF_GRAY16: case PF_GRAY_ALPHA16: case PF_GRAY_ALPHA16_PREMUL: case PF_RGB16: case PF_BGR16:
    case PF_RGBA16: case PF_RGBA16_PREMUL: case PF_BGRA16: case PF_BGRA16_PREMUL: case PF_CMYK16:
      return S_U16;
    case PF_RGBA_F32: case PF_RGBA_F32_PREMUL: case PF_RGB_F32: case PF_GRAY_F32: return S_F32;
    default: return S_U8;
  }
}

static inline size_t sample_bytes(enum sample s) { return s == S_U8 ? 1 : s == S_U16 ? 2 : 4; }

// The source's samples, as test/fuzz/resize.zig makes them: with
// `alpha` set, sample `alpha` of every pixel of `channels` is at least half
// its range.
static inline void make_source(const struct request *r, enum sample s, uint8_t *px, size_t n, size_t channels,
                               int alpha) {
  size_t at = 0;
  for (size_t i = 0; i < n; i++) {
    int high = alpha >= 0 && (int)(i % channels) == alpha;
    if (s == S_U8) {
      uint8_t b = next_byte(r, &at);
      px[i] = high ? 128 + (b >> 1) : b;
    } else if (s == S_U16) {
      uint16_t lo = next_byte(r, &at);
      uint16_t v = (uint16_t)(next_byte(r, &at) << 8 | lo);
      if (high) v = 32768 + (v >> 1);
      memcpy(px + 2 * i, &v, 2);
    } else {
      uint8_t b = next_byte(r, &at);
      float v = (high ? 128 + (b >> 1) : b) / 255.0f;
      memcpy(px + 4 * i, &v, 4);
    }
  }
}

#endif

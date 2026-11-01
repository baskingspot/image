// stb_image's BMP decoder (it has no RLE) to RGBA, and stb_image_write's
// BMP encoder: 24-bit from RGB and gray, 32-bit (a BITMAPV4HEADER) from
// RGBA. stb_image allocates the pixels, so a decode is a load and a free,
// and only `check` copies them out.
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define STBI_NO_STDIO
#include "stb/stb_image.h"

// Static, so another format's file can compile stb_image_write too.
#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#pragma GCC diagnostic ignored "-Wunused-function"
#include "stb/stb_image_write.h"

#include "arm.h"

static size_t bmp_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  int w, h, comp;
  uint8_t *px = stbi_load_from_memory(in, (int)len, &w, &h, &comp, 4);
  if (!px) return 0;
  size_t n = (size_t)w * h * 4;
  if (bench_checking && n <= cap) memcpy(out, px, n);
  stbi_image_free(px);
  return n <= cap ? n : 0;
}

struct sink {
  uint8_t *out;
  size_t cap, len;
};

static void put(void *context, void *data, int size) {
  struct sink *s = context;
  if (s->len + size <= s->cap) memcpy(s->out + s->len, data, size);
  s->len += size;
}

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int comp) {
  int side = (int)sqrt((double)(len / comp));
  struct sink s = {out, cap, 0};
  if (!stbi_write_bmp_to_func(put, &s, side, side, comp, in)) return 0;
  return s.len <= cap ? s.len : 0;
}

static size_t bmp_encode_rgb(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 3);
}

static size_t bmp_encode_rgba(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 4);
}

static size_t bmp_encode_gray(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 1);
}

BENCH_OP("bmp-decode", bmp_decode)
BENCH_OP("bmp-encode-rgb", bmp_encode_rgb)
BENCH_OP("bmp-encode-rgba", bmp_encode_rgba)
BENCH_OP("bmp-encode-gray", bmp_encode_gray)

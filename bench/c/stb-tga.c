// stb_image's TGA decoder and stb_image_write's TGA encoder. stb_image
// allocates the pixels, in the file's own channels in RGB order, so a call
// is a decode and a free; only `check` copies them out. stb_image_write
// writes through a callback, here into the output buffer; its run-length
// switch is a global it reads per call.
#include <stdlib.h>
#include <string.h>

#include "stb/stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_STATIC
#include "stb/stb_image_write.h"

#include "arm.h"

static size_t tga_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  int w, h, comp;
  uint8_t *px = stbi_load_from_memory(in, (int)len, &w, &h, &comp, 0);
  if (!px) return 0;
  size_t n = (size_t)w * h * comp;
  if (bench_checking && n <= cap) memcpy(out, px, n);
  stbi_image_free(px);
  return n <= cap ? n : 0;
}

static size_t tga_decode_rle(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return tga_decode(in, len, out, cap);
}

struct sink {
  uint8_t *out;
  size_t cap, len;
  int failed;
};

static void put(void *context, void *data, int size) {
  struct sink *s = context;
  if (s->len + size > s->cap) {
    s->failed = 1;
    return;
  }
  memcpy(s->out + s->len, data, size);
  s->len += size;
}

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int rle) {
  size_t pixels = (size_t)bench_width * bench_height;
  if (!pixels || len % pixels) return 0;
  int comp = (int)(len / pixels);
  struct sink s = {out, cap, 0, 0};
  stbi_write_tga_with_rle = rle;
  if (!stbi_write_tga_to_func(put, &s, (int)bench_width, (int)bench_height, comp, in) || s.failed)
    return 0;
  return s.len;
}

static size_t tga_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 0);
}

static size_t tga_encode_rle(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 1);
}

BENCH_OP("tga-decode", tga_decode)
BENCH_OP("tga-decode-rle", tga_decode_rle)
BENCH_OP("tga-encode", tga_encode)
BENCH_OP("tga-encode-rle", tga_encode_rle)

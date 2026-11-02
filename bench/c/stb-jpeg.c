// stb_image's JPEG decoder, to RGB8. Its API allocates the pixels, so a
// call is stbi_load_from_memory and free; only `check` copies them out.
// stb_image_write's JPEG encoder for the encode rows it has: baseline at
// quality 85 (4:2:0) and 95 (where it stops subsampling), RGB or gray,
// writing through a callback into the output buffer.
#include <stdlib.h>
#include <string.h>

#include "stb/stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#define STB_IMAGE_WRITE_STATIC
#include "stb/stb_image_write.h"

#include "arm.h"

static size_t jpeg_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  int w, h, n;
  stbi_uc *px = stbi_load_from_memory(in, (int)len, &w, &h, &n, 3);
  if (!px) return 0;
  size_t size = (size_t)w * h * 3;
  if (bench_checking && size <= cap) memcpy(out, px, size);
  stbi_image_free(px);
  return size <= cap ? size : 0;
}

// The same call on every row; BENCH_OP needs a function per registration.
static size_t jpeg_progressive(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_444(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_cmyk(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}

BENCH_OP("jpeg-decode", jpeg_decode)
BENCH_OP("jpeg-decode-progressive", jpeg_progressive)
BENCH_OP("jpeg-decode-444", jpeg_444)
BENCH_OP("jpeg-decode-cmyk", jpeg_cmyk)

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

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int comp, int quality) {
  if (len != (size_t)bench_width * bench_height * comp) return 0;
  struct sink s = {out, cap, 0, 0};
  if (!stbi_write_jpg_to_func(put, &s, (int)bench_width, (int)bench_height, comp, in, quality) ||
      s.failed)
    return 0;
  return s.len;
}

static size_t jpeg_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 3, 85);
}
static size_t jpeg_encode_444(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 3, 95);
}
static size_t jpeg_encode_gray(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 1, 85);
}

BENCH_OP("jpeg-encode", jpeg_encode)
BENCH_OP("jpeg-encode-444", jpeg_encode_444)
BENCH_OP("jpeg-encode-gray", jpeg_encode_gray)

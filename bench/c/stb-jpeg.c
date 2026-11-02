// stb_image's JPEG decoder, to RGB8. Its API allocates the pixels, so a
// call is stbi_load_from_memory and free; only `check` copies them out.
#include <stdlib.h>
#include <string.h>

#include "stb/stb_image.h"

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

BENCH_OP("jpeg-decode", jpeg_decode)
BENCH_OP("jpeg-decode-progressive", jpeg_progressive)
BENCH_OP("jpeg-decode-444", jpeg_444)

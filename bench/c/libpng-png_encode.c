// libpng's encoder, writing raw RGB or RGBA pixels, at the size the harness
// gives (`bench_width`, `bench_height`), into the output buffer: the default
// zlib level (6) and libpng's default adaptive filters, and level 1 for the
// fast row. libpng writes the pixels' own color type; it does not reduce.
#include <png.h>
#include <setjmp.h>
#include <string.h>

#include "arm.h"

struct sink {
  uint8_t *out;
  size_t cap, len;
};

static void write_fn(png_structp png, png_bytep data, size_t n) {
  struct sink *s = png_get_io_ptr(png);
  if (s->cap - s->len < n) png_error(png, "full");
  memcpy(s->out + s->len, data, n);
  s->len += n;
}

static void flush_fn(png_structp png) { (void)png; }

static void quiet(png_structp png, png_const_charp msg) {
  (void)png;
  (void)msg;
}

static void fail(png_structp png, png_const_charp msg) {
  (void)msg;
  png_longjmp(png, 1);
}

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int level) {
  uint32_t w = bench_width, h = bench_height;
  size_t pixels = (size_t)w * h;
  if (!pixels || len % pixels) return 0;
  size_t channels = len / pixels;
  const uint8_t *px = in;
  struct sink s = {out, cap, 0};
  png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, fail, quiet);
  png_infop info = png_create_info_struct(png);
  volatile size_t result = 0;
  if (setjmp(png_jmpbuf(png))) goto done;
  png_set_write_fn(png, &s, write_fn, flush_fn);
  png_set_user_limits(png, 0x7fffffff, 0x7fffffff);
  if (level >= 0) png_set_compression_level(png, level);
  png_set_IHDR(png, info, w, h, 8, channels == 4 ? PNG_COLOR_TYPE_RGBA : PNG_COLOR_TYPE_RGB,
               PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
  png_write_info(png, info);
  for (uint32_t y = 0; y < h; y++) png_write_row(png, px + (size_t)y * w * channels);
  png_write_end(png, NULL);
  result = s.len;
done:
  png_destroy_write_struct(&png, &info);
  return result;
}

static size_t png_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, -1);
}

static size_t png_encode_fast(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 1);
}

BENCH_OP("png-encode", png_encode)
BENCH_OP("png-encode-fast", png_encode_fast)

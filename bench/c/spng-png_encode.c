// libspng's encoder, encoding raw RGB or RGBA pixels, at the size the
// harness gives (`bench_width`, `bench_height`), to its own buffer, which only
// `check` copies out: the default zlib level (6) and filter choice (all),
// and level 1 for the fast row. libspng writes the pixels' own color type;
// it does not reduce.
#include <spng.h>
#include <stdlib.h>
#include <string.h>

#include "arm.h"

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int level) {
  uint32_t w = bench_width, h = bench_height;
  size_t pixels = (size_t)w * h;
  if (!pixels || len % pixels) return 0;
  size_t channels = len / pixels;
  spng_ctx *ctx = spng_ctx_new(SPNG_CTX_ENCODER);
  size_t n = 0;
  int err = 0;
  struct spng_ihdr ihdr = {
      .width = w,
      .height = h,
      .bit_depth = 8,
      .color_type = channels == 4 ? SPNG_COLOR_TYPE_TRUECOLOR_ALPHA : SPNG_COLOR_TYPE_TRUECOLOR,
  };
  spng_set_option(ctx, SPNG_ENCODE_TO_BUFFER, 1);
  if (level >= 0) spng_set_option(ctx, SPNG_IMG_COMPRESSION_LEVEL, level);
  if (spng_set_ihdr(ctx, &ihdr) ||
      spng_encode_image(ctx, in, len, SPNG_FMT_PNG, SPNG_ENCODE_FINALIZE)) {
    spng_ctx_free(ctx);
    return 0;
  }
  void *png = spng_get_png_buffer(ctx, &n, &err);
  if (!png || err || n > cap) n = 0;
  else if (bench_checking) memcpy(out, png, n);
  free(png);
  spng_ctx_free(ctx);
  return n;
}

static size_t png_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, -1);
}

static size_t png_encode_fast(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 1);
}

BENCH_OP("png-encode", png_encode)
BENCH_OP("png-encode-fast", png_encode_fast)

// libspng, from memory, to RGBA8 with tRNS applied, into the caller's
// buffer.
#include <spng.h>

#include "arm.h"

static size_t png_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  spng_ctx *ctx = spng_ctx_new(0);
  size_t n = 0;
  if (spng_set_png_buffer(ctx, in, len) || spng_decoded_image_size(ctx, SPNG_FMT_RGBA8, &n) ||
      n > cap || spng_decode_image(ctx, out, n, SPNG_FMT_RGBA8, SPNG_DECODE_TRNS))
    n = 0;
  spng_ctx_free(ctx);
  return n;
}

BENCH_OP("png-decode", png_decode)

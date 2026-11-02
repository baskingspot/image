// Wuffs's JPEG decoder, to RGB8. The decoder lives in static memory and is
// initialized per call, as a caller that reuses it would; its work buffer
// (every component's coefficients and samples) is kept between calls.
#include <stdlib.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_jpeg__decoder *dec;

static size_t jpeg_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (!dec) dec = malloc(sizeof__wuffs_jpeg__decoder());
  wuffs_base__status st =
      wuffs_jpeg__decoder__initialize(dec, sizeof__wuffs_jpeg__decoder(), WUFFS_VERSION,
                                      WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  return wuffs_arm_decode(wuffs_jpeg__decoder__upcast_as__wuffs_base__image_decoder(dec), in, len,
                          out, cap, WUFFS_BASE__PIXEL_FORMAT__RGB);
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

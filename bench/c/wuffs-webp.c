// Wuffs's WebP decoder, which reads lossless files, to RGBA8. The decoder
// lives in static memory and is initialized per call, as a caller that
// reuses it would.
#include <stdlib.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_webp__decoder *dec;

static size_t webp_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (!dec) dec = malloc(sizeof__wuffs_webp__decoder());
  wuffs_base__status st =
      wuffs_webp__decoder__initialize(dec, sizeof__wuffs_webp__decoder(), WUFFS_VERSION,
                                      WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  return wuffs_arm_decode(wuffs_webp__decoder__upcast_as__wuffs_base__image_decoder(dec), in, len,
                          out, cap, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL);
}

BENCH_OP("webp-decode-lossless", webp_decode)

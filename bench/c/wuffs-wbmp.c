// Wuffs's WBMP decoder: to gray (Y), as WBMP stores it, and to RGBA. The
// decoder lives in static memory and is initialized per call, as a caller
// that reuses it would.
#include <stdlib.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_wbmp__decoder *dec;

static size_t decode_as(const uint8_t *in, size_t len, uint8_t *out, size_t cap, uint32_t fmt) {
  if (!dec) dec = malloc(sizeof__wuffs_wbmp__decoder());
  wuffs_base__status st =
      wuffs_wbmp__decoder__initialize(dec, sizeof__wuffs_wbmp__decoder(), WUFFS_VERSION,
                                      WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  return wuffs_arm_decode(wuffs_wbmp__decoder__upcast_as__wuffs_base__image_decoder(dec), in, len,
                          out, cap, fmt);
}

static size_t wbmp_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, WUFFS_BASE__PIXEL_FORMAT__Y);
}

static size_t wbmp_decode_rgba(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL);
}

BENCH_OP("wbmp-decode", wbmp_decode)
BENCH_OP("wbmp-decode-rgba", wbmp_decode_rgba)

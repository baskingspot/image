// Wuffs's QOI decoder: to RGB or RGBA as the file has them (the bytes this
// package's native decode writes), and to BGRA, Wuffs's own order. The
// decoder lives in static memory and is initialized per call, as a caller
// that reuses it would.
#include <string.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_qoi__decoder *dec;

static size_t decode_as(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int bgra) {
  if (!dec) dec = malloc(sizeof__wuffs_qoi__decoder());
  wuffs_base__status st =
      wuffs_qoi__decoder__initialize(dec, sizeof__wuffs_qoi__decoder(), WUFFS_VERSION,
                                     WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  // The channel count is in the header; Wuffs reports it as BGRX or BGRA.
  uint32_t fmt = bgra ? WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL
                 : (len > 12 && in[12] == 3) ? WUFFS_BASE__PIXEL_FORMAT__RGB
                                             : WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL;
  return wuffs_arm_decode(wuffs_qoi__decoder__upcast_as__wuffs_base__image_decoder(dec), in, len,
                          out, cap, fmt);
}

static size_t qoi_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, 0);
}

static size_t qoi_decode_bgra(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, 1);
}

BENCH_OP("qoi-decode", qoi_decode)
BENCH_OP("qoi-decode-bgra", qoi_decode_bgra)

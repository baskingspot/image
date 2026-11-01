// Wuffs's Netpbm decoder, which reads raw PGM and PPM with maxval 255 or
// 65535: to gray or RGB as the file has them (the bytes this package's
// native decode writes), to RGBA, and 16-bit PPM to 16-bit BGRA, the only
// 16-bit color it writes. The decoder lives in static memory and is
// initialized per call, as a caller that reuses it would.
#include <string.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_netpbm__decoder *dec;

static size_t decode_as(const uint8_t *in, size_t len, uint8_t *out, size_t cap, uint32_t fmt) {
  if (!dec) dec = malloc(sizeof__wuffs_netpbm__decoder());
  wuffs_base__status st =
      wuffs_netpbm__decoder__initialize(dec, sizeof__wuffs_netpbm__decoder(), WUFFS_VERSION,
                                        WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  return wuffs_arm_decode(wuffs_netpbm__decoder__upcast_as__wuffs_base__image_decoder(dec), in,
                          len, out, cap, fmt);
}

#define F(x) WUFFS_BASE__PIXEL_FORMAT__##x
static size_t ppm(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, F(RGB));
}
static size_t ppm_rgba(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, F(RGBA_NONPREMUL));
}
static size_t pgm(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, F(Y));
}
static size_t ppm16_bgra(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, F(BGRA_NONPREMUL_4X16LE));
}

BENCH_OP("netpbm-decode-ppm", ppm)
BENCH_OP("netpbm-decode-ppm-rgba", ppm_rgba)
BENCH_OP("netpbm-decode-pgm", pgm)
BENCH_OP("netpbm-decode-ppm16-bgra", ppm16_bgra)

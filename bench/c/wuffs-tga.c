// Wuffs's TGA decoder: to the file's own channels in RGB order (the bytes
// this package's native decode writes in RGB order), and to BGRA. The
// decoder lives in static memory and is initialized per call, as a caller
// that reuses it would.
#include <string.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_targa__decoder *dec;

static size_t decode_as(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int bgra) {
  if (!dec) dec = malloc(sizeof__wuffs_targa__decoder());
  wuffs_base__status st =
      wuffs_targa__decoder__initialize(dec, sizeof__wuffs_targa__decoder(), WUFFS_VERSION,
                                       WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  // The pixel depth and image type are in the header: gray, RGB, or RGBA.
  uint32_t fmt = WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL;
  if (!bgra && len > 16) {
    int gray = (in[2] & ~8) == 3;
    fmt = gray            ? WUFFS_BASE__PIXEL_FORMAT__Y
          : in[16] == 24 ? WUFFS_BASE__PIXEL_FORMAT__RGB
                         : WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL;
  }
  return wuffs_arm_decode(wuffs_targa__decoder__upcast_as__wuffs_base__image_decoder(dec), in, len,
                          out, cap, fmt);
}

static size_t tga_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, 0);
}

static size_t tga_decode_rle(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, 0);
}

static size_t tga_decode_bgra(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode_as(in, len, out, cap, 1);
}

BENCH_OP("tga-decode", tga_decode)
BENCH_OP("tga-decode-rle", tga_decode_rle)
BENCH_OP("tga-decode-bgra", tga_decode_bgra)

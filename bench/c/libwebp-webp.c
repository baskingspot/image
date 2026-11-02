// libwebp's simple API into the caller's buffer, as RGBA8.
#include <webp/decode.h>

#include "arm.h"

static size_t webp_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  int w, h;
  if (!WebPGetInfo(in, len, &w, &h)) return 0;
  size_t stride = (size_t)w * 4;
  if (stride * h > cap) return 0;
  if (!WebPDecodeRGBAInto(in, len, out, cap, (int)stride)) return 0;
  return stride * h;
}

// One function per row: `BENCH_OP` names its registration after it.
static size_t webp_lossless(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return webp_decode(in, len, out, cap);
}

static size_t webp_lossless_large(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return webp_decode(in, len, out, cap);
}

static size_t webp_lossy(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return webp_decode(in, len, out, cap);
}

BENCH_OP("webp-decode-lossless", webp_lossless)
BENCH_OP("webp-decode-lossless-large", webp_lossless_large)
BENCH_OP("webp-decode-lossy", webp_lossy)

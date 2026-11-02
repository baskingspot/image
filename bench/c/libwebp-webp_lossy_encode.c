// libwebp's lossy encoder, from raw RGB or RGBA pixels at the size the
// harness gives (`bench_width`, `bench_height`), into the output buffer:
// quality 75 and libwebp's defaults otherwise, as `cwebp -q 75 -m M`,
// with method 4 (cwebp's default) for the default and RGBA rows, 2 for
// the fast row, and 6 for the best.
#include <string.h>
#include <webp/encode.h>

#include "arm.h"

struct sink {
  uint8_t *out;
  size_t cap, len;
};

static int write_fn(const uint8_t *data, size_t n, const WebPPicture *pic) {
  struct sink *s = pic->custom_ptr;
  if (s->cap - s->len < n) return 0;
  memcpy(s->out + s->len, data, n);
  s->len += n;
  return 1;
}

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int method) {
  uint32_t w = bench_width, h = bench_height;
  size_t pixels = (size_t)w * h;
  if (!pixels || len % pixels) return 0;
  size_t channels = len / pixels;
  if (channels != 3 && channels != 4) return 0;
  WebPConfig config;
  if (!WebPConfigInit(&config)) return 0;
  config.quality = 75;
  config.method = method;
  WebPPicture pic;
  if (!WebPPictureInit(&pic)) return 0;
  pic.width = (int)w;
  pic.height = (int)h;
  int ok = channels == 4 ? WebPPictureImportRGBA(&pic, in, (int)(w * 4))
                         : WebPPictureImportRGB(&pic, in, (int)(w * 3));
  struct sink s = {out, cap, 0};
  pic.writer = write_fn;
  pic.custom_ptr = &s;
  if (ok) ok = WebPEncode(&config, &pic);
  WebPPictureFree(&pic);
  return ok ? s.len : 0;
}

// One function per row: `BENCH_OP` names its registration after it.
static size_t webp_lossy_default(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 4);
}

static size_t webp_lossy_fast(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 2);
}

static size_t webp_lossy_best(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 6);
}

static size_t webp_lossy_rgba(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 4);
}

BENCH_OP("webp-encode-lossy", webp_lossy_default)
BENCH_OP("webp-encode-lossy-fast", webp_lossy_fast)
BENCH_OP("webp-encode-lossy-best", webp_lossy_best)
BENCH_OP("webp-encode-lossy-rgba", webp_lossy_rgba)

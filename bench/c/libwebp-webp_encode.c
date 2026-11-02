// libwebp's lossless encoder, writing raw RGB or RGBA pixels
// (bench/corpus/webp_encode.sh) into the output buffer: one row per
// `cwebp -lossless -z` level, through WebPConfigLosslessPreset, with
// `exact` set so that transparent pixels keep their colors, as this
// package's encoder keeps them.
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

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int level) {
  size_t n = (size_t)bench_width * bench_height;
  if (n == 0) return 0;
  size_t channels = len / n;
  if (channels * n != len || (channels != 3 && channels != 4)) return 0;
  WebPConfig config;
  if (!WebPConfigInit(&config) || !WebPConfigLosslessPreset(&config, level)) return 0;
  config.exact = 1;
  WebPPicture pic;
  if (!WebPPictureInit(&pic)) return 0;
  pic.use_argb = 1;
  pic.width = (int)bench_width;
  pic.height = (int)bench_height;
  int ok = channels == 4 ? WebPPictureImportRGBA(&pic, in, (int)(bench_width * 4))
                         : WebPPictureImportRGB(&pic, in, (int)(bench_width * 3));
  struct sink s = {out, cap, 0};
  pic.writer = write_fn;
  pic.custom_ptr = &s;
  if (ok) ok = WebPEncode(&config, &pic);
  WebPPictureFree(&pic);
  return ok ? s.len : 0;
}

// One function per row: `BENCH_OP` names its registration after it.
#define LEVEL(k)                                                                    \
  static size_t webp_encode_z##k(const uint8_t *in, size_t len, uint8_t *out, size_t cap) { \
    return encode(in, len, out, cap, k);                                            \
  }                                                                                 \
  BENCH_OP("webp-encode-z" #k, webp_encode_z##k)

LEVEL(0)
LEVEL(1)
LEVEL(2)
LEVEL(3)
LEVEL(4)
LEVEL(5)
LEVEL(6)
LEVEL(7)
LEVEL(8)
LEVEL(9)

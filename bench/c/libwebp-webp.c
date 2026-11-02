// libwebp's simple API into the caller's buffer, as RGBA8, and its
// animation decoder for animations.
#include <string.h>
#include <webp/decode.h>
#include <webp/demux.h>

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

// libwebp's animation decoder, every frame, the last canvas copied out.
static size_t webp_anim(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  WebPData data = {in, len};
  WebPAnimDecoderOptions opts;
  if (!WebPAnimDecoderOptionsInit(&opts)) return 0;
  opts.color_mode = MODE_RGBA;
  opts.use_threads = 0;
  WebPAnimDecoder *dec = WebPAnimDecoderNew(&data, &opts);
  if (!dec) return 0;
  WebPAnimInfo info;
  size_t n = 0;
  uint8_t *canvas = NULL;
  int timestamp;
  if (WebPAnimDecoderGetInfo(dec, &info)) {
    n = (size_t)info.canvas_width * info.canvas_height * 4;
    while (WebPAnimDecoderHasMoreFrames(dec)) {
      if (!WebPAnimDecoderGetNext(dec, &canvas, &timestamp)) {
        canvas = NULL;
        break;
      }
    }
    if (canvas && n <= cap) {
      memcpy(out, canvas, n);
    } else {
      n = 0;
    }
  }
  WebPAnimDecoderDelete(dec);
  return n;
}

BENCH_OP("webp-decode-lossless", webp_lossless)
BENCH_OP("webp-decode-lossless-large", webp_lossless_large)
BENCH_OP("webp-decode-lossy", webp_lossy)
BENCH_OP("webp-decode-anim", webp_anim)

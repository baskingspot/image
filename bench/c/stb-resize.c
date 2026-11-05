// stb_image_resize2, the resize rows' bar: stbir_resize_uint8_linear (or
// _srgb) with its defaults, Mitchell shrinking and Catmull-Rom growing,
// edges clamped, to the sizes bench/zig/resize.zig computes. It allocates
// its working memory on every call.
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb/stb_image_resize2.h"

#include "arm.h"
#include "resize-sizes.h"

static size_t run(const uint8_t *in, size_t len, uint8_t *out, size_t cap, stbir_pixel_layout layout,
                  size_t bpp, enum resize_size size, int srgb) {
  if (len != (size_t)bench_width * bench_height * bpp) return 0;
  uint32_t dw, dh;
  resize_size_of(size, bench_width, bench_height, &dw, &dh);
  size_t n = (size_t)dw * dh * bpp;
  if (n > cap) return 0;
  void *ok = srgb ? stbir_resize_uint8_srgb(in, (int)bench_width, (int)bench_height, 0, out, (int)dw, (int)dh, 0, layout)
                  : stbir_resize_uint8_linear(in, (int)bench_width, (int)bench_height, 0, out, (int)dw, (int)dh, 0, layout);
  return ok ? n : 0;
}

static size_t gray8_quarter(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_1CHANNEL, 1, RESIZE_QUARTER, 0);
}
static size_t gray8_double(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_1CHANNEL, 1, RESIZE_DOUBLE, 0);
}
static size_t bgra8p_quarter(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_BGRA_PM, 4, RESIZE_QUARTER, 0);
}
static size_t bgra8p_double(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_BGRA_PM, 4, RESIZE_DOUBLE, 0);
}
static size_t rgb8_thumb256(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_RGB, 3, RESIZE_THUMB256, 0);
}
static size_t rgb8_thumb1024(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_RGB, 3, RESIZE_THUMB1024, 0);
}
static size_t rgb8_double(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_RGB, 3, RESIZE_DOUBLE, 0);
}
static size_t rgba8_half(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_RGBA, 4, RESIZE_HALF, 0);
}
static size_t rgb8_srgb_thumb256(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, STBIR_RGB, 3, RESIZE_THUMB256, 1);
}

BENCH_OP("resize-gray8-quarter", gray8_quarter)
BENCH_OP("resize-gray8-double", gray8_double)
BENCH_OP("resize-bgra8p-quarter", bgra8p_quarter)
BENCH_OP("resize-bgra8p-double", bgra8p_double)
BENCH_OP("resize-rgb8-thumb256", rgb8_thumb256)
BENCH_OP("resize-rgb8-thumb1024", rgb8_thumb1024)
BENCH_OP("resize-rgb8-double", rgb8_double)
BENCH_OP("resize-rgba8-half", rgba8_half)
BENCH_OP("resize-rgb8-srgb-thumb256", rgb8_srgb_thumb256)

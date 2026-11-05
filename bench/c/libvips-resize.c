// libvips, a production resizer, as a resize arm: vips_reduce with
// Mitchell to shrink (vips_reduceh and vips_reducev called one after the
// other, without the line cache vips_reduce puts between them, ran about
// four times slower), and to grow, which reduce refuses, vips_resize,
// whose upsizing interpolates with Catmull-Rom (its bicubic), as the rows'
// defaults pick; edges clamped. Straight alpha is premultiplied around it,
// as vips_thumbnail does. One thread and no operation cache, so it times
// the resize and not a pool or a cache hit; the sRGB row is left out
// (libvips filters stored values, and a trip through scRGB would time a
// colorspace conversion). vips_image_write_to_memory returns its own
// buffer, copied out only while checking.
#include <string.h>
#include <vips/vips.h>

#include "arm.h"
#include "resize-sizes.h"

static void start(void) {
  static int started;
  if (started) return;
  started = 1;
  if (VIPS_INIT("bench-libvips")) vips_error_exit(NULL);
  vips_concurrency_set(1);
  vips_cache_set_max(0);
}

static size_t run(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int bands, int alpha,
                  enum resize_size size) {
  start();
  uint32_t w = bench_width, h = bench_height, dw, dh;
  if (len != (size_t)w * h * bands) return 0;
  resize_size_of(size, w, h, &dw, &dh);
  size_t n = (size_t)dw * dh * bands;
  if (n > cap) return 0;
  VipsObject *scope = VIPS_OBJECT(vips_image_new());
  VipsImage **t = (VipsImage **)vips_object_local_array(scope, 6);
  size_t got = 0;
  t[0] = vips_image_new_from_memory(in, len, (int)w, (int)h, bands, VIPS_FORMAT_UCHAR);
  if (!t[0]) goto done;
  VipsImage *x = t[0];
  if (alpha) {
    if (vips_premultiply(x, &t[1], NULL)) goto done;
    x = t[1];
  }
  if (dw > w) {
    if (vips_resize(x, &t[3], (double)dw / w, "vscale", (double)dh / h, "kernel", VIPS_KERNEL_CUBIC, NULL))
      goto done;
  } else if (vips_reduce(x, &t[3], (double)w / dw, (double)h / dh, "kernel", VIPS_KERNEL_MITCHELL, NULL)) {
    goto done;
  }
  x = t[3];
  if (alpha) {
    if (vips_unpremultiply(x, &t[4], NULL) || vips_cast(t[4], &t[5], VIPS_FORMAT_UCHAR, NULL)) goto done;
    x = t[5];
  }
  if (vips_image_get_width(x) != (int)dw || vips_image_get_height(x) != (int)dh) goto done;
  size_t written;
  void *buf = vips_image_write_to_memory(x, &written);
  if (buf && written == n) {
    if (bench_checking) memcpy(out, buf, n);
    got = n;
  }
  g_free(buf);
done:
  g_object_unref(scope);
  return got;
}

static size_t gray8_quarter(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 1, 0, RESIZE_QUARTER);
}
static size_t gray8_double(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 1, 0, RESIZE_DOUBLE);
}
static size_t bgra8p_quarter(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 4, 0, RESIZE_QUARTER);
}
static size_t bgra8p_double(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 4, 0, RESIZE_DOUBLE);
}
static size_t rgb8_thumb256(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 3, 0, RESIZE_THUMB256);
}
static size_t rgb8_thumb1024(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 3, 0, RESIZE_THUMB1024);
}
static size_t rgb8_double(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 3, 0, RESIZE_DOUBLE);
}
static size_t rgba8_half(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return run(in, len, out, cap, 4, 1, RESIZE_HALF);
}

BENCH_OP("resize-gray8-quarter", gray8_quarter)
BENCH_OP("resize-gray8-double", gray8_double)
BENCH_OP("resize-bgra8p-quarter", bgra8p_quarter)
BENCH_OP("resize-bgra8p-double", bgra8p_double)
BENCH_OP("resize-rgb8-thumb256", rgb8_thumb256)
BENCH_OP("resize-rgb8-thumb1024", rgb8_thumb1024)
BENCH_OP("resize-rgb8-double", rgb8_double)
BENCH_OP("resize-rgba8-half", rgba8_half)

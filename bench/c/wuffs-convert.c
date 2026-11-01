// Wuffs's pixel swizzler on the conversion rows, and the decode the Wuffs
// arm's format files share. Wuffs's implementation is compiled here.
#include <stdlib.h>

#define WUFFS_IMPLEMENTATION
#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

size_t wuffs_arm_decode(wuffs_base__image_decoder *dec, const uint8_t *in, size_t len, uint8_t *out,
                        size_t cap, uint32_t pixfmt) {
  static uint8_t *work;
  static size_t work_cap;
  wuffs_base__image_config ic = {0};
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)in, len, true);
  wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(dec, &ic, &src);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
  wuffs_base__pixel_config__set(&ic.pixcfg, pixfmt, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
  size_t n = wuffs_base__pixel_config__pixbuf_len(&ic.pixcfg);
  if (n > cap) return 0;
  wuffs_base__pixel_buffer pb;
  st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg, wuffs_base__make_slice_u8(out, n));
  if (!wuffs_base__status__is_ok(&st)) return 0;
  uint64_t need = wuffs_base__image_decoder__workbuf_len(dec).max_incl;
  if (need > work_cap) {
    free(work);
    work = malloc(need);
    work_cap = need;
  }
  st = wuffs_base__image_decoder__decode_frame(dec, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC,
                                               wuffs_base__make_slice_u8(work, need), NULL);
  return wuffs_base__status__is_ok(&st) ? n : 0;
}

static size_t swizzle(const uint8_t *in, size_t len, uint8_t *out, size_t cap, uint32_t src_fmt,
                      size_t src_bpp, uint32_t dst_fmt, size_t dst_bpp) {
  wuffs_base__pixel_swizzler s;
  wuffs_base__status st = wuffs_base__pixel_swizzler__prepare(
      &s, wuffs_base__make_pixel_format(dst_fmt), wuffs_base__empty_slice_u8(),
      wuffs_base__make_pixel_format(src_fmt), wuffs_base__empty_slice_u8(),
      WUFFS_BASE__PIXEL_BLEND__SRC);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  size_t n = len / src_bpp;
  if (n * dst_bpp > cap) return 0;
  return dst_bpp * wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice(
                       &s, wuffs_base__make_slice_u8(out, n * dst_bpp), wuffs_base__empty_slice_u8(),
                       wuffs_base__make_slice_u8((uint8_t *)in, len));
}

#define F(x) WUFFS_BASE__PIXEL_FORMAT__##x
static size_t rgba8_bgra8(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return swizzle(in, len, out, cap, F(RGBA_NONPREMUL), 4, F(BGRA_NONPREMUL), 4);
}
static size_t rgb8_rgba8(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return swizzle(in, len, out, cap, F(RGB), 3, F(RGBA_NONPREMUL), 4);
}
static size_t rgba8_rgb8(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return swizzle(in, len, out, cap, F(RGBA_NONPREMUL), 4, F(RGB), 3);
}
static size_t rgba8_premul(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return swizzle(in, len, out, cap, F(RGBA_NONPREMUL), 4, F(RGBA_PREMUL), 4);
}
static size_t gray8_rgba8(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return swizzle(in, len, out, cap, F(Y), 1, F(RGBA_NONPREMUL), 4);
}
static size_t rgba16_rgba8(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  // Wuffs narrows only BGRA order; the same bytes for RGBA, as narrowing
  // keeps the channel order.
  return swizzle(in, len, out, cap, F(BGRA_NONPREMUL_4X16LE), 8, F(BGRA_NONPREMUL), 4);
}

BENCH_OP("convert-rgba8-bgra8", rgba8_bgra8)
BENCH_OP("convert-rgb8-rgba8", rgb8_rgba8)
BENCH_OP("convert-rgba8-rgb8", rgba8_rgb8)
BENCH_OP("convert-rgba8-premul", rgba8_premul)
BENCH_OP("convert-gray8-rgba8", gray8_rgba8)
BENCH_OP("convert-rgba16-rgba8", rgba16_rgba8)

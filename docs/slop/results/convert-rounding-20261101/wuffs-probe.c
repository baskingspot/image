// Wuffs's pixel swizzler for wuffs-probe.zig, by the index of image's
// PixelFormat (16-bit samples little endian, as on the machine that ran it).
#define WUFFS_IMPLEMENTATION
#include "wuffs-v0.4.c"

#define F(x) WUFFS_BASE__PIXEL_FORMAT__##x
static const uint32_t formats[20] = {
    F(Y), F(YA_NONPREMUL), F(YA_PREMUL), F(RGB), F(BGR), F(RGBA_NONPREMUL), F(RGBA_PREMUL),
    F(BGRA_NONPREMUL), F(BGRA_PREMUL), F(Y_16LE), 0, 0, 0, 0, F(RGBA_NONPREMUL_4X16LE),
    F(RGBA_PREMUL_4X16LE), F(BGRA_NONPREMUL_4X16LE), F(BGRA_PREMUL_4X16LE), 0, 0,
};

// Bytes written, or 0 when Wuffs lacks the pair.
size_t probe_wuffs_swizzle(uint8_t dst, uint8_t src, uint8_t *out, size_t out_len, const uint8_t *in,
                           size_t in_len) {
  if (!formats[dst] || !formats[src]) return 0;
  wuffs_base__pixel_swizzler s;
  wuffs_base__status st = wuffs_base__pixel_swizzler__prepare(
      &s, wuffs_base__make_pixel_format(formats[dst]), wuffs_base__empty_slice_u8(),
      wuffs_base__make_pixel_format(formats[src]), wuffs_base__empty_slice_u8(),
      WUFFS_BASE__PIXEL_BLEND__SRC);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  return wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice(
      &s, wuffs_base__make_slice_u8(out, out_len), wuffs_base__empty_slice_u8(),
      wuffs_base__make_slice_u8((uint8_t *)in, in_len));
}

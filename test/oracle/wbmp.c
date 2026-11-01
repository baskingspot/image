// WBMP's oracles: Wuffs, the bar, and ImageMagick's MagickWand.
#include "wuffs-v0.4.c"

#include "oracle.h"

static enum status wbmp_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  return wuffs_decode(wuffs_wbmp__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// ImageMagick reads WBMP only when told to, since it has no signature;
// any warning rejects, as a truncated file is only a warning to it.
static enum status wbmp_magick(const uint8_t *in, size_t len, enum pixel_format format,
                               uint64_t max_pixels, struct image *out) {
  static const struct magick how = {.format = "WBMP", .reject_warnings = 1};
  return magick_decode(&how, in, len, format, max_pixels, out);
}

const struct op wbmp_ops[] = {
    {"wbmp-wuffs", wbmp_wuffs},
    {"wbmp-magick", wbmp_magick},
    {0},
};

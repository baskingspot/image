// ICO's and CUR's oracle: ImageMagick through MagickWand (magick.c), the
// only reference library here that reads them. Its first image is the
// directory's first entry. Warnings reject, as for BMP (bmp.c).
#include "oracle.h"

static enum status ico_magick(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  const char *magick = len > 2 && in[2] == 2 ? "CUR" : "ICO";
  return magick_decode(&(struct magick){.format = magick, .reject_warnings = 1}, in, len, format,
                       max_pixels, out);
}

const struct op ico_ops[] = {
    {"ico-magick", ico_magick},
    {0},
};

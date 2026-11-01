// ICO's and CUR's oracle: ImageMagick through MagickWand (bmp.c), the only
// reference library here that reads them. Its first image is the
// directory's first entry.
#include "oracle.h"

enum status bmp_magick_decode(const char *magick, const uint8_t *in, size_t len,
                              enum pixel_format format, uint64_t max_pixels, struct image *out);

static enum status ico_magick(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  return bmp_magick_decode(len > 2 && in[2] == 2 ? "CUR" : "ICO", in, len, format, max_pixels, out);
}

const struct op ico_ops[] = {
    {"ico-magick", ico_magick},
    {0},
};

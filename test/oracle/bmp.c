// BMP's oracles: Wuffs, the bar; stb_image; and ImageMagick through
// MagickWand (magick.c).
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

// Static, so another format's file can compile stb_image too.
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_BMP
// Static leaves the parts STBI_ONLY_BMP drops declared and unused.
#pragma GCC diagnostic ignored "-Wunused-function"
#include "stb/stb_image.h"

#include "oracle.h"

static enum status bmp_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  return wuffs_decode(wuffs_bmp__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// stb_image writes RGBA; BGRA is a swap away.
static enum status bmp_stb(const uint8_t *in, size_t len, enum pixel_format format,
                           uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8 && format != PF_BGRA8) return STATUS_SKIPPED;
  int w, h, comp;
  if (len > 0x7fffffff) return STATUS_REJECTED;
  if (!stbi_info_from_memory(in, (int)len, &w, &h, &comp)) return STATUS_REJECTED;
  if ((uint64_t)w * (uint64_t)h > max_pixels) return STATUS_TOO_LARGE;
  uint8_t *px = stbi_load_from_memory(in, (int)len, &w, &h, &comp, 4);
  if (!px) return STATUS_REJECTED;
  size_t n = (size_t)w * h;
  if (format == PF_BGRA8) {
    for (size_t i = 0; i < n; i++) {
      uint8_t t = px[4 * i];
      px[4 * i] = px[4 * i + 2];
      px[4 * i + 2] = t;
    }
  }
  out->width = w;
  out->height = h;
  out->len = n * 4;
  out->pixels = px;
  return STATUS_OK;
}

// MagickWand, warnings included: it reports truncated and malformed BMPs
// as warnings and decodes what it can.
static enum status bmp_magick(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  return magick_decode(&(struct magick){.format = "BMP", .reject_warnings = 1}, in, len, format,
                       max_pixels, out);
}

const struct op bmp_ops[] = {
    {"bmp-wuffs", bmp_wuffs},
    {"bmp-stb", bmp_stb},
    {"bmp-magick", bmp_magick},
    {0},
};

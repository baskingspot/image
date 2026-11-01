// TGA's oracles: Wuffs, the bar; stb_image; and ImageMagick's MagickWand.
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

// Static, so another format's oracle can compile stb_image too.
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_TGA
// STBI_ONLY_TGA leaves functions declared static and undefined, which GCC
// reports at the end of the file.
#pragma GCC diagnostic ignored "-Wunused-function"
#include "stb/stb_image.h"

#include <MagickWand/MagickWand.h>

#include "oracle.h"

// The header's size, which every oracle checks against the limit before
// decoding.
static int too_large(const uint8_t *in, size_t len, uint64_t max_pixels) {
  if (len < 18) return 0;
  uint64_t w = in[12] | in[13] << 8, h = in[14] | in[15] << 8;
  return w * h > max_pixels;
}

static enum status tga_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  return wuffs_decode(wuffs_targa__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// stb_image writes gray, gray and alpha, RGB, or RGBA; BGRA is RGBA
// swapped. Its gray from color is its own luma, so gray is left out.
static enum status tga_stb(const uint8_t *in, size_t len, enum pixel_format format,
                           uint64_t max_pixels, struct image *out) {
  int channels = format == PF_RGB8 ? 3 : (format == PF_RGBA8 || format == PF_BGRA8) ? 4 : 0;
  if (!channels) return STATUS_SKIPPED;
  if (too_large(in, len, max_pixels)) return STATUS_TOO_LARGE;
  int w, h, comp;
  uint8_t *px = stbi_load_from_memory(in, (int)(len > 0x7fffffff ? 0x7fffffff : len), &w, &h, &comp,
                                      channels);
  if (!px) return STATUS_REJECTED;
  out->width = w;
  out->height = h;
  out->len = (size_t)w * h * channels;
  if (format == PF_BGRA8) {
    for (size_t i = 0; i < out->len; i += 4) {
      uint8_t t = px[i];
      px[i] = px[i + 2];
      px[i + 2] = t;
    }
  }
  out->pixels = px;
  return STATUS_OK;
}

// ImageMagick, told the input is TGA, since TGA has no signature.
static enum status tga_magick(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  const char *map = format == PF_RGB8 ? "RGB" : format == PF_RGBA8 ? "RGBA" : format == PF_BGRA8 ? "BGRA" : 0;
  if (!map) return STATUS_SKIPPED;
  if (too_large(in, len, max_pixels)) return STATUS_TOO_LARGE;
  if (!IsMagickWandInstantiated()) {
    MagickWandGenesis();
    MagickSetResourceLimit(ThreadResource, 1);
  }
  MagickWand *wand = NewMagickWand();
  enum status result = STATUS_REJECTED;
  MagickSetFormat(wand, "TGA");
  if (MagickReadImageBlob(wand, in, len) == MagickFalse) goto done;
  ExceptionType severity;
  char *description = MagickGetException(wand, &severity);
  MagickRelinquishMemory(description);
  if (severity >= ErrorException) goto done;
  MagickResetIterator(wand);
  if (MagickNextImage(wand) == MagickFalse) goto done;
  size_t w = MagickGetImageWidth(wand), h = MagickGetImageHeight(wand);
  out->len = w * h * strlen(map);
  out->pixels = malloc(out->len ? out->len : 1);
  if (MagickExportImagePixels(wand, 0, 0, w, h, map, CharPixel, out->pixels) == MagickFalse) {
    free(out->pixels);
    out->pixels = NULL;
    goto done;
  }
  out->width = w;
  out->height = h;
  result = STATUS_OK;
done:
  DestroyMagickWand(wand);
  return result;
}

const struct op tga_ops[] = {
    {"tga-wuffs", tga_wuffs},
    {"tga-stb", tga_stb},
    {"tga-magick", tga_magick},
    {0},
};

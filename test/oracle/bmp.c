// BMP's oracles: Wuffs, the bar; stb_image; and ImageMagick through
// MagickWand. ico.c reuses the MagickWand decode for ICO and CUR.
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

#include <MagickWand/MagickWand.h>

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

// The first image of `in` read as `magick` ("BMP", "ICO", or "CUR") by
// MagickWand. Any exception, warnings included, rejects the input: Magick
// reports truncated and malformed files as warnings and decodes what it
// can.
enum status bmp_magick_decode(const char *magick, const uint8_t *in, size_t len,
                              enum pixel_format format, uint64_t max_pixels, struct image *out) {
  const char *map;
  switch (format) {
    case PF_RGBA8: map = "RGBA"; break;
    case PF_BGRA8: map = "BGRA"; break;
    default: return STATUS_SKIPPED;
  }
  static int ready;
  if (!ready) {
    MagickWandGenesis();
    // An ICO's later entries can claim any size, and Magick reads them all:
    // refuse large ones, and never spill to disk.
    MagickSetResourceLimit(ThreadResource, 1);
    MagickSetResourceLimit(WidthResource, 1 << 16);
    MagickSetResourceLimit(HeightResource, 1 << 16);
    MagickSetResourceLimit(AreaResource, 1 << 24);
    MagickSetResourceLimit(ListLengthResource, 1024);
    MagickSetResourceLimit(MemoryResource, (MagickSizeType)1 << 30);
    MagickSetResourceLimit(MapResource, (MagickSizeType)1 << 30);
    MagickSetResourceLimit(DiskResource, 0);
    ready = 1;
  }
  enum status result = STATUS_REJECTED;
  MagickWand *wand = NewMagickWand();
  MagickSetFormat(wand, magick);
  if (MagickPingImageBlob(wand, in, len) == MagickFalse) goto done;
  MagickResetIterator(wand);
  if (MagickNextImage(wand) == MagickFalse) goto done;
  size_t w = MagickGetImageWidth(wand), h = MagickGetImageHeight(wand);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  ClearMagickWand(wand);
  MagickSetFormat(wand, magick);
  ExceptionType severity;
  if (MagickReadImageBlob(wand, in, len) == MagickFalse) goto done;
  char *msg = MagickGetException(wand, &severity);
  MagickRelinquishMemory(msg);
  if (severity != UndefinedException) goto done;
  MagickResetIterator(wand);
  if (MagickNextImage(wand) == MagickFalse) goto done;
  w = MagickGetImageWidth(wand);
  h = MagickGetImageHeight(wand);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  out->len = w * h * 4;
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

static enum status bmp_magick(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  return bmp_magick_decode("BMP", in, len, format, max_pixels, out);
}

const struct op bmp_ops[] = {
    {"bmp-wuffs", bmp_wuffs},
    {"bmp-stb", bmp_stb},
    {"bmp-magick", bmp_magick},
    {0},
};

// ImageMagick through MagickWand, for any format's oracle (oracle.h has the
// interface).
#include <stdlib.h>

#include <MagickWand/MagickWand.h>

#include "oracle.h"

// Pixels as MagickExportImagePixels writes them: the channel map and the
// storage type. Gray is the red channel, which is the gray of a gray image;
// Magick's luma for a color image is its own.
static int export_map(enum pixel_format format, const char **map, StorageType *storage) {
  *storage = CharPixel;
  switch (format) {
    case PF_GRAY8: *map = "R"; return 1;
    case PF_GRAY_ALPHA8: *map = "RA"; return 1;
    case PF_RGB8: *map = "RGB"; return 1;
    case PF_BGR8: *map = "BGR"; return 1;
    case PF_RGBA8: *map = "RGBA"; return 1;
    case PF_BGRA8: *map = "BGRA"; return 1;
    default: break;
  }
  *storage = ShortPixel;
  switch (format) {
    case PF_GRAY16: *map = "R"; return 1;
    case PF_GRAY_ALPHA16: *map = "RA"; return 1;
    case PF_RGB16: *map = "RGB"; return 1;
    case PF_BGR16: *map = "BGR"; return 1;
    case PF_RGBA16: *map = "RGBA"; return 1;
    case PF_BGRA16: *map = "BGRA"; return 1;
    default: break;
  }
  *storage = FloatPixel;
  if (format == PF_RGBA_F32) {
    *map = "RGBA";
    return 1;
  }
  return 0;
}

static void name(MagickWand *wand, const struct magick *how) {
  if (how->format) MagickSetFormat(wand, how->format);
  if (how->filename) MagickSetFilename(wand, how->filename);
}

// Whether the wand's exception, if any, rejects the input.
static int rejects(MagickWand *wand, const struct magick *how) {
  ExceptionType severity;
  char *message = MagickGetException(wand, &severity);
  MagickRelinquishMemory(message);
  return severity >= (how->reject_warnings ? WarningException : ErrorException);
}

enum status magick_decode(const struct magick *how, const uint8_t *in, size_t len,
                          enum pixel_format format, uint64_t max_pixels, struct image *out) {
  const char *map;
  StorageType storage;
  if (!export_map(format, &map, &storage)) return STATUS_SKIPPED;
  if (!IsMagickWandInstantiated()) {
    MagickWandGenesis();
    // One thread, so answers do not depend on scheduling. A file can claim
    // any size, and some (an ICO's later entries) are read whatever the
    // first image is: refuse large ones, and never spill to disk.
    MagickSetResourceLimit(ThreadResource, 1);
    MagickSetResourceLimit(WidthResource, 1 << 16);
    MagickSetResourceLimit(HeightResource, 1 << 16);
    MagickSetResourceLimit(AreaResource, 1 << 24);
    MagickSetResourceLimit(ListLengthResource, 1024);
    MagickSetResourceLimit(MemoryResource, (MagickSizeType)1 << 30);
    MagickSetResourceLimit(MapResource, (MagickSizeType)1 << 30);
    MagickSetResourceLimit(DiskResource, 0);
  }
  enum status result = STATUS_REJECTED;
  MagickWand *wand = NewMagickWand();
  // Ping first, so a large image is refused before its pixels exist.
  name(wand, how);
  if (MagickPingImageBlob(wand, in, len) == MagickFalse || rejects(wand, how)) goto done;
  MagickResetIterator(wand);
  if (MagickNextImage(wand) == MagickFalse) goto done;
  if ((uint64_t)MagickGetImageWidth(wand) * MagickGetImageHeight(wand) > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  ClearMagickWand(wand);
  name(wand, how);
  if (MagickReadImageBlob(wand, in, len) == MagickFalse || rejects(wand, how)) goto done;
  MagickResetIterator(wand);
  if (MagickNextImage(wand) == MagickFalse) goto done;
  size_t w = MagickGetImageWidth(wand), h = MagickGetImageHeight(wand);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  out->len = w * h * pixel_bytes(format);
  out->pixels = malloc(out->len ? out->len : 1);
  if (MagickExportImagePixels(wand, 0, 0, w, h, map, storage, out->pixels) == MagickFalse) {
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

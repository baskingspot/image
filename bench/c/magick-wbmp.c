// ImageMagick's WBMP coder through MagickWand, the only other library that
// reads and writes WBMP: decode to gray, and encode raw gray (a header of
// little-endian u32s, width, height, and channels; bench/corpus/wbmp_encode.sh),
// which its writer thresholds at half intensity as ours does.
#include <string.h>

#include <MagickWand/MagickWand.h>

#include "arm.h"

static MagickWand *wand;

static void start(void) {
  if (!wand) {
    MagickWandGenesis();
    wand = NewMagickWand();
  }
  ClearMagickWand(wand);
}

static size_t wbmp_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  start();
  MagickSetFormat(wand, "WBMP");
  if (MagickReadImageBlob(wand, in, len) == MagickFalse) return 0;
  size_t w = MagickGetImageWidth(wand), h = MagickGetImageHeight(wand);
  if (w * h > cap) return 0;
  if (MagickExportImagePixels(wand, 0, 0, w, h, "I", CharPixel, out) == MagickFalse) return 0;
  return w * h;
}

static uint32_t le32(const uint8_t *p) {
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static size_t wbmp_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (len < 12) return 0;
  start();
  if (MagickConstituteImage(wand, le32(in), le32(in + 4), "I", CharPixel, in + 12) == MagickFalse)
    return 0;
  if (MagickSetImageFormat(wand, "WBMP") == MagickFalse) return 0;
  size_t n = 0;
  unsigned char *blob = MagickGetImageBlob(wand, &n);
  if (!blob) return 0;
  if (n <= cap) memcpy(out, blob, n);
  MagickRelinquishMemory(blob);
  return n <= cap ? n : 0;
}

BENCH_OP("wbmp-decode", wbmp_decode)
BENCH_OP("wbmp-encode", wbmp_encode)

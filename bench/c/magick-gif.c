// ImageMagick's GIF writer through MagickWand: raw RGBA8
// (bench/corpus/gif_encode.sh) to a file in memory with its defaults, as
// `magick in.png out.gif` writes: an image with at most 256 colors stored
// as it is, any other quantized to 256 with ImageMagick's default dither.
// `gif-encode-anim` adds each whole canvas as a frame, 10 hundredths of a
// second each, looping forever, and optimizes the layers (crops each frame
// to what changes), as `-layers OptimizeFrame` does.
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

static size_t blob_out(MagickWand *w, uint8_t *out, size_t cap, int all) {
  size_t n = 0;
  unsigned char *blob = all ? MagickGetImagesBlob(w, &n) : MagickGetImageBlob(w, &n);
  if (!blob) return 0;
  if (n <= cap) memcpy(out, blob, n);
  MagickRelinquishMemory(blob);
  return n <= cap ? n : 0;
}

static size_t gif_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (len != (size_t)bench_width * bench_height * 4) return 0;
  start();
  if (MagickConstituteImage(wand, bench_width, bench_height, "RGBA", CharPixel, in) == MagickFalse) return 0;
  if (MagickSetImageFormat(wand, "GIF") == MagickFalse) return 0;
  return blob_out(wand, out, cap, 0);
}

static size_t gif_encode_anim(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  size_t canvas = (size_t)bench_width * bench_height * 4;
  if (canvas == 0 || len % canvas != 0) return 0;
  start();
  for (size_t at = 0; at < len; at += canvas) {
    if (MagickConstituteImage(wand, bench_width, bench_height, "RGBA", CharPixel, in + at) == MagickFalse)
      return 0;
    MagickSetImageDelay(wand, 10);
    MagickSetImageDispose(wand, BackgroundDispose);
  }
  MagickSetFirstIterator(wand);
  MagickWand *opt = MagickOptimizeImageLayers(wand);
  if (!opt) return 0;
  size_t n = 0;
  if (MagickSetFormat(opt, "GIF") != MagickFalse && MagickSetImageIterations(opt, 0) != MagickFalse)
    n = blob_out(opt, out, cap, 1);
  DestroyMagickWand(opt);
  return n;
}

static size_t gif_encode_few(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return gif_encode(in, len, out, cap);
}

BENCH_OP("gif-encode", gif_encode)
BENCH_OP("gif-encode-few", gif_encode_few)
BENCH_OP("gif-encode-anim", gif_encode_anim)

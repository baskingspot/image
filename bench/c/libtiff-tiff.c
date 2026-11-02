// libtiff from memory (TIFFClientOpen) to RGBA8. 8-bit RGB in strips, which
// every input but the bilevel ones is (JPEG's YCbCr as RGB, which libjpeg
// converts with JPEGCOLORMODE_RGB), reads each strip with
// TIFFReadEncodedStrip into a buffer kept between calls and expands it, as
// a caller after speed would; anything else goes through
// TIFFReadRGBAImageOriented.
#include <stdlib.h>
#include <string.h>
#include <tiffio.h>

#include "arm.h"

struct source {
  const uint8_t *p;
  toff_t len, at;
};

static tmsize_t read_fn(thandle_t h, void *dst, tmsize_t n) {
  struct source *s = h;
  toff_t left = s->at < s->len ? s->len - s->at : 0;
  if ((toff_t)n > left) n = (tmsize_t)left;
  memcpy(dst, s->p + s->at, (size_t)n);
  s->at += (toff_t)n;
  return n;
}

static tmsize_t write_fn(thandle_t h, void *src, tmsize_t n) {
  (void)h;
  (void)src;
  (void)n;
  return -1;
}

static toff_t seek_fn(thandle_t h, toff_t off, int whence) {
  struct source *s = h;
  if (whence == SEEK_CUR) off += s->at;
  else if (whence == SEEK_END) off += s->len;
  s->at = off;
  return off;
}

static int close_fn(thandle_t h) {
  (void)h;
  return 0;
}

static toff_t size_fn(thandle_t h) { return ((struct source *)h)->len; }

static int map_fn(thandle_t h, void **base, toff_t *size) {
  (void)h;
  (void)base;
  (void)size;
  return 0;
}

static void unmap_fn(thandle_t h, void *base, toff_t size) {
  (void)h;
  (void)base;
  (void)size;
}

static void quiet(const char *module, const char *fmt, va_list ap) {
  (void)module;
  (void)fmt;
  (void)ap;
}

static uint8_t *strip;
static tmsize_t strip_cap;

static size_t tiff_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  TIFFSetErrorHandler(quiet);
  TIFFSetWarningHandler(quiet);
  struct source src = {in, len, 0};
  TIFF *tif = TIFFClientOpen("in", "rm", &src, read_fn, write_fn, seek_fn, close_fn, size_fn, map_fn, unmap_fn);
  if (!tif) return 0;
  size_t result = 0;
  uint32_t w = 0, h = 0, rows = 0;
  uint16_t bits = 0, spp = 0, photometric = 0, planar = PLANARCONFIG_CONTIG;
  TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &w);
  TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
  TIFFGetFieldDefaulted(tif, TIFFTAG_BITSPERSAMPLE, &bits);
  TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLESPERPIXEL, &spp);
  TIFFGetFieldDefaulted(tif, TIFFTAG_PLANARCONFIG, &planar);
  TIFFGetField(tif, TIFFTAG_PHOTOMETRIC, &photometric);
  uint16_t compression = COMPRESSION_NONE;
  TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &compression);
  if (compression == COMPRESSION_JPEG && photometric == PHOTOMETRIC_YCBCR) {
    TIFFSetField(tif, TIFFTAG_JPEGCOLORMODE, JPEGCOLORMODE_RGB);
    photometric = PHOTOMETRIC_RGB;
  }
  size_t n = (size_t)w * h * 4;
  if (n == 0 || n > cap) goto done;
  if (bits == 8 && spp == 3 && photometric == PHOTOMETRIC_RGB && planar == PLANARCONFIG_CONTIG &&
      !TIFFIsTiled(tif) && TIFFGetFieldDefaulted(tif, TIFFTAG_ROWSPERSTRIP, &rows)) {
    if (rows > h) rows = h;
    tmsize_t size = TIFFStripSize(tif);
    if (size > strip_cap) {
      free(strip);
      strip = malloc((size_t)size);
      strip_cap = size;
    }
    uint8_t *o = out;
    for (uint32_t s = 0, y = 0; y < h; s++, y += rows) {
      uint32_t k = h - y < rows ? h - y : rows;
      if (TIFFReadEncodedStrip(tif, s, strip, (tmsize_t)k * w * 3) < 0) goto done;
      for (size_t i = 0; i < (size_t)k * w; i++) {
        o[0] = strip[3 * i];
        o[1] = strip[3 * i + 1];
        o[2] = strip[3 * i + 2];
        o[3] = 0xff;
        o += 4;
      }
    }
  } else if (!TIFFReadRGBAImageOriented(tif, w, h, (uint32_t *)out, ORIENTATION_TOPLEFT, 0)) {
    goto done;
  }
  result = n;
done:
  TIFFClose(tif);
  return result;
}

// The same call on every row; BENCH_OP needs a function per registration.
static size_t tiff_lzw(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return tiff_decode(in, len, out, cap);
}
static size_t tiff_deflate(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return tiff_decode(in, len, out, cap);
}
static size_t tiff_packbits(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return tiff_decode(in, len, out, cap);
}
static size_t tiff_jpeg(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return tiff_decode(in, len, out, cap);
}
static size_t tiff_g4(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return tiff_decode(in, len, out, cap);
}

BENCH_OP("tiff-decode-none", tiff_decode)
BENCH_OP("tiff-decode-lzw", tiff_lzw)
BENCH_OP("tiff-decode-deflate", tiff_deflate)
BENCH_OP("tiff-decode-packbits", tiff_packbits)
BENCH_OP("tiff-decode-jpeg", tiff_jpeg)
BENCH_OP("tiff-decode-g4", tiff_g4)

// libtiff encoding raw RGBA or RGB pixels into the caller's buffer (TIFFClientOpen):
// the rows' compression, Predictor 2 with LZW and Deflate (zlib level 6,
// libtiff's default), and libtiff's default strips of about 8 KiB, each
// copied into a buffer kept between calls before TIFFWriteEncodedStrip,
// which may difference it in place.
#include <stdlib.h>
#include <string.h>
#include <tiffio.h>

#include "arm.h"

struct sink {
  uint8_t *p;
  toff_t cap, len, at;
};

static tmsize_t sink_read(thandle_t h, void *dst, tmsize_t n) {
  struct sink *s = h;
  toff_t left = s->at < s->len ? s->len - s->at : 0;
  if ((toff_t)n > left) n = (tmsize_t)left;
  memcpy(dst, s->p + s->at, (size_t)n);
  s->at += (toff_t)n;
  return n;
}

static tmsize_t sink_write(thandle_t h, void *src, tmsize_t n) {
  struct sink *s = h;
  if (s->at + (toff_t)n > s->cap) return -1;
  memcpy(s->p + s->at, src, (size_t)n);
  s->at += (toff_t)n;
  if (s->at > s->len) s->len = s->at;
  return n;
}

static toff_t sink_seek(thandle_t h, toff_t off, int whence) {
  struct sink *s = h;
  if (whence == SEEK_CUR) off += s->at;
  else if (whence == SEEK_END) off += s->len;
  s->at = off;
  return off;
}

static int sink_close(thandle_t h) {
  (void)h;
  return 0;
}

static toff_t sink_size(thandle_t h) { return ((struct sink *)h)->len; }

static int sink_map(thandle_t h, void **base, toff_t *size) {
  (void)h;
  (void)base;
  (void)size;
  return 0;
}

static void sink_unmap(thandle_t h, void *base, toff_t size) {
  (void)h;
  (void)base;
  (void)size;
}

static uint8_t *strip_buf;
static size_t strip_cap;

static size_t encode(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap,
                     uint16_t compression) {
  uint32_t w = bench_width, h = bench_height;
  if (w == 0 || h == 0) return 0;
  int spp = (int)(in_len / ((size_t)w * h));
  size_t row = (size_t)w * spp;
  if ((spp != 3 && spp != 4) || in_len != row * h) return 0;
  struct sink s = {out, out_cap, 0, 0};
  TIFF *t = TIFFClientOpen("mem", "wl", &s, sink_read, sink_write, sink_seek, sink_close, sink_size,
                           sink_map, sink_unmap);
  if (!t) return 0;
  TIFFSetField(t, TIFFTAG_IMAGEWIDTH, w);
  TIFFSetField(t, TIFFTAG_IMAGELENGTH, h);
  TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, 8);
  TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, spp);
  TIFFSetField(t, TIFFTAG_COMPRESSION, compression);
  TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
  TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
  if (spp == 4) {
    uint16_t extra = EXTRASAMPLE_UNASSALPHA;
    TIFFSetField(t, TIFFTAG_EXTRASAMPLES, 1, &extra);
  }
  if (compression == COMPRESSION_LZW || compression == COMPRESSION_ADOBE_DEFLATE)
    TIFFSetField(t, TIFFTAG_PREDICTOR, PREDICTOR_HORIZONTAL);
  uint32_t rows = TIFFDefaultStripSize(t, 0);
  if (rows > h) rows = h;
  TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, rows);
  size_t need = row * rows;
  if (need > strip_cap) {
    free(strip_buf);
    strip_buf = malloc(need);
    strip_cap = strip_buf ? need : 0;
  }
  int ok = strip_buf != NULL;
  for (uint32_t y = 0; ok && y < h; y += rows) {
    size_t n = (size_t)(h - y < rows ? h - y : rows) * row;
    memcpy(strip_buf, in + (size_t)y * row, n);
    ok = TIFFWriteEncodedStrip(t, y / rows, strip_buf, (tmsize_t)n) >= 0;
  }
  TIFFClose(t);
  return ok ? (size_t)s.len : 0;
}

static size_t encode_none(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap) {
  return encode(in, in_len, out, out_cap, COMPRESSION_NONE);
}
static size_t encode_packbits(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap) {
  return encode(in, in_len, out, out_cap, COMPRESSION_PACKBITS);
}
static size_t encode_lzw(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap) {
  return encode(in, in_len, out, out_cap, COMPRESSION_LZW);
}
static size_t encode_deflate(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_cap) {
  return encode(in, in_len, out, out_cap, COMPRESSION_ADOBE_DEFLATE);
}

BENCH_OP("tiff-encode-none", encode_none)
BENCH_OP("tiff-encode-packbits", encode_packbits)
BENCH_OP("tiff-encode-lzw", encode_lzw)
BENCH_OP("tiff-encode-deflate", encode_deflate)

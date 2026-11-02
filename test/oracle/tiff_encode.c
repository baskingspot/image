// The TIFF encoder's oracle: libtiff, the bar, writes the same image with
// the same settings (TIFFWriteEncodedStrip), and the file it writes, with
// its IFD, values, and strips moved to where this package's encoder puts
// them, must be this package's file byte for byte (test/oracle/
// tiff_encode.zig says why the layout differs and which settings apply).
//
// tiff-libtiff-encode answers for the formats the encoder stores without
// converting them; it skips the others. The settings follow from the size,
// as in tiff_encode.zig: (width * 31 + height * 17) % 4 picks none,
// PackBits, LZW, or LZW with Predictor 2. An 8-bit RGB image of at most 256
// colors is a palette of 1, 2, 4, or 8 bits, its colors in order of first
// appearance, when the indices and the color map are smaller than the RGB
// pixels. Strips hold max(1, 8192 / row bytes) rows.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tiffio.h>

#include "oracle.h"

struct buf {
  uint8_t *p;
  toff_t len, cap, at;
};

static tmsize_t buf_read(thandle_t h, void *dst, tmsize_t n) {
  struct buf *b = (struct buf *)h;
  if (b->at >= b->len) return 0;
  toff_t left = b->len - b->at;
  if ((toff_t)n > left) n = (tmsize_t)left;
  memcpy(dst, b->p + b->at, (size_t)n);
  b->at += (toff_t)n;
  return n;
}

static tmsize_t buf_write(thandle_t h, void *src, tmsize_t n) {
  struct buf *b = (struct buf *)h;
  toff_t end = b->at + (toff_t)n;
  if (end > b->cap) {
    toff_t cap = b->cap ? b->cap : 1 << 16;
    while (cap < end) cap *= 2;
    uint8_t *p = realloc(b->p, (size_t)cap);
    if (!p) return -1;
    memset(p + b->cap, 0, (size_t)(cap - b->cap));
    b->p = p;
    b->cap = cap;
  }
  memcpy(b->p + b->at, src, (size_t)n);
  b->at = end;
  if (end > b->len) b->len = end;
  return n;
}

static toff_t buf_seek(thandle_t h, toff_t off, int whence) {
  struct buf *b = (struct buf *)h;
  toff_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? b->at : b->len;
  b->at = base + off;
  return b->at;
}

static int buf_close(thandle_t h) {
  (void)h;
  return 0;
}

static toff_t buf_size(thandle_t h) { return ((struct buf *)h)->len; }

static int buf_map(thandle_t h, void **base, toff_t *size) {
  (void)h;
  (void)base;
  (void)size;
  return 0;
}

static void buf_unmap(thandle_t h, void *base, toff_t size) {
  (void)h;
  (void)base;
  (void)size;
}

static void quiet(const char *module, const char *fmt, va_list ap) {
  (void)module;
  (void)fmt;
  (void)ap;
}

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void wr16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)v;
  p[1] = (uint8_t)(v >> 8);
}
static void wr32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static uint32_t type_size(uint16_t type) {
  switch (type) {
    case 1: case 2: case 6: case 7: return 1;
    case 3: case 8: return 2;
    case 4: case 9: case 11: return 4;
    case 5: case 10: case 12: return 8;
  }
  return 0;
}

// `in`, a classic little-endian TIFF of one IFD, laid out as this package's
// encoder lays out a page: the header, the IFD at 8, the values outside it
// in entry order but the strip offsets and byte counts last, and the strips.
static int relayout(const uint8_t *in, size_t len, struct image *out) {
  if (len < 8) return 0;
  uint32_t ifd = rd32(in + 4);
  if ((size_t)ifd + 2 > len) return 0;
  uint16_t n = rd16(in + ifd);
  if ((size_t)ifd + 2 + 12u * n + 4 > len) return 0;
  const uint8_t *e = in + ifd + 2;
  // Where each entry's value is in `in`, and its length.
  const uint8_t *val[64];
  uint32_t vlen[64];
  int offs = -1, counts = -1;
  if (n > 64) return 0;
  for (int i = 0; i < n; i++) {
    const uint8_t *x = e + 12 * i;
    uint32_t size = type_size(rd16(x + 2)) * rd32(x + 4);
    vlen[i] = size;
    if (size <= 4) {
      val[i] = x + 8;
    } else {
      uint32_t at = rd32(x + 8);
      if ((size_t)at + size > len) return 0;
      val[i] = in + at;
    }
    if (rd16(x) == 273) offs = i;
    if (rd16(x) == 279) counts = i;
  }
  if (offs < 0 || counts < 0) return 0;
  uint32_t strips = rd32(e + 12 * offs + 4);
  if (strips != rd32(e + 12 * counts + 4)) return 0;
  uint16_t otype = rd16(e + 12 * offs + 2), ctype = rd16(e + 12 * counts + 2);
  if ((otype != 3 && otype != 4) || (ctype != 3 && ctype != 4)) return 0;
#define GET(i, k, type) ((type) == 3 ? rd16(val[i] + 2 * (k)) : rd32(val[i] + 4 * (k)))
  uint64_t total = 0;
  for (uint32_t k = 0; k < strips; k++) {
    uint32_t at = GET(offs, k, otype), c = GET(counts, k, ctype);
    if ((uint64_t)at + c > len) return 0;
    total += c;
  }
  uint64_t values = 0;
  for (int i = 0; i < n; i++) values += vlen[i] > 4 ? vlen[i] : 0;
  uint32_t data_at = 8 + 2 + 12u * n + 4 + (uint32_t)values;
  out->len = data_at + total;
  out->pixels = malloc(out->len);
  if (!out->pixels) return 0;
  uint8_t *o = out->pixels;
  memcpy(o, "II*\0", 4);
  wr32(o + 4, 8);
  wr16(o + 8, n);
  uint8_t *oe = o + 10;
  wr32(oe + 12 * n, 0);
  uint32_t at = 8 + 2 + 12u * n + 4;
  for (int pass = 0; pass < 2; pass++) {
    for (int i = 0; i < n; i++) {
      int arrays = i == offs || i == counts;
      if (vlen[i] <= 4 || arrays != pass) continue;
      memcpy(o + at, val[i], vlen[i]);
      wr32(oe + 12 * i + 8, at);
      at += vlen[i];
    }
  }
  for (int i = 0; i < n; i++) {
    memcpy(oe + 12 * i, e + 12 * i, 8);
    if (vlen[i] <= 4) memcpy(oe + 12 * i + 8, e + 12 * i + 8, 4);
  }
  // The strips, and their new offsets.
  uint8_t *ov = vlen[offs] > 4 ? o + rd32(oe + 12 * offs + 8) : oe + 12 * offs + 8;
  uint32_t d = data_at;
  for (uint32_t k = 0; k < strips; k++) {
    uint32_t from = GET(offs, k, otype), c = GET(counts, k, ctype);
    memcpy(o + d, in + from, c);
    if (otype == 3) {
      wr16(ov + 2 * k, (uint16_t)d);
    } else {
      wr32(ov + 4 * k, d);
    }
    d += c;
  }
#undef GET
  return 1;
}

struct stored {
  uint16_t spp, bits, photometric, extra;
  int invert;
};

static int stored_for(enum pixel_format f, struct stored *s) {
  struct stored t = {1, 8, 1, 0, 0};
  switch (f) {
    case PF_GRAY8: break;
    case PF_GRAY_ALPHA8: t.spp = 2; t.extra = 2; break;
    case PF_GRAY_ALPHA8_PREMUL: t.spp = 2; t.extra = 1; break;
    case PF_RGB8: t.spp = 3; t.photometric = 2; break;
    case PF_RGBA8: t.spp = 4; t.photometric = 2; t.extra = 2; break;
    case PF_RGBA8_PREMUL: t.spp = 4; t.photometric = 2; t.extra = 1; break;
    case PF_GRAY16: t.bits = 16; break;
    case PF_GRAY_ALPHA16: t.bits = 16; t.spp = 2; t.extra = 2; break;
    case PF_GRAY_ALPHA16_PREMUL: t.bits = 16; t.spp = 2; t.extra = 1; break;
    case PF_RGB16: t.bits = 16; t.spp = 3; t.photometric = 2; break;
    case PF_RGBA16: t.bits = 16; t.spp = 4; t.photometric = 2; t.extra = 2; break;
    case PF_RGBA16_PREMUL: t.bits = 16; t.spp = 4; t.photometric = 2; t.extra = 1; break;
    case PF_CMYK8: t.spp = 4; t.photometric = 5; t.invert = 1; break;
    case PF_CMYK16: t.bits = 16; t.spp = 4; t.photometric = 5; t.invert = 1; break;
    default: return 0;
  }
  *s = t;
  return 1;
}

// The palette of an 8-bit RGB image, in order of first appearance, and the
// index width it needs, or 0 for more than 256 colors.
static int palette(const uint8_t *px, size_t n, uint8_t colors[256][3], int *count) {
  int len = 0;
  for (size_t i = 0; i < n; i++) {
    const uint8_t *c = px + 3 * i;
    if (i > 0 && memcmp(c, c - 3, 3) == 0) continue;
    int found = 0;
    for (int k = len - 1; k >= 0 && !found; k--) found = memcmp(colors[k], c, 3) == 0;
    if (found) continue;
    if (len == 256) return 0;
    memcpy(colors[len++], c, 3);
  }
  *count = len;
  return len <= 2 ? 1 : len <= 4 ? 2 : len <= 16 ? 4 : 8;
}

static enum status encode(const uint8_t *pixels, enum pixel_format format, uint32_t w, uint32_t h,
                          struct image *out) {
  struct stored s;
  if (!stored_for(format, &s)) return STATUS_SKIPPED;
  int setting = (int)((w * 31u + h * 17u) % 4);
  uint16_t compression = setting == 0 ? COMPRESSION_NONE : setting == 1 ? COMPRESSION_PACKBITS : COMPRESSION_LZW;
  int predictor = setting == 3;
  size_t bpp = (size_t)s.spp * s.bits / 8;
  size_t pixel_count = (size_t)w * h;

  static _Thread_local uint8_t colors[256][3];
  int count = 0, pal_bits = 0;
  if (format == PF_RGB8) {
    pal_bits = palette(pixels, pixel_count, colors, &count);
    if (pal_bits) {
      uint64_t indices = ((uint64_t)w * pal_bits + 7) / 8 * h;
      if (!(indices + ((uint64_t)6 << pal_bits) < (uint64_t)3 * pixel_count)) pal_bits = 0;
    }
  }
  size_t row_len = pal_bits ? ((size_t)w * pal_bits + 7) / 8 : w * bpp;
  uint32_t rows = row_len >= 8192 ? 1 : (uint32_t)(8192 / row_len);
  if (rows > h) rows = h;

  TIFFSetErrorHandler(quiet);
  TIFFSetWarningHandler(quiet);
  struct buf b = {0};
  TIFF *t = TIFFClientOpen("mem", "wl", &b, buf_read, buf_write, buf_seek, buf_close, buf_size, buf_map,
                           buf_unmap);
  if (!t) return STATUS_REJECTED;
  TIFFSetField(t, TIFFTAG_IMAGEWIDTH, w);
  TIFFSetField(t, TIFFTAG_IMAGELENGTH, h);
  TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, pal_bits ? pal_bits : s.bits);
  TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, pal_bits ? 1 : s.spp);
  TIFFSetField(t, TIFFTAG_COMPRESSION, compression);
  TIFFSetField(t, TIFFTAG_PHOTOMETRIC, pal_bits ? PHOTOMETRIC_PALETTE : s.photometric);
  TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, rows);
  TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
  if (predictor && !pal_bits) TIFFSetField(t, TIFFTAG_PREDICTOR, PREDICTOR_HORIZONTAL);
  static _Thread_local uint16_t map[3][256];
  if (pal_bits) {
    memset(map, 0, sizeof map);
    for (int k = 0; k < count; k++) {
      for (int c = 0; c < 3; c++) map[c][k] = (uint16_t)(colors[k][c] * 257);
    }
    TIFFSetField(t, TIFFTAG_COLORMAP, map[0], map[1], map[2]);
  }
  if (s.extra && !pal_bits) {
    uint16_t extra = s.extra;
    TIFFSetField(t, TIFFTAG_EXTRASAMPLES, 1, &extra);
  }
  uint8_t *strip = malloc(row_len * rows);
  int ok = strip != NULL;
  for (uint32_t y0 = 0; ok && y0 < h; y0 += rows) {
    uint32_t n = h - y0 < rows ? h - y0 : rows;
    for (uint32_t r = 0; r < n; r++) {
      const uint8_t *src = pixels + (size_t)(y0 + r) * w * bpp;
      uint8_t *dst = strip + (size_t)r * row_len;
      if (pal_bits) {
        memset(dst, 0, row_len);
        int k = 0;
        for (uint32_t x = 0; x < w; x++) {
          if (memcmp(colors[k], src + 3 * x, 3) != 0) {
            k = 0;
            while (memcmp(colors[k], src + 3 * x, 3) != 0) k++;
          }
          size_t bit = (size_t)x * pal_bits;
          dst[bit / 8] |= (uint8_t)(k << (8 - pal_bits - bit % 8));
        }
      } else if (s.invert) {
        for (size_t i = 0; i < row_len; i++) dst[i] = (uint8_t)~src[i];
      } else {
        memcpy(dst, src, row_len);
      }
    }
    ok = TIFFWriteEncodedStrip(t, y0 / rows, strip, (tmsize_t)(n * row_len)) >= 0;
  }
  free(strip);
  TIFFClose(t);
  int laid = ok && relayout(b.p, (size_t)b.len, out);
  free(b.p);
  return laid ? STATUS_OK : STATUS_REJECTED;
}

const struct op tiff_encode_ops[] = {
    {"tiff-libtiff-encode", .encode = encode},
    {0},
};

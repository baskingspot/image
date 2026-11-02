// TIFF's oracles, both libtiff, the bar, on the first directory:
//
// - tiff-rgba: libtiff's RGBA interface (TIFFRGBAImageGet), its own
//   conversion of every photometric it reads to 8-bit RGBA. It
//   premultiplies unassociated alpha, so it answers in RGBA8 premultiplied.
//   The rows are in stored order: the requested orientation is the file's.
//   It skips what its interface declines (TIFFRGBAImageOK) and, when it
//   fails, the files libtiff's decompression reads (tiff-raw accepts): the
//   interface's own limits, such as its stricter byte counts for tiles, are
//   not a verdict on the file.
// - tiff-raw: libtiff's decompression (TIFFReadEncodedStrip and
//   TIFFReadEncodedTile, with the predictor and byte order applied), and
//   this file's own expansion of the samples to the decoder's native
//   format, by the rules in src/tiff/samples.zig. It answers only in that
//   format. YCbCr it compares only with the default coefficients and
//   reference black and white. CMYK, whose native cmyk8 and cmyk16 this
//   protocol cannot carry, it answers as the RGB image.convert makes of
//   them at their depth.
//
// Any error libtiff reports rejects the input; warnings do not, but for the
// CCITT decoders' warnings about corrupt data, which libtiff conceals. A
// CCITT line longer than the width skips the input instead: libtiff
// makes one when a pass mode's b2 lies past the reference line's last
// change, reading a stale run from an earlier row for it, and when that run
// happens to be empty it ends the line at the width with no warning, as
// this decoder does.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tiffio.h>
#include <zlib.h>

#include "oracle.h"

struct mem {
  const uint8_t *p;
  toff_t len, at;
};

static tmsize_t mem_read(thandle_t h, void *buf, tmsize_t n) {
  struct mem *m = (struct mem *)h;
  if (m->at >= m->len) return 0;
  toff_t left = m->len - m->at;
  if ((toff_t)n > left) n = (tmsize_t)left;
  memcpy(buf, m->p + m->at, (size_t)n);
  m->at += (toff_t)n;
  return n;
}

static tmsize_t mem_write(thandle_t h, void *buf, tmsize_t n) {
  (void)h;
  (void)buf;
  (void)n;
  return -1;
}

static toff_t mem_seek(thandle_t h, toff_t off, int whence) {
  struct mem *m = (struct mem *)h;
  toff_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? m->at : m->len;
  m->at = base + off;
  return m->at;
}

static int mem_close(thandle_t h) {
  (void)h;
  return 0;
}

static toff_t mem_size(thandle_t h) { return ((struct mem *)h)->len; }

// The input is mapped, as a caller holding the file in memory maps it:
// libtiff's unmapped reads of uncompressed strips and tiles ignore the
// byte counts and read on into the bytes after them.
static int mem_map(thandle_t h, void **base, toff_t *size) {
  struct mem *m = (struct mem *)h;
  *base = (void *)m->p;
  *size = m->len;
  return 1;
}

static void mem_unmap(thandle_t h, void *base, toff_t size) {
  (void)h;
  (void)base;
  (void)size;
}

static int failed;
// Whether libtiff replaced the strip or tile byte counts with its own
// estimate from the image's size, as it does when they are missing or
// look wrong to it; its answer is then about another file.
static int estimated;
// Whether libtiff warned of a CCITT line longer than the width.
static int long_line;

static int on_error(TIFF *tif, void *user, const char *module, const char *fmt, va_list ap) {
  (void)tif;
  (void)user;
  (void)module;
  (void)ap;
  // libtiff reports a NumberOfInks that disagrees with InkNames or
  // SamplesPerPixel as an error and reads on; this decoder reads neither.
  if (strstr(fmt, "NumberOfInks")) return 1;
  failed = 1;
  return 1;
}

static int on_warning(TIFF *tif, void *user, const char *module, const char *fmt, va_list ap) {
  (void)tif;
  (void)user;
  // libtiff's CCITT decoders warn about a bad code or a row of the wrong
  // length, and conceal it; the data is corrupt, so it rejects. (Group 3
  // data without a first EOL is not.)
  if (module && strncmp(module, "Fax", 3) == 0 && strncmp(fmt, "Try to decode", 13) != 0) {
    failed = 1;
    char msg[256];
    vsnprintf(msg, sizeof msg, fmt, ap);
    if (strncmp(msg, "Line length mismatch", 20) == 0) long_line = 1;
  }
  if (strstr(fmt, "calculating from imagelength")) estimated = 1;
  return 1;
}

static TIFF *open_mem(struct mem *m) {
  failed = 0;
  estimated = 0;
  long_line = 0;
  TIFFOpenOptions *o = TIFFOpenOptionsAlloc();
  TIFFOpenOptionsSetErrorHandlerExtR(o, on_error, NULL);
  TIFFOpenOptionsSetWarningHandlerExtR(o, on_warning, NULL);
  TIFFOpenOptionsSetMaxSingleMemAlloc(o, (tmsize_t)1 << 28);
  TIFFOpenOptionsSetMaxCumulatedMemAlloc(o, (tmsize_t)1 << 30);
  TIFF *tif = TIFFClientOpenExt("mem", "r", (thandle_t)m, mem_read, mem_write, mem_seek, mem_close,
                                mem_size, mem_map, mem_unmap, o);
  TIFFOpenOptionsFree(o);
  if (tif && (failed || estimated)) {
    TIFFClose(tif);
    return NULL;
  }
  return tif;
}

static enum status tiff_raw(const uint8_t *in, size_t len, enum pixel_format format,
                            uint64_t max_pixels, struct image *out);

// Whether a Deflate strip or tile of the open page holds more than its
// rows, or is corrupt only near their end, by zlib's reading. libtiff (with
// libdeflate) then stops where its output is full, and may leave the last
// bytes of a match that crosses the end unwritten, so its rows are not the
// stream's, and it accepts a stream this decoder finds corrupt. The same
// goes for the places below where libdeflate reads otherwise than zlib.
static int deflate_overruns(TIFF *tif) {
  uint16_t c = COMPRESSION_NONE;
  TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &c);
  if (c != COMPRESSION_ADOBE_DEFLATE && c != COMPRESSION_DEFLATE) return 0;
  int tiled = TIFFIsTiled(tif);
  uint32_t n = tiled ? TIFFNumberOfTiles(tif) : TIFFNumberOfStrips(tif);
  uint32_t h = 0, rps = 0;
  TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
  TIFFGetFieldDefaulted(tif, TIFFTAG_ROWSPERSTRIP, &rps);
  int found = 0, was_failed = failed;
  for (uint32_t i = 0; i < n && !found; i++) {
    tmsize_t need;
    if (tiled) {
      need = TIFFTileSize(tif);
    } else {
      uint32_t strips_per_plane = rps ? (h + rps - 1) / rps : 1;
      uint32_t k = strips_per_plane ? i % strips_per_plane : 0;
      uint32_t rows = rps && h - k * rps < rps ? h - k * rps : rps;
      need = TIFFVStripSize(tif, rows);
    }
    uint64_t raw_len = TIFFGetStrileByteCount(tif, i);
    if (need <= 0 || raw_len == 0 || raw_len > (1u << 28)) continue;
    uint8_t *raw = malloc((size_t)raw_len);
    uint8_t *dst = malloc((size_t)need + 1);
    tmsize_t got = tiled ? TIFFReadRawTile(tif, i, raw, (tmsize_t)raw_len) : TIFFReadRawStrip(tif, i, raw, (tmsize_t)raw_len);
    if (got > 0) {
      z_stream z = {0};
      if (inflateInit(&z) == Z_OK) {
        z.next_in = raw;
        z.avail_in = (uInt)got;
        z.next_out = dst;
        z.avail_out = (uInt)need + 1;
        int r;
        do r = inflate(&z, Z_NO_FLUSH);
        while (r == Z_OK && z.avail_out > 0 && z.avail_in > 0);
        uint64_t made = (uint64_t)need + 1 - z.avail_out;
        // More output than the rows, or an error other than the checksum
        // (which libtiff checks as this decoder does) within a match's
        // length of their end, where libdeflate may find the output full
        // before the error.
        if (made > (uint64_t)need || (made + 258 >= (uint64_t)need && r == Z_DATA_ERROR && z.msg &&
                                      strcmp(z.msg, "incorrect data check") != 0))
          found = 1;
        // An unused codeword of an incomplete Huffman code, which zlib
        // rejects and libdeflate decodes as the code's one symbol, and a
        // code without an end of block, which libdeflate reads on with.
        if (r == Z_DATA_ERROR && z.msg &&
            (strcmp(z.msg, "invalid literal/length code") == 0 || strcmp(z.msg, "invalid distance code") == 0 ||
             strcmp(z.msg, "invalid code -- missing end-of-block") == 0))
          found = 1;
        // A stream cut off near the rows' end, which libdeflate reads on
        // into as zero bits, up to eight bytes of them.
        if (r != Z_STREAM_END && r != Z_DATA_ERROR && z.avail_in == 0 && made + 8 * 258 >= (uint64_t)need)
          found = 1;
        inflateEnd(&z);
      }
    }
    free(raw);
    free(dst);
  }
  failed = was_failed;
  return found;
}

// Whether tiff-raw accepts the input in its native format.
static int raw_reads(const uint8_t *in, size_t len, uint64_t max_pixels) {
  for (int f = PF_GRAY8; f <= PF_RGBA_F32_PREMUL; f++) {
    struct image tmp = {0};
    enum status s = tiff_raw(in, len, (enum pixel_format)f, max_pixels, &tmp);
    free(tmp.pixels);
    if (s != STATUS_SKIPPED) return s == STATUS_OK;
  }
  return 0;
}

static enum status tiff_rgba(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8_PREMUL) return STATUS_SKIPPED;
  struct mem m = {in, len, 0};
  TIFF *tif = open_mem(&m);
  if (!tif) return estimated ? STATUS_SKIPPED : STATUS_REJECTED;
  if (deflate_overruns(tif)) {
    TIFFClose(tif);
    return STATUS_SKIPPED;
  }
  enum status result = STATUS_REJECTED;
  uint32_t *raster = NULL;
  char emsg[1024];
  TIFFRGBAImage img;
  uint32_t w = 0, h = 0;
  TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &w);
  TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  if (!TIFFRGBAImageOK(tif, emsg)) {
    result = STATUS_SKIPPED;
    goto done;
  }
  if (!TIFFRGBAImageBegin(&img, tif, 1, emsg)) goto fail;
  img.req_orientation = img.orientation;
  raster = malloc((size_t)w * h * 4 + 4);
  int ok = TIFFRGBAImageGet(&img, raster, w, h);
  TIFFRGBAImageEnd(&img);
  if (!ok || failed) goto fail;
  out->width = w;
  out->height = h;
  out->len = (size_t)w * h * 4;
  out->pixels = malloc(out->len + 1);
  for (size_t i = 0; i < (size_t)w * h; i++) {
    uint32_t p = raster[i];
    out->pixels[4 * i] = TIFFGetR(p);
    out->pixels[4 * i + 1] = TIFFGetG(p);
    out->pixels[4 * i + 2] = TIFFGetB(p);
    out->pixels[4 * i + 3] = TIFFGetA(p);
  }
  result = STATUS_OK;
  goto done;
fail:
  if (long_line || raw_reads(in, len, max_pixels)) result = STATUS_SKIPPED;
done:
  free(raster);
  TIFFClose(tif);
  return result;
}

// The page as the decoder sees it.
struct page {
  uint32_t w, h;
  uint16_t bits, spp, fmt, photometric, planar, extra_type, nextra;
  int alpha;  // 0 none, 1 premultiplied, 2 straight
  uint16_t *cmap[3];
};

static int color_channels(uint16_t photometric) {
  switch (photometric) {
    case PHOTOMETRIC_MINISWHITE: case PHOTOMETRIC_MINISBLACK: case PHOTOMETRIC_PALETTE: return 1;
    case PHOTOMETRIC_RGB: return 3;
    case PHOTOMETRIC_SEPARATED: return 4;
  }
  return 0;
}

static enum pixel_format native(const struct page *p, int palette8) {
  int a = p->alpha;
  if (p->fmt == SAMPLEFORMAT_IEEEFP) return a == 1 ? PF_RGBA_F32_PREMUL : PF_RGBA_F32;
  int wide = p->bits > 8;
  switch (p->photometric) {
    case PHOTOMETRIC_PALETTE: return palette8 ? PF_RGB8 : PF_RGB16;
    case PHOTOMETRIC_MINISWHITE: case PHOTOMETRIC_MINISBLACK:
      if (!a) return wide ? PF_GRAY16 : PF_GRAY8;
      if (wide) return a == 1 ? PF_GRAY_ALPHA16_PREMUL : PF_GRAY_ALPHA16;
      return a == 1 ? PF_GRAY_ALPHA8_PREMUL : PF_GRAY_ALPHA8;
    default:
      if (!a) return wide ? PF_RGB16 : PF_RGB8;
      if (wide) return a == 1 ? PF_RGBA16_PREMUL : PF_RGBA16;
      return a == 1 ? PF_RGBA8_PREMUL : PF_RGBA8;
  }
}

// Sample `i` of `bits` bits from a row, as libtiff leaves it: whole bytes
// in the machine's order, other widths packed most significant bit first.
static uint64_t sample_at(const uint8_t *row, uint64_t i, int bits) {
  switch (bits) {
    case 8: return row[i];
    case 16: { uint16_t v; memcpy(&v, row + 2 * i, 2); return v; }
    case 32: { uint32_t v; memcpy(&v, row + 4 * i, 4); return v; }
    case 64: { uint64_t v; memcpy(&v, row + 8 * i, 8); return v; }
    case 24: {
      const uint8_t *b = row + 3 * i;
      uint32_t v = 0;
      memcpy(&v, b, 3);  // little endian machines only
      return v;
    }
  }
  uint64_t pos = i * (uint64_t)bits, v = 0;
  for (int k = 0; k < bits; k++, pos++) v = v << 1 | (row[pos / 8] >> (7 - pos % 8) & 1);
  return v;
}

static float half_to_float(uint16_t h) {
  int s = h >> 15, e = h >> 10 & 31, f = h & 1023;
  float v = e == 0 ? ldexpf((float)f, -24) : e == 31 ? (f ? NAN : INFINITY) : ldexpf((float)(f | 1024), e - 25);
  return s ? -v : v;
}

static float f24_to_float(uint32_t x) {
  int s = x >> 23 & 1, e = x >> 16 & 127, f = x & 0xffff;
  float v = e == 0 ? ldexpf((float)f, -78) : e == 127 ? (f ? NAN : INFINITY) : ldexpf((float)(f | 0x10000), e - 63 - 16);
  return s ? -v : v;
}

static float sample_float(uint64_t v, int bits) {
  switch (bits) {
    case 16: return half_to_float((uint16_t)v);
    case 24: return f24_to_float((uint32_t)v);
    case 32: { uint32_t u = (uint32_t)v; float f; memcpy(&f, &u, 4); return f; }
    default: { double d; memcpy(&d, &v, 8); return (float)d; }
  }
}

static uint8_t ycc_clamp(float v) {
  if (!(v > 0)) return 0;
  if (v >= 255) return 255;
  return (uint8_t)roundf(v);
}

// YCbCr by the decoder's rules (src/tiff/samples.zig, Ycc): the
// specification's equations in single precision with the default
// coefficients and reference black and white, rounded and clamped. A file
// that sets either field is skipped. libtiff's decompression gives the data
// units; this spreads each unit's Cb and Cr over its pixels.
static enum status raw_ycbcr(TIFF *tif, const struct page *p, enum pixel_format format, struct image *out) {
  uint16_t h = 2, v = 2, pred = 1;
  float *unused;
  if (TIFFGetField(tif, TIFFTAG_YCBCRCOEFFICIENTS, &unused) || TIFFGetField(tif, TIFFTAG_REFERENCEBLACKWHITE, &unused))
    return STATUS_SKIPPED;
  if (format != PF_RGB8) return STATUS_SKIPPED;
  TIFFGetFieldDefaulted(tif, TIFFTAG_YCBCRSUBSAMPLING, &h, &v);
  // The predictor is the LZW and Deflate codecs' field.
  uint16_t compression = COMPRESSION_NONE;
  TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &compression);
  if (compression == COMPRESSION_LZW || compression == COMPRESSION_ADOBE_DEFLATE || compression == COMPRESSION_DEFLATE)
    TIFFGetFieldDefaulted(tif, TIFFTAG_PREDICTOR, &pred);
  // What the decoder refuses.
  if (p->bits != 8 || p->fmt != SAMPLEFORMAT_UINT || p->spp != 3) return STATUS_REJECTED;
  if (!(h == 1 || h == 2 || h == 4) || !(v == 1 || v == 2 || v == 4) || v > h) return STATUS_REJECTED;
  int sub = h != 1 || v != 1;
  int planar = p->planar == PLANARCONFIG_SEPARATE;
  if (sub && (planar || pred != 1)) return STATUS_REJECTED;
  int tiled = TIFFIsTiled(tif);
  uint32_t cw = p->w, ch = 0;
  if (tiled) {
    TIFFGetField(tif, TIFFTAG_TILEWIDTH, &cw);
    TIFFGetField(tif, TIFFTAG_TILELENGTH, &ch);
  } else {
    TIFFGetFieldDefaulted(tif, TIFFTAG_ROWSPERSTRIP, &ch);
    if (ch > p->h) ch = p->h;
  }
  if (ch % v != 0 && (tiled || ch != p->h)) return STATUS_REJECTED;
  size_t n = (size_t)p->w * p->h;
  uint8_t *ycc = calloc(3 * n + 1, 1);
  tmsize_t size = tiled ? TIFFTileSize(tif) : TIFFStripSize(tif);
  uint8_t *chunk = size > 0 ? malloc((size_t)size) : NULL;
  enum status result = STATUS_REJECTED;
  if (!chunk) goto done;
  uint32_t bw = (cw + h - 1) / h, unit = (uint32_t)h * v + 2;
  int nplanes = planar ? 3 : 1;
  for (int pl = 0; pl < nplanes; pl++) {
    for (uint32_t y0 = 0; y0 < p->h; y0 += ch) {
      for (uint32_t x0 = 0; x0 < p->w; x0 += cw) {
        uint32_t rows = p->h - y0 < ch ? p->h - y0 : ch;
        if (tiled) {
          ttile_t t = TIFFComputeTile(tif, x0, y0, 0, (tsample_t)pl);
          if (TIFFReadEncodedTile(tif, t, chunk, size) < size || failed) goto done;
        } else {
          tstrip_t s = TIFFComputeStrip(tif, y0, (tsample_t)pl);
          tmsize_t want = planar ? (tmsize_t)rows * cw : (tmsize_t)((rows + v - 1) / v) * bw * unit;
          if (TIFFReadEncodedStrip(tif, s, chunk, want) < want || failed) goto done;
        }
        for (uint32_t r = 0; r < rows; r++) {
          for (uint32_t c = 0; c < cw && x0 + c < p->w; c++) {
            uint8_t *px = ycc + 3 * ((size_t)(y0 + r) * p->w + x0 + c);
            if (planar) {
              px[pl] = chunk[(size_t)r * cw + c];
            } else {
              const uint8_t *u = chunk + ((size_t)(r / v) * bw + c / h) * unit;
              px[0] = u[(r % v) * h + c % h];
              px[1] = u[h * v];
              px[2] = u[h * v + 1];
            }
          }
        }
      }
    }
  }
  const float lr = 0.299f, lg = 0.587f, lb = 0.114f;
  out->len = 3 * n;
  out->pixels = malloc(out->len + 1);
  for (size_t i = 0; i < n; i++) {
    float yv = ((float)ycc[3 * i] - 0.0f) * 255 / (255.0f - 0.0f);
    float cb = ((float)ycc[3 * i + 1] - 128.0f) * 127 / (255.0f - 128.0f);
    float cr = ((float)ycc[3 * i + 2] - 128.0f) * 127 / (255.0f - 128.0f);
    float r = cr * (2 - 2 * lr) + yv;
    float b = cb * (2 - 2 * lb) + yv;
    float g = (yv - lb * b - lr * r) / lg;
    out->pixels[3 * i] = ycc_clamp(r);
    out->pixels[3 * i + 1] = ycc_clamp(g);
    out->pixels[3 * i + 2] = ycc_clamp(b);
  }
  out->width = p->w;
  out->height = p->h;
  result = STATUS_OK;
done:
  free(chunk);
  free(ycc);
  return result;
}

static enum status tiff_raw(const uint8_t *in, size_t len, enum pixel_format format,
                            uint64_t max_pixels, struct image *out) {
  struct mem m = {in, len, 0};
  TIFF *tif = open_mem(&m);
  if (!tif) return estimated ? STATUS_SKIPPED : STATUS_REJECTED;
  if (deflate_overruns(tif)) {
    TIFFClose(tif);
    return STATUS_SKIPPED;
  }
  enum status result = STATUS_REJECTED;
  uint8_t **planes = NULL;
  uint8_t *chunk = NULL;
  struct page p = {0};
  uint16_t *extra = NULL;
  int nplanes = 0;
  if (!TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &p.w) || !TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &p.h)) goto done;
  TIFFGetFieldDefaulted(tif, TIFFTAG_BITSPERSAMPLE, &p.bits);
  TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLESPERPIXEL, &p.spp);
  TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLEFORMAT, &p.fmt);
  TIFFGetFieldDefaulted(tif, TIFFTAG_PLANARCONFIG, &p.planar);
  if (!TIFFGetField(tif, TIFFTAG_PHOTOMETRIC, &p.photometric)) {
    // Missing or ignored: the decoder's guess.
    uint16_t c = COMPRESSION_NONE;
    TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &c);
    int fax = c == COMPRESSION_CCITTRLE || c == COMPRESSION_CCITTFAX3 || c == COMPRESSION_CCITTFAX4;
    p.photometric = fax ? PHOTOMETRIC_MINISWHITE : p.spp >= 3 ? PHOTOMETRIC_RGB : PHOTOMETRIC_MINISBLACK;
  }
  if (TIFFGetField(tif, TIFFTAG_EXTRASAMPLES, &p.nextra, &extra) && p.nextra > 0) p.extra_type = extra[0];
  if ((uint64_t)p.w * p.h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  if (p.fmt == 4) p.fmt = 1;
  if (p.photometric == PHOTOMETRIC_YCBCR) {
    result = raw_ycbcr(tif, &p, format, out);
    goto done;
  }
  int cc = color_channels(p.photometric);
  if (!cc || p.spp < cc || p.fmt > 3) {
    result = STATUS_SKIPPED;
    goto done;
  }
  // The decoder leaves out inks other than CMYK, white-is-zero floats, and
  // palette pages with extra samples or samples other than unsigned.
  uint16_t ink = INKSET_CMYK;
  if (cc == 4) TIFFGetFieldDefaulted(tif, TIFFTAG_INKSET, &ink);
  if (ink != INKSET_CMYK || (p.fmt == SAMPLEFORMAT_IEEEFP && p.photometric == PHOTOMETRIC_MINISWHITE) ||
      (p.photometric == PHOTOMETRIC_PALETTE && (p.spp != 1 || p.fmt != SAMPLEFORMAT_UINT))) {
    result = STATUS_SKIPPED;
    goto done;
  }
  // The decoder's float widths; libtiff leaves the rest to the caller.
  if (p.fmt == SAMPLEFORMAT_IEEEFP && p.bits != 16 && p.bits != 24 && p.bits != 32 && p.bits != 64) goto done;
  // Integer samples wider than 32 bits the decoder leaves out.
  if (p.fmt != SAMPLEFORMAT_IEEEFP && p.bits > 32) {
    result = STATUS_SKIPPED;
    goto done;
  }
  // CMYK has no alpha: its native cmyk8 and cmyk16 drop it.
  if (p.spp > cc && cc != 4) p.alpha = p.extra_type == 1 ? 1 : p.extra_type == 2 ? 2 : 0;
  int palette8 = 1;
  if (p.photometric == PHOTOMETRIC_PALETTE) {
    if (!TIFFGetField(tif, TIFFTAG_COLORMAP, &p.cmap[0], &p.cmap[1], &p.cmap[2]) || p.bits > 8) goto done;
    for (int c = 0; c < 3; c++)
      for (int i = 0; i < 1 << p.bits; i++) palette8 &= (p.cmap[c][i] >> 8) == (p.cmap[c][i] & 255);
  }
  // CMYK's native cmyk8 and cmyk16 are not formats this protocol has; it
  // is compared as the RGB at the same depth that image.convert makes of
  // them.
  enum pixel_format want = native(&p, palette8);
  if (cc == 4) want = p.bits > 8 || p.fmt == SAMPLEFORMAT_IEEEFP ? PF_RGB16 : PF_RGB8;
  if (format != want) {
    result = STATUS_SKIPPED;
    goto done;
  }
  int planar = p.planar == PLANARCONFIG_SEPARATE && p.spp > 1;
  nplanes = planar ? p.spp : 1;
  int per_px = planar ? 1 : p.spp;
  uint64_t row_bytes = ((uint64_t)p.w * per_px * p.bits + 7) / 8;
  planes = calloc(nplanes, sizeof *planes);
  for (int i = 0; i < nplanes; i++) planes[i] = malloc(row_bytes * p.h + 8);
  if (TIFFIsTiled(tif)) {
    uint32_t tw, th;
    TIFFGetField(tif, TIFFTAG_TILEWIDTH, &tw);
    TIFFGetField(tif, TIFFTAG_TILELENGTH, &th);
    tmsize_t ts = TIFFTileSize(tif);
    if (ts <= 0) goto done;
    chunk = malloc((size_t)ts);
    uint64_t tile_row = ((uint64_t)tw * per_px * p.bits + 7) / 8;
    for (int pl = 0; pl < nplanes; pl++) {
      for (uint32_t y = 0; y < p.h; y += th) {
        for (uint32_t x = 0; x < p.w; x += tw) {
          ttile_t t = TIFFComputeTile(tif, x, y, 0, (tsample_t)pl);
          if (TIFFReadEncodedTile(tif, t, chunk, ts) < 0 || failed) goto done;
          uint32_t rows = p.h - y < th ? p.h - y : th;
          for (uint32_t r = 0; r < rows; r++) {
            // Bit-copy the visible part of the tile row.
            uint64_t bits0 = (uint64_t)x * per_px * p.bits;
            uint64_t nbits = (uint64_t)(p.w - x < tw ? p.w - x : tw) * per_px * p.bits;
            const uint8_t *src = chunk + r * tile_row;
            uint8_t *dst = planes[pl] + (uint64_t)(y + r) * row_bytes;
            if (bits0 % 8 == 0 && nbits % 8 == 0) {
              memcpy(dst + bits0 / 8, src, nbits / 8);
            } else {
              for (uint64_t k = 0; k < nbits; k++) {
                uint64_t to = bits0 + k;
                int bit = src[k / 8] >> (7 - k % 8) & 1;
                dst[to / 8] = (uint8_t)((dst[to / 8] & ~(0x80 >> (to % 8))) | bit << (7 - to % 8));
              }
            }
          }
        }
      }
    }
  } else {
    uint32_t rps;
    TIFFGetFieldDefaulted(tif, TIFFTAG_ROWSPERSTRIP, &rps);
    if (rps > p.h) rps = p.h;
    tmsize_t ss = TIFFStripSize(tif);
    if (ss <= 0) goto done;
    chunk = malloc((size_t)ss);
    for (int pl = 0; pl < nplanes; pl++) {
      for (uint32_t y = 0; y < p.h; y += rps) {
        tstrip_t s = TIFFComputeStrip(tif, y, (tsample_t)pl);
        uint32_t rows = p.h - y < rps ? p.h - y : rps;
        tmsize_t want = (tmsize_t)(rows * row_bytes);
        if (TIFFReadEncodedStrip(tif, s, chunk, want) < want || failed) goto done;
        memcpy(planes[pl] + (uint64_t)y * row_bytes, chunk, (size_t)want);
      }
    }
  }
  size_t bpp = pixel_bytes(format);
  out->len = (size_t)p.w * p.h * bpp;
  out->pixels = malloc(out->len + 1);
  uint64_t max = p.bits >= 64 ? ~0ull : (1ull << p.bits) - 1;
  int wide = p.bits > 8;
  int used = cc + (p.alpha ? 1 : 0);
  uint8_t *o = out->pixels;
  for (uint32_t y = 0; y < p.h; y++) {
    for (uint32_t x = 0; x < p.w; x++) {
      uint64_t v[5];
      float f[5];
      for (int c = 0; c < used; c++) {
        const uint8_t *row = planes[planar ? c : 0] + (uint64_t)y * row_bytes;
        uint64_t s = sample_at(row, planar ? x : (uint64_t)x * p.spp + c, p.bits);
        if (p.fmt == SAMPLEFORMAT_IEEEFP) {
          f[c] = sample_float(s, p.bits);
          continue;
        }
        if (p.fmt == SAMPLEFORMAT_INT) s ^= 1ull << (p.bits - 1);
        if (c == 0 && p.photometric == PHOTOMETRIC_MINISWHITE && p.alpha != 1) s = max - s;
        if (p.photometric == PHOTOMETRIC_PALETTE) {
          v[0] = s;
        } else if (wide) {
          v[c] = p.bits == 16 ? s : (s * 65535 + max / 2) / max;
        } else {
          v[c] = p.bits == 8 ? s : (s * 255 + max / 2) / max;
        }
      }
      // Premultiplied white-is-zero gray is alpha minus the sample.
      if (p.photometric == PHOTOMETRIC_MINISWHITE && p.alpha == 1 && p.fmt != SAMPLEFORMAT_IEEEFP)
        v[0] = v[used - 1] > v[0] ? v[used - 1] - v[0] : 0;
      if (p.fmt == SAMPLEFORMAT_IEEEFP && cc == 4) {
        // cmyk16's inverted inks, 1 - v rounded and clamped (NaN is 0),
        // then image.convert's naive RGB at 16 bits.
        uint64_t inv[4];
        for (int c = 0; c < 4; c++) {
          float i = 1 - f[c];
          inv[c] = !(i > 0) ? 0 : i >= 1 ? 65535 : (uint64_t)roundf(i * 65535);
        }
        for (int c = 0; c < 3; c++) {
          uint16_t s = (uint16_t)((2 * inv[c] * inv[3] + 65535) / (2 * 65535));
          memcpy(o, &s, 2);
          o += 2;
        }
        continue;
      }
      if (p.fmt == SAMPLEFORMAT_IEEEFP) {
        float px[4] = {0, 0, 0, 1};
        if (cc == 1) px[0] = px[1] = px[2] = f[0];
        else memcpy(px, f, 12);
        if (p.alpha) px[3] = f[used - 1];
        memcpy(o, px, 16);
        o += 16;
        continue;
      }
      if (p.photometric == PHOTOMETRIC_PALETTE) {
        for (int c = 0; c < 3; c++) {
          uint16_t e = p.cmap[c][v[0]];
          if (palette8) *o++ = (uint8_t)(e >> 8);
          else { memcpy(o, &e, 2); o += 2; }
        }
        continue;
      }
      uint64_t px[4];
      int k;
      if (cc == 4) {
        // The inverted inks of cmyk8 or cmyk16, then image.convert's naive
        // RGB at that depth: ink * black / max, rounded.
        uint64_t mm = wide ? 65535 : 255;
        for (int c = 0; c < 3; c++) px[c] = (2 * (mm - v[c]) * (mm - v[3]) + mm) / (2 * mm);
        k = 3;
      } else {
        for (int c = 0; c < cc; c++) px[c] = v[c];
        k = cc;
      }
      if (p.alpha) px[k++] = v[used - 1];
      for (int c = 0; c < k; c++) {
        if (wide) { uint16_t s = (uint16_t)px[c]; memcpy(o, &s, 2); o += 2; }
        else *o++ = (uint8_t)px[c];
      }
    }
  }
  out->width = p.w;
  out->height = p.h;
  result = STATUS_OK;
done:
  if (result == STATUS_REJECTED && long_line) result = STATUS_SKIPPED;
  if (result != STATUS_OK && out->pixels) {
    free(out->pixels);
    out->pixels = NULL;
  }
  if (planes) {
    for (int i = 0; i < nplanes; i++) free(planes[i]);
    free(planes);
  }
  free(chunk);
  TIFFClose(tif);
  return result;
}

const struct op tiff_ops[] = {
    {"tiff-rgba", tiff_rgba},
    {"tiff-raw", tiff_raw},
    {0},
};

// PNG's oracles: Wuffs, the bar, libpng (with the APNG patch nixpkgs
// applies), and libspng. Each decodes the first frame: Wuffs the
// animation's, libpng and libspng the default image. Each writes RGBA8 or
// BGRA16 (the 16-bit order Wuffs has for PNG), samples in the machine's
// byte order, with tRNS as alpha.
#include <png.h>
#include <setjmp.h>
#include <spng.h>
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

#include "oracle.h"

// The first frame through Wuffs's PNG decoder, as wuffs_decode does it.
static enum status wuffs_png(const uint8_t *in, size_t len, uint32_t pixfmt, size_t bpp,
                             uint64_t max_pixels, struct image *out) {
  enum status result = STATUS_REJECTED;
  uint8_t *work = NULL;
  wuffs_base__image_decoder *dec = wuffs_png__decoder__alloc_as__wuffs_base__image_decoder();
  wuffs_base__image_config ic = {0};
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)in, len, true);
  wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(dec, &ic, &src);
  if (!wuffs_base__status__is_ok(&st)) goto done;
  uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  wuffs_base__pixel_config__set(&ic.pixcfg, pixfmt, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
  out->len = (size_t)w * h * bpp;
  out->pixels = calloc(1, out->len ? out->len : 1);
  wuffs_base__pixel_buffer pb;
  st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg,
                                                wuffs_base__make_slice_u8(out->pixels, out->len));
  if (!wuffs_base__status__is_ok(&st)) goto done;
  uint64_t work_len = wuffs_base__image_decoder__workbuf_len(dec).max_incl;
  work = malloc(work_len ? work_len : 1);
  st = wuffs_base__image_decoder__decode_frame(dec, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC,
                                               wuffs_base__make_slice_u8(work, work_len), NULL);
  if (!wuffs_base__status__is_ok(&st)) goto done;
  out->width = w;
  out->height = h;
  result = STATUS_OK;
done:
  free(work);
  free(dec);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

// Where the tRNS chunk of a gray or truecolor image starts, before the
// first IDAT, or 0.
static size_t key_trns(const uint8_t *in, size_t len) {
  if (len < 26 || (in[25] != 0 && in[25] != 2)) return 0;
  for (size_t at = 8; at + 8 <= len;) {
    uint32_t n = (uint32_t)in[at] << 24 | in[at + 1] << 16 | in[at + 2] << 8 | in[at + 3];
    if (!memcmp(in + at + 4, "IDAT", 4)) return 0;
    if (!memcmp(in + at + 4, "tRNS", 4)) return at;
    if (n > len - at - 8) return 0;
    at += 12 + (size_t)n;
  }
  return 0;
}

// Wuffs writes the pixels a gray or truecolor tRNS makes transparent as
// transparent black, where libpng, libspng, and this package keep their
// color with alpha 0. To compare the rest of Wuffs's decode, such an image
// is decoded again with the tRNS chunk renamed to one Wuffs skips, and the
// transparent pixels take their color from that.
static enum status png_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  uint32_t pixfmt = format == PF_RGBA8    ? WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL
                    : format == PF_BGRA16 ? WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL_4X16LE
                                          : 0;
  if (!pixfmt) return STATUS_SKIPPED;
  size_t bpp = pixel_bytes(format);
  enum status s = wuffs_png(in, len, pixfmt, bpp, max_pixels, out);
  size_t trns = key_trns(in, len);
  if (s != STATUS_OK || !trns) return s;
  uint8_t *copy = malloc(len);
  memcpy(copy, in, len);
  copy[trns + 4] = 'x';
  struct image opaque = {0};
  enum status s2 = wuffs_png(copy, len, pixfmt, bpp, max_pixels, &opaque);
  free(copy);
  if (s2 != STATUS_OK || opaque.len != out->len) {
    free(out->pixels);
    out->pixels = NULL;
    free(opaque.pixels);
    return STATUS_REJECTED;
  }
  size_t a = bpp == 4 ? 3 : 6;
  for (size_t i = 0; i < out->len; i += bpp) {
    int clear = out->pixels[i + a] == 0 && (bpp == 4 || out->pixels[i + a + 1] == 0);
    if (clear) memcpy(out->pixels + i, opaque.pixels + i, a);
  }
  free(opaque.pixels);
  return STATUS_OK;
}

// RGBA16 to BGRA16, in place.
static void swap16(struct image *img) {
  uint16_t *p = (uint16_t *)img->pixels;
  for (size_t i = 0; i < img->len / 8; i++, p += 4) {
    uint16_t t = p[0];
    p[0] = p[2];
    p[2] = t;
  }
}

struct source {
  const uint8_t *p;
  size_t len, at;
};

static void libpng_read(png_structp png, png_bytep dst, size_t n) {
  struct source *s = png_get_io_ptr(png);
  if (s->len - s->at < n) png_error(png, "truncated");
  memcpy(dst, s->p + s->at, n);
  s->at += n;
}

static void libpng_error(png_structp png, png_const_charp msg) {
  (void)msg;
  png_longjmp(png, 1);
}

static void libpng_warning(png_structp png, png_const_charp msg) {
  (void)png;
  (void)msg;
}

// The classic API with libpng's own transformations, all defaults kept
// (an ancillary chunk's bad CRC is a warning, a critical one's an error),
// and png_read_end, so the chunks after the image are read too.
static enum status png_libpng(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8 && format != PF_BGRA16) return STATUS_SKIPPED;
  int wide = format == PF_BGRA16;
  struct source src = {in, len, 0};
  png_bytep *rows = NULL;
  png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, libpng_error, libpng_warning);
  png_infop info = png_create_info_struct(png);
  volatile enum status result = STATUS_REJECTED;
  if (setjmp(png_jmpbuf(png))) goto done;
  png_set_read_fn(png, &src, libpng_read);
  png_set_user_limits(png, 0x7fffffff, 0x7fffffff);
  png_read_info(png, info);
  uint32_t w = png_get_image_width(png, info), h = png_get_image_height(png, info);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  int depth = png_get_bit_depth(png, info), color = png_get_color_type(png, info);
  if (color == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
  if (color == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
  if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
  if (!(color & PNG_COLOR_MASK_COLOR)) png_set_gray_to_rgb(png);
  if (wide) {
    png_set_expand_16(png);
    png_set_bgr(png);
    png_set_swap(png);
  } else {
    png_set_strip_16(png);
  }
  png_set_add_alpha(png, 0xffff, PNG_FILLER_AFTER);
  png_set_interlace_handling(png);
  png_read_update_info(png, info);
  size_t stride = (size_t)w * (wide ? 8 : 4);
  if (png_get_rowbytes(png, info) != stride) goto done;
  out->len = stride * h;
  out->pixels = malloc(out->len);
  rows = malloc(h * sizeof *rows);
  for (uint32_t y = 0; y < h; y++) rows[y] = out->pixels + y * stride;
  png_read_image(png, rows);
  png_read_end(png, NULL);
  out->width = w;
  out->height = h;
  result = STATUS_OK;
done:
  png_destroy_read_struct(&png, &info, NULL);
  free(rows);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

// libspng's defaults.
static enum status png_spng(const uint8_t *in, size_t len, enum pixel_format format,
                            uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8 && format != PF_BGRA16) return STATUS_SKIPPED;
  enum status result = STATUS_REJECTED;
  int fmt = format == PF_RGBA8 ? SPNG_FMT_RGBA8 : SPNG_FMT_RGBA16;
  spng_ctx *ctx = spng_ctx_new(0);
  struct spng_ihdr ihdr;
  size_t n;
  if (spng_set_png_buffer(ctx, in, len) || spng_get_ihdr(ctx, &ihdr)) goto done;
  if ((uint64_t)ihdr.width * ihdr.height > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  if (spng_decoded_image_size(ctx, fmt, &n)) goto done;
  out->pixels = malloc(n ? n : 1);
  out->len = n;
  if (spng_decode_image(ctx, out->pixels, n, fmt, SPNG_DECODE_TRNS)) goto done;
  out->width = ihdr.width;
  out->height = ihdr.height;
  if (fmt == SPNG_FMT_RGBA16) swap16(out);
  result = STATUS_OK;
done:
  spng_ctx_free(ctx);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

// The HDR chunks libpng reads before the image data, as png.zig's `hdr`
// lays out this package's `Metadata`: a byte of flags (1 cICP, 2 mDCV, 4
// cLLI), cICP's four bytes, mDCV's eight chromaticities (red, green, blue,
// white; x then y) and its minimum and maximum luminance, then cLLI's
// MaxCLL and MaxFALL, as native f32s, zero where a chunk is absent. Each
// float is the stored integer over its divisor in double, rounded to
// float. A gray8 "image" one row of 53 bytes.
#define HDR_LEN 53
static enum status png_libpng_hdr(const uint8_t *in, size_t len, enum pixel_format format,
                                  uint64_t max_pixels, struct image *out) {
  (void)max_pixels;
  if (format != PF_GRAY8) return STATUS_SKIPPED;
  struct source src = {in, len, 0};
  png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, libpng_error, libpng_warning);
  png_infop info = png_create_info_struct(png);
  volatile enum status result = STATUS_SKIPPED;
  if (setjmp(png_jmpbuf(png))) goto done;
  png_set_read_fn(png, &src, libpng_read);
  png_set_user_limits(png, 0x7fffffff, 0x7fffffff);
  png_read_info(png, info);
  uint8_t rec[HDR_LEN] = {0};
  float f[12] = {0};
  png_byte cicp[4];
  if (png_get_cICP(png, info, &cicp[0], &cicp[1], &cicp[2], &cicp[3])) {
    rec[0] |= 1;
    memcpy(rec + 1, cicp, 4);
  }
  png_fixed_point wx, wy, rx, ry, gx, gy, bx, by;
  png_uint_32 maxdl, mindl, cll, fall;
  if (png_get_mDCV_fixed(png, info, &wx, &wy, &rx, &ry, &gx, &gy, &bx, &by, &maxdl, &mindl)) {
    rec[0] |= 2;
    // libpng holds the chromaticities times 100,000, twice what mDCV stores.
    png_fixed_point xy[8] = {rx, ry, gx, gy, bx, by, wx, wy};
    for (int i = 0; i < 8; i++) f[i] = (float)((double)(xy[i] / 2) / 50000.0);
    f[8] = (float)((double)mindl / 10000.0);
    f[9] = (float)((double)maxdl / 10000.0);
  }
  if (png_get_cLLI_fixed(png, info, &cll, &fall)) {
    rec[0] |= 4;
    f[10] = (float)((double)cll / 10000.0);
    f[11] = (float)((double)fall / 10000.0);
  }
  memcpy(rec + 5, f, sizeof f);
  out->pixels = malloc(HDR_LEN);
  memcpy(out->pixels, rec, HDR_LEN);
  out->len = HDR_LEN;
  out->width = HDR_LEN;
  out->height = 1;
  result = STATUS_OK;
done:
  png_destroy_read_struct(&png, &info, NULL);
  return result;
}

const struct op png_ops[] = {
    {"png-wuffs", png_wuffs},
    {"png-libpng", png_libpng},
    {"png-spng", png_spng},
    {"png-libpng-hdr", png_libpng_hdr},
    {0},
};

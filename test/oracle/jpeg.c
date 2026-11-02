// JPEG's oracles: libjpeg-turbo, the bar, through its libjpeg API with its
// default decoding choices (the accurate integer IDCT and fancy
// upsampling), and Wuffs.
//
// libjpeg-turbo runs strict: a warning is an error, as with TurboJPEG's
// TJFLAG_STOPONWARNING, except three that cannot change the pixels: bytes
// that are not a marker between segments (JWRN_EXTRANEOUS_DATA, which it
// counts after its own read-ahead), Ss, Se, Ah, and Al that are not
// 0, 63, 0, 0 in a sequential scan (JWRN_NOT_SEQUENTIAL), and a JFIF major
// version other than 1. It runs without SIMD (JSIMD_FORCENONE), whose
// IDCT saturates where the C code wraps on corrupt data, and without
// block smoothing, which it applies to progressive images whose scans
// leave low AC coefficients unrefined (test/oracle/jpeg.zig).
//
// It writes RGB for any image and gray for a grayscale one, 8- or 16-bit,
// and RGB for CMYK and YCCK through its naive conversion (cmyk.h, as
// djpeg's PPM writer does), each channel the ink's inverse times black's,
// at the image's precision. CMYK and YCCK images also decode to their inks
// as cmyk8 and cmyk16: libjpeg-turbo's JCS_CMYK output, the stored samples
// for CMYK and YCCK's converted, and inverted, from YCbCr; it converts no
// other color space to inks, and in lossless mode not YCCK, so those are
// skipped or rejected. Samples of other precisions than 8 bits (12,
// and 2 to 16 lossless) are clamped to their precision, as unsigned 16-bit
// values when they are wider than 8, and scaled to the output's, rounded;
// 8-bit output from samples past 8 bits is the high byte of the 16-bit
// value, as this package converts 16-bit pixels to 8.
#define _POSIX_C_SOURCE 200112L
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>
#include <jerror.h>
#include <ultrahdr_api.h>

#include "wuffs-v0.4.c"

#include "oracle.h"

struct strict {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
};

static void strict_exit(j_common_ptr cinfo) {
  longjmp(((struct strict *)cinfo->err)->jump, 1);
}

// A warning is level -1; trace messages are higher and ignored.
static void strict_emit(j_common_ptr cinfo, int level) {
  if (level >= 0) return;
  int code = cinfo->err->msg_code;
  if (code == JWRN_EXTRANEOUS_DATA || code == JWRN_NOT_SEQUENTIAL || code == JWRN_JFIF_MAJOR) return;
  longjmp(((struct strict *)cinfo->err)->jump, 1);
}

__attribute__((constructor)) static void no_simd(void) { setenv("JSIMD_FORCENONE", "1", 1); }

// A memory source that hands libjpeg-turbo 256 bytes at a time. Its
// sequential Huffman decoder takes a fast path when 512 bytes per block of
// the MCU are buffered, which decodes a code its table lacks as symbol 0
// without a warning; with this source it always takes the strict path, as
// it does near the end of every file.
struct chunked {
  struct jpeg_source_mgr pub;
  const uint8_t *data;
  size_t len, at;
};

static void chunked_init(j_decompress_ptr cinfo) { (void)cinfo; }

static boolean chunked_fill(j_decompress_ptr cinfo) {
  static const JOCTET eoi[2] = {0xFF, JPEG_EOI};
  struct chunked *src = (struct chunked *)cinfo->src;
  if (src->at >= src->len) {
    WARNMS(cinfo, JWRN_JPEG_EOF);
    src->pub.next_input_byte = eoi;
    src->pub.bytes_in_buffer = 2;
    return TRUE;
  }
  size_t n = src->len - src->at < 256 ? src->len - src->at : 256;
  src->pub.next_input_byte = src->data + src->at;
  src->pub.bytes_in_buffer = n;
  src->at += n;
  return TRUE;
}

static void chunked_skip(j_decompress_ptr cinfo, long n) {
  struct jpeg_source_mgr *src = cinfo->src;
  while (n > (long)src->bytes_in_buffer) {
    n -= (long)src->bytes_in_buffer;
    chunked_fill(cinfo);
  }
  src->next_input_byte += n;
  src->bytes_in_buffer -= (size_t)n;
}

static void chunked_term(j_decompress_ptr cinfo) { (void)cinfo; }

// One sample `v` of precision `prec`, already clamped to it, in the
// output's 8 or 16 bits: scaled to 8 bits (to 16 past 8), rounded, then
// widened or narrowed as this package converts its native format.
static unsigned scale(unsigned v, unsigned prec, int wide) {
  unsigned max = (1u << prec) - 1;
  if (prec <= 8) {
    unsigned b = (unsigned)(((uint64_t)v * 255 + max / 2) / max);
    return wide ? b * 257 : b;
  }
  unsigned w = (unsigned)(((uint64_t)v * 65535 + max / 2) / max);
  return wide ? w : w >> 8;
}

static enum status jpeg_turbo(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  int inks = format == PF_CMYK8 || format == PF_CMYK16;
  int alpha = format == PF_GRAY_ALPHA8 || format == PF_GRAY_ALPHA16;
  int wide = format == PF_RGB16 || format == PF_GRAY16 || format == PF_CMYK16 || format == PF_GRAY_ALPHA16;
  if (format != PF_RGB8 && format != PF_GRAY8 && format != PF_CMYK8 && format != PF_GRAY_ALPHA8 && !wide)
    return STATUS_SKIPPED;
  struct jpeg_decompress_struct cinfo;
  struct strict err;
  void *row = NULL;
  volatile enum status result = STATUS_REJECTED;
  out->pixels = NULL;
  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = strict_exit;
  err.pub.emit_message = strict_emit;
  jpeg_create_decompress(&cinfo);
  if (setjmp(err.jump)) goto done;
  struct chunked src = {{0}, in, len, 0};
  src.pub.init_source = chunked_init;
  src.pub.fill_input_buffer = chunked_fill;
  src.pub.skip_input_data = chunked_skip;
  src.pub.resync_to_restart = jpeg_resync_to_restart;
  src.pub.term_source = chunked_term;
  cinfo.src = &src.pub;
  jpeg_read_header(&cinfo, TRUE);
  unsigned prec = (unsigned)cinfo.data_precision;
  if ((uint64_t)cinfo.image_width * cinfo.image_height > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  int cmyk = cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK;
  int gray_out = format == PF_GRAY8 || format == PF_GRAY16;
  // Two components (TIFF's gray and alpha) libjpeg-turbo reads as
  // JCS_UNKNOWN and returns unconverted; they compare as gray and alpha,
  // as gray alone, and as gray copied to RGB, as this package converts its
  // native gray_alpha. Gray with alpha also compares for a gray image,
  // opaque; not for color, which would need this package's RGB to gray.
  int two = cinfo.num_components == 2;
  if ((gray_out && cinfo.num_components > 2) || (alpha && cinfo.num_components > 2) || (inks && !cmyk)) {
    result = STATUS_SKIPPED;
    goto done;
  }
  // A grayscale image decodes as gray and is copied to RGB here: in
  // lossless mode libjpeg-turbo converts no colors, not even gray to RGB.
  cinfo.out_color_space = cinfo.num_components == 1 ? JCS_GRAYSCALE : two ? JCS_UNKNOWN : cmyk ? JCS_CMYK : JCS_RGB;
  cinfo.do_block_smoothing = FALSE;
  jpeg_start_decompress(&cinfo);
  size_t bpp = pixel_bytes(format);
  size_t stride = (size_t)cinfo.output_width * bpp;
  size_t ch = (size_t)cinfo.output_components;
  out->width = cinfo.output_width;
  out->height = cinfo.output_height;
  out->len = stride * cinfo.output_height;
  out->pixels = malloc(out->len ? out->len : 1);
  row = malloc((size_t)cinfo.output_width * ch * 2 + 1);
  unsigned max = (1u << prec) - 1;
  size_t out_ch = gray_out ? 1 : alpha ? 2 : inks ? 4 : 3;
  while (cinfo.output_scanline < cinfo.output_height) {
    size_t y = cinfo.output_scanline;
    // libjpeg-turbo's sample types: 8 bits to 8, 12-bit (signed) to 12,
    // and 16-bit (unsigned) past 12.
    if (prec <= 8) {
      JSAMPROW r = row;
      jpeg_read_scanlines(&cinfo, &r, 1);
    } else if (prec <= 12) {
      J12SAMPROW r = row;
      jpeg12_read_scanlines(&cinfo, &r, 1);
    } else {
      J16SAMPROW r = row;
      jpeg16_read_scanlines(&cinfo, &r, 1);
    }
    uint8_t *dst = out->pixels + y * stride;
    for (size_t x = 0; x < cinfo.output_width; x++) {
      unsigned p[4] = {0};
      for (size_t c = 0; c < ch; c++) {
        unsigned v = prec <= 8 ? ((uint8_t *)row)[x * ch + c] : ((uint16_t *)row)[x * ch + c];
        p[c] = v > max ? max : v;
      }
      if (ch == 1 && alpha) p[1] = max;
      else if (ch == 1 || (two && !alpha)) p[1] = p[2] = p[0];
      if (cmyk && !inks) {
        for (int c = 0; c < 3; c++) p[c] = (unsigned)((2 * (uint64_t)p[c] * p[3] + max) / (2 * max));
      }
      for (size_t c = 0; c < out_ch; c++) {
        unsigned v = scale(p[c], prec, wide);
        if (wide) {
          uint16_t w = (uint16_t)v;
          memcpy(dst + (x * out_ch + c) * 2, &w, 2);
        } else {
          dst[x * out_ch + c] = (uint8_t)v;
        }
      }
    }
  }
  jpeg_finish_decompress(&cinfo);
  result = STATUS_OK;
done:
  jpeg_destroy_decompress(&cinfo);
  free(row);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

static enum status jpeg_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  // Wuffs's 16-bit output would only widen its 8-bit pixels.
  if (format != PF_RGB8 && format != PF_GRAY8) return STATUS_SKIPPED;
  return wuffs_decode(wuffs_jpeg__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// The encoder's settings for a `width` by `height` source, drawn from its
// size so that both sides choose them alike (test/oracle/jpeg_encode.zig's
// `settingsFor` is the same): quality 1 to 100, subsampling, progressive or
// baseline, optimized or standard tables, and sometimes an EXIF block, an
// ICC profile, or both, the profile then long enough to take two segments.
struct settings {
  int quality, subsampling, progressive, optimize;
  uint32_t key, exif_len, icc_len;
};

static struct settings settings_for(uint32_t width, uint32_t height) {
  uint32_t k = width * 0x9E3779B1u ^ height * 0x85EBCA77u;
  k ^= k >> 15;
  k *= 0x2C1B3C6Du;
  k ^= k >> 12;
  struct settings s = {
      .quality = 1 + (int)(k % 100),
      .subsampling = (int)((k >> 8) % 3),
      .progressive = (int)((k >> 10) & 1),
      .optimize = (int)((k >> 11) & 1),
      .key = k,
  };
  uint32_t meta = (k >> 12) & 7;
  if (meta == 5 || meta == 7) s.exif_len = 1 + (k >> 16) % 2000;
  if (meta == 6) s.icc_len = 1 + (k >> 16) % 3000;
  if (meta == 7) s.icc_len = 65520 + (k >> 16) % 70000;
  return s;
}

// libjpeg-turbo's encoder, for this package's (test/oracle/jpeg_encode.zig):
// RGB, RGBA with its alpha ignored, or gray, at the settings above, with
// the islow DCT and libjpeg's defaults otherwise (JFIF, no restarts), and
// tables limited to baseline's 8 bits (TurboJPEG's choice).
static enum status jpeg_turbo_encode(const uint8_t *pixels, enum pixel_format format,
                                     uint32_t width, uint32_t height, struct image *out) {
  int ch;
  J_COLOR_SPACE space;
  switch (format) {
  case PF_RGB8: ch = 3; space = JCS_RGB; break;
  case PF_RGBA8: ch = 4; space = JCS_EXT_RGBA; break;
  case PF_GRAY8: ch = 1; space = JCS_GRAYSCALE; break;
  default: return STATUS_SKIPPED;
  }
  struct settings s = settings_for(width, height);
  uint8_t *volatile meta = NULL;
  unsigned char *buf = NULL;
  unsigned long len = 0;
  struct jpeg_compress_struct cinfo;
  struct strict err;
  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = strict_exit;
  if (setjmp(err.jump)) {
    jpeg_destroy_compress(&cinfo);
    free(buf);
    free(meta);
    return STATUS_REJECTED;
  }
  jpeg_create_compress(&cinfo);
  jpeg_mem_dest(&cinfo, &buf, &len);
  cinfo.image_width = width;
  cinfo.image_height = height;
  cinfo.input_components = ch;
  cinfo.in_color_space = space;
  jpeg_set_defaults(&cinfo);
  jpeg_set_quality(&cinfo, s.quality, TRUE);
  if (ch != 1) {
    cinfo.comp_info[0].h_samp_factor = s.subsampling == 0 ? 1 : 2;
    cinfo.comp_info[0].v_samp_factor = s.subsampling == 2 ? 2 : 1;
  }
  cinfo.optimize_coding = s.optimize;
  if (s.progressive) jpeg_simple_progression(&cinfo);
  jpeg_start_compress(&cinfo, TRUE);
  uint32_t most = s.exif_len > s.icc_len ? s.exif_len : s.icc_len;
  if (most) {
    meta = malloc(6 + most);
    if (!meta) longjmp(err.jump, 1);
  }
  if (s.exif_len) {
    memcpy(meta, "Exif\0\0", 6);
    for (uint32_t i = 0; i < s.exif_len; i++) meta[6 + i] = (uint8_t)(i * 131 + s.key);
    jpeg_write_marker(&cinfo, JPEG_APP0 + 1, meta, 6 + s.exif_len);
  }
  if (s.icc_len) {
    for (uint32_t i = 0; i < s.icc_len; i++) meta[i] = (uint8_t)(i * 71 + (s.key >> 8));
    jpeg_write_icc_profile(&cinfo, meta, s.icc_len);
  }
  while (cinfo.next_scanline < height) {
    JSAMPROW row = (JSAMPROW)(pixels + (size_t)cinfo.next_scanline * width * ch);
    jpeg_write_scanlines(&cinfo, &row, 1);
  }
  jpeg_finish_compress(&cinfo);
  jpeg_destroy_compress(&cinfo);
  free(meta);
  out->pixels = buf;
  out->len = len;
  return STATUS_OK;
}

const struct op jpeg_encode_ops[] = {
    {"jpeg-turbo-encode", .encode = jpeg_turbo_encode},
    {0},
};

// Whether libultrahdr finds a gain map (`is_uhdr_image`), as jpeg.zig's
// `gain_map` lays out this package's flag: a gray8 "image" of one byte, 1
// or 0. libultrahdr finds the gain map image as the second JPEG in the
// file and parses its metadata (XMP or ISO 21496-1); it never rejects.
static enum status jpeg_uhdr(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  (void)max_pixels;
  if (format != PF_GRAY8) return STATUS_SKIPPED;
  out->pixels = malloc(1);
  // It crashes on an empty input, which holds no gain map.
  out->pixels[0] = (uint8_t)(len > 0 && is_uhdr_image((void *)in, (int)len));
  out->len = 1;
  out->width = 1;
  out->height = 1;
  return STATUS_OK;
}

const struct op jpeg_ops[] = {
    {"jpeg-turbo", jpeg_turbo},
    {"jpeg-wuffs", jpeg_wuffs},
    {"jpeg-uhdr", jpeg_uhdr},
    {0},
};

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
// It writes RGB8 for any image, gray8 for a grayscale one, and RGB for
// CMYK and YCCK through its naive conversion (cmyk.h, as djpeg's PPM
// writer does), each channel the ink's inverse times black's.
#define _POSIX_C_SOURCE 200112L
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>
#include <jerror.h>

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

static enum status jpeg_turbo(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  if (format != PF_RGB8 && format != PF_GRAY8) return STATUS_SKIPPED;
  struct jpeg_decompress_struct cinfo;
  struct strict err;
  JSAMPROW row = NULL;
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
  // libjpeg-turbo decodes 12-bit and lossless images through other
  // entry points.
  if (cinfo.data_precision != 8) {
    result = STATUS_SKIPPED;
    goto done;
  }
  if ((uint64_t)cinfo.image_width * cinfo.image_height > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  int cmyk = cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK;
  if (format == PF_GRAY8) {
    if (cinfo.num_components != 1) {
      result = STATUS_SKIPPED;
      goto done;
    }
    cinfo.out_color_space = JCS_GRAYSCALE;
  } else {
    cinfo.out_color_space = cmyk ? JCS_CMYK : JCS_RGB;
  }
  cinfo.do_block_smoothing = FALSE;
  jpeg_start_decompress(&cinfo);
  size_t bpp = pixel_bytes(format);
  size_t stride = (size_t)cinfo.output_width * bpp;
  out->width = cinfo.output_width;
  out->height = cinfo.output_height;
  out->len = stride * cinfo.output_height;
  out->pixels = malloc(out->len ? out->len : 1);
  row = malloc((size_t)cinfo.output_width * cinfo.output_components + 1);
  while (cinfo.output_scanline < cinfo.output_height) {
    size_t y = cinfo.output_scanline;
    jpeg_read_scanlines(&cinfo, &row, 1);
    uint8_t *dst = out->pixels + y * stride;
    if (!cmyk) {
      memcpy(dst, row, stride);
      continue;
    }
    for (size_t x = 0; x < cinfo.output_width; x++) {
      unsigned k = row[4 * x + 3];
      for (int c = 0; c < 3; c++) {
        dst[3 * x + c] = (uint8_t)((double)row[4 * x + c] * (double)k / 255.0 + 0.5);
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
  if (format != PF_RGB8 && format != PF_GRAY8) return STATUS_SKIPPED;
  return wuffs_decode(wuffs_jpeg__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

const struct op jpeg_ops[] = {
    {"jpeg-turbo", jpeg_turbo},
    {"jpeg-wuffs", jpeg_wuffs},
    {0},
};

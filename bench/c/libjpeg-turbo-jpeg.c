// libjpeg-turbo through the libjpeg API, from memory, to RGB8 with its
// default settings (the accurate integer IDCT and fancy upsampling, with
// its SIMD), scanlines straight into the caller's buffer. CMYK and YCCK
// files decode to libjpeg-turbo's inks, a row at a time, converted to RGB
// naively as djpeg converts them (each channel the ink times black over
// 255, rounded). Errors longjmp out. 12-bit files
// decode to its 12-bit samples, six bytes a pixel, unscaled (this package
// scales them to 16 bits), so that operation's checksums differ.
//
// The encode rows compress raw RGB8 or gray pixels with its defaults (the
// islow forward DCT, JFIF, its SIMD) at quality 85 with baseline tables,
// as TurboJPEG does, into the caller's buffer through a destination
// manager; this package's files are the same bytes.
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>

#include <jpeglib.h>
#include <jerror.h>

#include "arm.h"

struct fail {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
};

static void fail_exit(j_common_ptr cinfo) { longjmp(((struct fail *)cinfo->err)->jump, 1); }
static void quiet(j_common_ptr cinfo, int level) {
  (void)cinfo;
  (void)level;
}

static size_t decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int wide) {
  struct jpeg_decompress_struct cinfo;
  struct fail err;
  volatile size_t result = 0;
  uint8_t *volatile inks = NULL;
  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = fail_exit;
  err.pub.emit_message = quiet;
  jpeg_create_decompress(&cinfo);
  if (setjmp(err.jump)) goto done;
  jpeg_mem_src(&cinfo, in, (unsigned long)len);
  jpeg_read_header(&cinfo, TRUE);
  int cmyk = cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK;
  cinfo.out_color_space = cmyk ? JCS_CMYK : JCS_RGB;
  jpeg_start_decompress(&cinfo);
  size_t stride = (size_t)cinfo.output_width * (wide ? 6 : 3);
  if (cinfo.output_components != (cmyk ? 4 : 3) || stride * cinfo.output_height > cap) goto done;
  if (cmyk) {
    if (wide || !(inks = malloc((size_t)cinfo.output_width * 4))) goto done;
    while (cinfo.output_scanline < cinfo.output_height) {
      uint8_t *o = out + cinfo.output_scanline * stride;
      JSAMPROW r = inks;
      jpeg_read_scanlines(&cinfo, &r, 1);
      for (size_t x = 0; x < cinfo.output_width; x++) {
        unsigned k = inks[4 * x + 3];
        for (int c = 0; c < 3; c++) o[3 * x + c] = (uint8_t)((2 * inks[4 * x + c] * k + 255) / 510);
      }
    }
  }
  while (cinfo.output_scanline < cinfo.output_height) {
    JSAMPROW rows[16];
    J12SAMPROW rows12[16];
    int n = 0;
    while (n < 16 && cinfo.output_scanline + n < cinfo.output_height) {
      rows[n] = out + (cinfo.output_scanline + n) * stride;
      rows12[n] = (J12SAMPROW)(void *)rows[n];
      n++;
    }
    if (wide) {
      jpeg12_read_scanlines(&cinfo, rows12, n);
    } else {
      jpeg_read_scanlines(&cinfo, rows, n);
    }
  }
  jpeg_finish_decompress(&cinfo);
  result = stride * cinfo.output_height;
done:
  jpeg_destroy_decompress(&cinfo);
  free(inks);
  return result;
}

static size_t jpeg_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode(in, len, out, cap, 0);
}

// The same call on every row; BENCH_OP needs a function per registration.
static size_t jpeg_progressive(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_444(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}

static size_t jpeg_arith(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_lossless(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_cmyk(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_12bit(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode(in, len, out, cap, 1);
}

struct fixed_dest {
  struct jpeg_destination_mgr pub;
  int full;
};

static void dest_init(j_compress_ptr cinfo) { (void)cinfo; }
static boolean dest_empty(j_compress_ptr cinfo) {
  // Out of room: fail the call rather than grow.
  ((struct fixed_dest *)cinfo->dest)->full = 1;
  ERREXIT(cinfo, JERR_BUFFER_SIZE);
  return FALSE;
}
static void dest_term(j_compress_ptr cinfo) { (void)cinfo; }

enum mode { M420, M444, OPTIMIZED, PROGRESSIVE, GRAY };

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, enum mode m) {
  int ch = m == GRAY ? 1 : 3;
  size_t stride = (size_t)bench_width * ch;
  if (len != stride * bench_height) return 0;
  struct jpeg_compress_struct cinfo;
  struct fail err;
  struct fixed_dest dest = {{0}, 0};
  volatile size_t result = 0;
  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = fail_exit;
  err.pub.emit_message = quiet;
  jpeg_create_compress(&cinfo);
  if (setjmp(err.jump)) goto done;
  dest.pub.next_output_byte = out;
  dest.pub.free_in_buffer = cap;
  dest.pub.init_destination = dest_init;
  dest.pub.empty_output_buffer = dest_empty;
  dest.pub.term_destination = dest_term;
  cinfo.dest = &dest.pub;
  cinfo.image_width = bench_width;
  cinfo.image_height = bench_height;
  cinfo.input_components = ch;
  cinfo.in_color_space = m == GRAY ? JCS_GRAYSCALE : JCS_RGB;
  jpeg_set_defaults(&cinfo);
  jpeg_set_quality(&cinfo, m == M444 ? 95 : 85, TRUE);
  if (m == M444) cinfo.comp_info[0].h_samp_factor = cinfo.comp_info[0].v_samp_factor = 1;
  cinfo.optimize_coding = m == OPTIMIZED;
  if (m == PROGRESSIVE) jpeg_simple_progression(&cinfo);
  jpeg_start_compress(&cinfo, TRUE);
  while (cinfo.next_scanline < cinfo.image_height) {
    JSAMPROW rows[16];
    int n = 0;
    while (n < 16 && cinfo.next_scanline + n < cinfo.image_height) {
      rows[n] = (JSAMPROW)(in + (cinfo.next_scanline + n) * stride);
      n++;
    }
    jpeg_write_scanlines(&cinfo, rows, n);
  }
  jpeg_finish_compress(&cinfo);
  result = cap - dest.pub.free_in_buffer;
done:
  jpeg_destroy_compress(&cinfo);
  return result;
}

static size_t jpeg_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, M420);
}
static size_t jpeg_encode_444(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, M444);
}
static size_t jpeg_encode_optimized(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, OPTIMIZED);
}
static size_t jpeg_encode_progressive(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, PROGRESSIVE);
}
static size_t jpeg_encode_gray(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, GRAY);
}

BENCH_OP("jpeg-decode", jpeg_decode)
BENCH_OP("jpeg-decode-progressive", jpeg_progressive)
BENCH_OP("jpeg-decode-444", jpeg_444)
BENCH_OP("jpeg-decode-arith", jpeg_arith)
BENCH_OP("jpeg-decode-12bit", jpeg_12bit)
BENCH_OP("jpeg-decode-lossless", jpeg_lossless)
BENCH_OP("jpeg-decode-cmyk", jpeg_cmyk)
BENCH_OP("jpeg-encode", jpeg_encode)
BENCH_OP("jpeg-encode-444", jpeg_encode_444)
BENCH_OP("jpeg-encode-optimized", jpeg_encode_optimized)
BENCH_OP("jpeg-encode-progressive", jpeg_encode_progressive)
BENCH_OP("jpeg-encode-gray", jpeg_encode_gray)

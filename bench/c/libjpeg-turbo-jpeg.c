// libjpeg-turbo through the libjpeg API, from memory, to RGB8 with its
// default settings (the accurate integer IDCT and fancy upsampling, with
// its SIMD), scanlines straight into the caller's buffer. CMYK and YCCK
// files are not converted, so they fail. Errors longjmp out.
#include <setjmp.h>
#include <stdio.h>

#include <jpeglib.h>

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

static size_t jpeg_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  struct jpeg_decompress_struct cinfo;
  struct fail err;
  volatile size_t result = 0;
  cinfo.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = fail_exit;
  err.pub.emit_message = quiet;
  jpeg_create_decompress(&cinfo);
  if (setjmp(err.jump)) goto done;
  jpeg_mem_src(&cinfo, in, (unsigned long)len);
  jpeg_read_header(&cinfo, TRUE);
  cinfo.out_color_space = JCS_RGB;
  jpeg_start_decompress(&cinfo);
  size_t stride = (size_t)cinfo.output_width * 3;
  if (cinfo.output_components != 3 || stride * cinfo.output_height > cap) goto done;
  while (cinfo.output_scanline < cinfo.output_height) {
    JSAMPROW rows[16];
    int n = 0;
    while (n < 16 && cinfo.output_scanline + n < cinfo.output_height) {
      rows[n] = out + (cinfo.output_scanline + n) * stride;
      n++;
    }
    jpeg_read_scanlines(&cinfo, rows, n);
  }
  jpeg_finish_decompress(&cinfo);
  result = stride * cinfo.output_height;
done:
  jpeg_destroy_decompress(&cinfo);
  return result;
}

// The same call on every row; BENCH_OP needs a function per registration.
static size_t jpeg_progressive(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}
static size_t jpeg_444(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jpeg_decode(in, len, out, cap);
}

BENCH_OP("jpeg-decode", jpeg_decode)
BENCH_OP("jpeg-decode-progressive", jpeg_progressive)
BENCH_OP("jpeg-decode-444", jpeg_444)

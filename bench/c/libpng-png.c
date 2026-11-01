// libpng's classic API, from memory, to RGBA8 with its own transformations
// (the simplified API would apply gamma to some files). The row pointers
// are kept between calls.
#include <png.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

#include "arm.h"

struct source {
  const uint8_t *p;
  size_t len, at;
};

static void read_fn(png_structp png, png_bytep dst, size_t n) {
  struct source *s = png_get_io_ptr(png);
  if (s->len - s->at < n) png_error(png, "truncated");
  memcpy(dst, s->p + s->at, n);
  s->at += n;
}

static void quiet(png_structp png, png_const_charp msg) {
  (void)png;
  (void)msg;
}

static void fail(png_structp png, png_const_charp msg) {
  (void)msg;
  png_longjmp(png, 1);
}

static png_bytep *rows;
static size_t rows_cap;

static size_t png_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  struct source src = {in, len, 0};
  png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, fail, quiet);
  png_infop info = png_create_info_struct(png);
  volatile size_t result = 0;
  if (setjmp(png_jmpbuf(png))) goto done;
  png_set_read_fn(png, &src, read_fn);
  png_set_user_limits(png, 0x7fffffff, 0x7fffffff);
  png_read_info(png, info);
  uint32_t w = png_get_image_width(png, info), h = png_get_image_height(png, info);
  int depth = png_get_bit_depth(png, info), color = png_get_color_type(png, info);
  if (color == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
  if (color == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
  if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
  if (!(color & PNG_COLOR_MASK_COLOR)) png_set_gray_to_rgb(png);
  png_set_scale_16(png);
  png_set_add_alpha(png, 0xff, PNG_FILLER_AFTER);
  png_set_interlace_handling(png);
  png_read_update_info(png, info);
  size_t stride = (size_t)w * 4;
  if (png_get_rowbytes(png, info) != stride || stride * h > cap) goto done;
  if (h > rows_cap) {
    free(rows);
    rows = malloc(h * sizeof *rows);
    rows_cap = h;
  }
  for (uint32_t y = 0; y < h; y++) rows[y] = out + y * stride;
  png_read_image(png, rows);
  png_read_end(png, NULL);
  result = stride * h;
done:
  png_destroy_read_struct(&png, &info, NULL);
  return result;
}

BENCH_OP("png-decode", png_decode)

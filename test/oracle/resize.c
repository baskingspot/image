// image.resize's oracle: stb_image_resize2, the bar, with the request's
// filter, edge mode, colorspace, and alpha handling (test/oracle/resize.zig).
// A request is a header and the bytes its source's samples are made from,
// as test/fuzz/resize.zig describes; the reply is the destination.
//
// stb_image_resize2 has every filter but two, and both edge modes but two,
// as image.resize defines them. Lanczos-3 and nearest neighbor (its
// POINT_SAMPLE averages the pixels a destination pixel covers when an axis
// shrinks) go in as kernel callbacks. Its REFLECT mirrors about the edge
// pixel's center on the left and top edges, and about the edge itself on
// the right and bottom, and its WRAP goes round only once. Its ZERO, when
// the vertical axis shrinks, weighs the rows past the top edge unlike its
// horizontal pass and unlike image.resize (a flat column of 53 rows to 5
// with Catmull-Rom: 1.0543 in the second row, against 1.0130 across a
// row). So every edge mode but clamp is done here: the source is padded
// with what the edge mode reads, further than the filter reaches, by whole
// periods of the ratio, and the padded image is resized to the padded
// destination and cropped. (Through stb's input subrectangle instead, a
// 4-channel resize of a padded 248-pixel row to 57 wrote 255 into the
// last pixel's last two samples, and results varied between runs.)
//
// Straight alpha is premultiplied and unpremultiplied plainly
// (stbir_set_non_pm_alpha_speed_over_quality), as image.resize does,
// without stb's fill of fully transparent pixels. Nearest neighbor copies
// pixels, so it goes through the premultiplied layout, which copies a
// transparent pixel's color rather than losing it.
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_STATIC
#include "stb/stb_image_resize2.h"

#include "oracle.h"

#include "resize.h"

// The layout, or -1 for formats it has none for.
static int layout_of(enum pixel_format f) {
  switch (f) {
    case PF_GRAY8: case PF_GRAY16: case PF_GRAY_F32: return STBIR_1CHANNEL;
    case PF_GRAY_ALPHA8: case PF_GRAY_ALPHA16: return STBIR_RA;
    case PF_GRAY_ALPHA8_PREMUL: case PF_GRAY_ALPHA16_PREMUL: return STBIR_RA_PM;
    case PF_RGB8: case PF_RGB16: case PF_RGB_F32: return STBIR_RGB;
    case PF_BGR8: case PF_BGR16: return STBIR_BGR;
    case PF_RGBA8: case PF_RGBA16: case PF_RGBA_F32: return STBIR_RGBA;
    case PF_RGBA8_PREMUL: case PF_RGBA16_PREMUL: case PF_RGBA_F32_PREMUL: return STBIR_RGBA_PM;
    case PF_BGRA8: case PF_BGRA16: return STBIR_BGRA;
    case PF_BGRA8_PREMUL: case PF_BGRA16_PREMUL: return STBIR_BGRA_PM;
    case PF_CMYK8: case PF_CMYK16: return STBIR_4CHANNEL;
  }
  return -1;
}

// Kernel callbacks get distances in source pixels on an axis that grows,
// and in destination pixels on one that shrinks, with `scale` the smaller
// of the two pixel sizes' ratios; `user_data` says which axis shrinks.
struct axes {
  int h_down, v_down;
};

static float point(float x, float scale, int down) {
  float d = down ? x / scale : x;
  // stb's x is the center minus the pixel, so [-1/2, 1/2) picks the pixel
  // floor(center + 1/2), the one under the center. A center is a multiple
  // of 1/2048 from a pixel at these sizes, so a margin of 1e-4 settles a
  // center on a pixel's edge as image.resize's integers do, whatever stb's
  // float rounding.
  return d >= -0.5f - 1e-4f && d < 0.5f - 1e-4f ? 1.0f : 0.0f;
}
static float point_h(float x, float scale, void *u) { return point(x, scale, ((struct axes *)u)->h_down); }
static float point_v(float x, float scale, void *u) { return point(x, scale, ((struct axes *)u)->v_down); }
static float point_support_h(float scale, void *u) { return ((struct axes *)u)->h_down ? scale : 1.0f; }
static float point_support_v(float scale, void *u) { return ((struct axes *)u)->v_down ? scale : 1.0f; }

static float sinc(float x) {
  if (x == 0.0f) return 1.0f;
  float px = 3.14159265358979323846f * x;
  return sinf(px) / px;
}
static float lanczos3(float x, float scale, void *u) {
  (void)scale, (void)u;
  return fabsf(x) < 3.0f ? sinc(x) * sinc(x / 3.0f) : 0.0f;
}
static float lanczos3_support(float scale, void *u) {
  (void)scale, (void)u;
  return 3.0f;
}

// image.resize's reflect (about the edge, the edge pixel repeated) and wrap.
// Zero has no index.
static uint32_t edge_index(long i, uint32_t n, int edge) {
  if (i >= 0 && i < (long)n) return (uint32_t)i;
  if (edge == EDGE_WRAP) return (uint32_t)(((i % (long)n) + n) % n);
  long p = ((i % (2 * (long)n)) + 2 * n) % (2 * n);
  return (uint32_t)(p < (long)n ? p : 2 * (long)n - 1 - p);
}

// How far past the edges a filter reaches, in source pixels, with room.
static uint32_t reach(int filter, uint32_t src, uint32_t dst) {
  double stretch = src > dst ? (double)src / dst : 1.0;
  double support = filter == FILTER_LANCZOS3 ? 3 : filter == FILTER_TRIANGLE ? 1 : 2;
  return (uint32_t)ceil(support * stretch) + 2;
}

static uint32_t gcd(uint32_t a, uint32_t b) {
  while (b) {
    uint32_t t = a % b;
    a = b;
    b = t;
  }
  return a;
}

// One axis: `h` rows of `in_w` pixels to `out_w`, by stb's horizontal pass,
// the rows kept as they are (point sampling at one row per row). Pixels
// are `in_bpp` and `out_bpp` bytes.
static int pass(const struct request *r, const uint8_t *in, uint32_t in_w, uint32_t h, size_t in_bpp,
                stbir_pixel_layout in_layout, stbir_datatype in_type, uint8_t *out, uint32_t out_w,
                size_t out_bpp, stbir_pixel_layout out_layout, stbir_datatype out_type) {
  // Every edge mode but clamp from padding, where nearest neighbor and box
  // read no pixel past an edge. The padding is a whole number of the
  // ratio's periods, `pad` source pixels to `crop` destination pixels, so
  // the padded image resized to the padded width puts every destination
  // pixel where it was, and the result is cropped.
  uint32_t pad = 0, crop = 0;
  const uint8_t *from = in;
  uint8_t *padded = NULL, *wide = out;
  if (r->edge != EDGE_CLAMP && r->filter != FILTER_POINT && r->filter != FILTER_BOX) {
    uint32_t g = gcd(in_w, out_w), k = (reach(r->filter, in_w, out_w) + in_w / g - 1) / (in_w / g);
    pad = k * (in_w / g);
    crop = k * (out_w / g);
    uint32_t pw = in_w + 2 * pad;
    padded = malloc((size_t)pw * h * in_bpp);
    for (uint32_t y = 0; y < h; y++) {
      for (uint32_t x = 0; x < pw; x++) {
        uint8_t *to = padded + ((size_t)y * pw + x) * in_bpp;
        if (r->edge == EDGE_ZERO && (x < pad || x >= pad + in_w)) {
          memset(to, 0, in_bpp);
        } else {
          uint32_t sx = edge_index((long)x - pad, in_w, r->edge);
          memcpy(to, in + ((size_t)y * in_w + sx) * in_bpp, in_bpp);
        }
      }
    }
    from = padded;
    wide = malloc((size_t)(out_w + 2 * crop) * h * out_bpp);
  }
  STBIR_RESIZE res;
  stbir_resize_init(&res, from, (int)(in_w + 2 * pad), (int)h, 0, wide, (int)(out_w + 2 * crop), (int)h, 0,
                    in_layout, in_type);
  stbir_set_pixel_layouts(&res, in_layout, out_layout);
  stbir_set_datatypes(&res, in_type, out_type);
  struct axes axes = {in_w > out_w, 0};
  stbir_set_user_data(&res, &axes);
  if (r->filter == FILTER_POINT) {
    stbir_set_filter_callbacks(&res, point_h, point_support_h, point_v, point_support_v);
  } else if (r->filter == FILTER_LANCZOS3) {
    stbir_set_filter_callbacks(&res, lanczos3, lanczos3_support, point_v, point_support_v);
  } else {
    static const stbir_filter filters[] = {
        [FILTER_DEFAULT] = STBIR_FILTER_DEFAULT,       [FILTER_BOX] = STBIR_FILTER_BOX,
        [FILTER_TRIANGLE] = STBIR_FILTER_TRIANGLE,     [FILTER_B_SPLINE] = STBIR_FILTER_CUBICBSPLINE,
        [FILTER_CATMULL_ROM] = STBIR_FILTER_CATMULLROM, [FILTER_MITCHELL] = STBIR_FILTER_MITCHELL,
    };
    stbir_set_filters(&res, filters[r->filter], STBIR_FILTER_POINT_SAMPLE);
  }
  stbir_set_edgemodes(&res, STBIR_EDGE_CLAMP, STBIR_EDGE_CLAMP);
  stbir_set_non_pm_alpha_speed_over_quality(&res, 1);
  int ok = stbir_resize_extended(&res);
  if (crop) {
    for (uint32_t y = 0; y < h; y++) {
      memcpy(out + (size_t)y * out_w * out_bpp, wide + ((size_t)y * (out_w + 2 * crop) + crop) * out_bpp,
             (size_t)out_w * out_bpp);
    }
    free(wide);
  }
  free(padded);
  return ok;
}

// `w` by `h` pixels of `bpp` bytes, transposed.
static void transpose(const uint8_t *in, uint8_t *out, uint32_t w, uint32_t h, size_t bpp) {
  for (uint32_t y = 0; y < h; y++) {
    for (uint32_t x = 0; x < w; x++) memcpy(out + ((size_t)x * h + y) * bpp, in + ((size_t)y * w + x) * bpp, bpp);
  }
}

static enum status resize_with(const uint8_t *in, size_t len, enum pixel_format format, uint64_t max_pixels,
                               struct image *out, int high_alpha) {
  struct request r;
  if (!parse(in, len, &r)) return STATUS_REJECTED;
  if ((uint64_t)r.dw * r.dh > max_pixels) return STATUS_TOO_LARGE;
  int layout = layout_of(format);
  enum sample s = sample_of(format);
  size_t channels = pixel_bytes(format) / sample_bytes(s);
  stbir_datatype type = s == S_U8 ? STBIR_TYPE_UINT8 : s == S_U16 ? STBIR_TYPE_UINT16 : STBIR_TYPE_FLOAT;
  // sRGB is for 8- and 16-bit color; stb has it for 8 bits only, and
  // image.resize filters CMYK inks as stored.
  int cmyk = format == PF_CMYK8 || format == PF_CMYK16;
  if (r.srgb && s == S_U16 && !cmyk) return STATUS_SKIPPED;
  if (r.srgb && s == S_U8 && !cmyk) type = STBIR_TYPE_UINT8_SRGB;
  // Between the passes: floats in the same layout, straight alpha
  // unpremultiplied after the first pass and premultiplied again in the
  // second, so the two passes filter premultiplied colors throughout. (A
  // premultiplied layout on one side and a straight one on the other is
  // not a conversion stb makes: it copies the colors either way.)
  int straight = layout == STBIR_RGBA || layout == STBIR_BGRA || layout == STBIR_RA;
  if (r.filter == FILTER_POINT) {
    layout = layout == STBIR_RGBA ? STBIR_RGBA_PM : layout == STBIR_BGRA ? STBIR_BGRA_PM
           : layout == STBIR_RA ? STBIR_RA_PM : layout;
  }
  int alpha = layout == STBIR_RA || layout == STBIR_RA_PM ? 1 : channels == 4 && !cmyk ? 3 : -1;

  size_t bpp = pixel_bytes(format), mid_bpp = channels * 4;
  uint8_t *src = malloc((size_t)r.sw * r.sh * bpp);
  make_source(&r, s, src, (size_t)r.sw * r.sh * channels, channels, high_alpha ? alpha : -1);
  uint8_t *mid = malloc((size_t)r.dw * r.sh * mid_bpp);
  uint8_t *turned = malloc((size_t)r.dw * r.sh * mid_bpp);
  uint8_t *done = malloc((size_t)r.dw * r.dh * bpp);
  out->len = (size_t)r.dw * r.dh * bpp;
  out->pixels = malloc(out->len);
  int ok = pass(&r, src, r.sw, r.sh, bpp, layout, type, mid, r.dw, mid_bpp, layout, STBIR_TYPE_FLOAT);
  if (ok) {
    transpose(mid, turned, r.dw, r.sh, mid_bpp);
    ok = pass(&r, turned, r.sh, r.dw, mid_bpp, layout, STBIR_TYPE_FLOAT, done, r.dh, bpp, layout, type);
  }
  if (ok) transpose(done, out->pixels, r.dh, r.dw, bpp);
  // Where alpha is written as 0, stb's division of a premultiplied color
  // by it leaves 0/0's NaN converted; image.resize writes transparent
  // black there.
  if (ok && straight && r.filter != FILTER_POINT) {
    int a = alpha;
    size_t sb = sample_bytes(s);
    for (size_t p = 0; p < (size_t)r.dw * r.dh; p++) {
      uint8_t *px = out->pixels + p * bpp;
      int zero = 1;
      for (size_t k = 0; k < sb; k++) zero &= s == S_F32 ? 1 : px[a * sb + k] == 0;
      if (s == S_F32) {
        float v;
        memcpy(&v, px + a * sb, 4);
        zero = !(v > 0);
      }
      if (zero) {
        for (size_t c = 0; c < channels; c++) {
          if ((int)c != a) memset(px + c * sb, 0, sb);
        }
      }
    }
  }
  free(src);
  free(mid);
  free(turned);
  free(done);
  if (!ok) {
    free(out->pixels);
    out->pixels = NULL;
    return STATUS_REJECTED;
  }
  out->width = r.dw;
  out->height = r.dh;
  return STATUS_OK;
}

static enum status resize_stbir2(const uint8_t *in, size_t len, enum pixel_format format,
                                 uint64_t max_pixels, struct image *out) {
  return resize_with(in, len, format, max_pixels, out, 0);
}

// Alpha from half to opaque, for straight alpha (test/oracle/resize.zig).
static enum status resize_stbir2_alpha(const uint8_t *in, size_t len, enum pixel_format format,
                                       uint64_t max_pixels, struct image *out) {
  return resize_with(in, len, format, max_pixels, out, 1);
}

const struct op resize_ops[] = {
    {"resize-stbir2", resize_stbir2},
    {"resize-stbir2-alpha", resize_stbir2_alpha},
    {0},
};

// image.resize's defaults against stb_image_resize 0.97's
// stbir_resize_uint8, the call rockorager/monstar makes on FreeType glyph
// bitmaps: 1-channel coverage (gray8) and 4-channel premultiplied BGRA
// (bgra8_premul), whatever the request's options (test/oracle/resize.zig).
// The header is the flake's pinned copy of stb's deprecated/
// stb_image_resize.h.
#include <stdlib.h>

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_STATIC
#include "stb_image_resize097/stb_image_resize.h"

#include "oracle.h"
#include "resize.h"

static enum status resize_stbir097(const uint8_t *in, size_t len, enum pixel_format format,
                                   uint64_t max_pixels, struct image *out) {
  int channels = format == PF_GRAY8 ? 1 : format == PF_BGRA8_PREMUL ? 4 : 0;
  if (!channels) return STATUS_SKIPPED;
  struct request r;
  if (!parse(in, len, &r)) return STATUS_REJECTED;
  if ((uint64_t)r.dw * r.dh > max_pixels) return STATUS_TOO_LARGE;
  uint8_t *src = malloc((size_t)r.sw * r.sh * channels);
  make_source(&r, S_U8, src, (size_t)r.sw * r.sh * channels, channels, -1);
  out->len = (size_t)r.dw * r.dh * channels;
  out->pixels = malloc(out->len);
  int ok = stbir_resize_uint8(src, (int)r.sw, (int)r.sh, 0, out->pixels, (int)r.dw, (int)r.dh, 0, channels);
  free(src);
  if (!ok) {
    free(out->pixels);
    out->pixels = NULL;
    return STATUS_REJECTED;
  }
  out->width = r.dw;
  out->height = r.dh;
  return STATUS_OK;
}

const struct op resize_stb097_ops[] = {
    {"resize-stbir097", resize_stbir097},
    {0},
};

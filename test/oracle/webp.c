// WebP's oracles: libwebp, the bar, and Wuffs, which reads lossless files.
// Each decodes the first frame into RGBA8, BGRA8, or RGB8.
#include <stdlib.h>
#include <string.h>
#include <webp/decode.h>

#include "wuffs-v0.4.c"

#include "oracle.h"

// libwebp's advanced API, its defaults kept, into a buffer of our own.
static enum status webp_libwebp(const uint8_t *in, size_t len, enum pixel_format format,
                                uint64_t max_pixels, struct image *out) {
  WEBP_CSP_MODE mode = format == PF_RGBA8   ? MODE_RGBA
                       : format == PF_BGRA8 ? MODE_BGRA
                       : format == PF_RGB8  ? MODE_RGB
                                            : MODE_LAST;
  if (mode == MODE_LAST) return STATUS_SKIPPED;
  WebPDecoderConfig config;
  if (!WebPInitDecoderConfig(&config)) return STATUS_REJECTED;
  if (WebPGetFeatures(in, len, &config.input) != VP8_STATUS_OK) return STATUS_REJECTED;
  uint64_t w = (uint64_t)config.input.width, h = (uint64_t)config.input.height;
  if (w * h > max_pixels) return STATUS_TOO_LARGE;
  size_t bpp = pixel_bytes(format);
  out->len = (size_t)(w * h * bpp);
  out->pixels = calloc(1, out->len ? out->len : 1);
  config.output.colorspace = mode;
  config.output.is_external_memory = 1;
  config.output.u.RGBA.rgba = out->pixels;
  config.output.u.RGBA.stride = (int)(w * bpp);
  config.output.u.RGBA.size = out->len;
  if (WebPDecode(in, len, &config) != VP8_STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
    return STATUS_REJECTED;
  }
  out->width = (uint32_t)w;
  out->height = (uint32_t)h;
  return STATUS_OK;
}

static enum status webp_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  return wuffs_decode(wuffs_webp__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

const struct op webp_ops[] = {
    {"webp-libwebp", webp_libwebp},
    {"webp-wuffs", webp_wuffs},
    {0},
};

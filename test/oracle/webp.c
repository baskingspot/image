// WebP's oracles: libwebp, the bar, and Wuffs, into RGBA8, BGRA8, or RGB8.
// libwebp plays an animation through its animation decoder and answers
// with the last canvas; Wuffs decodes no animations.
#include <stdlib.h>
#include <string.h>
#include <webp/decode.h>
#include <webp/demux.h>

#include "wuffs-v0.4.c"

#include "oracle.h"

// Whether `in` is an animation: its VP8X chunk sets the flag.
static int animated(const uint8_t *in, size_t len) {
  return len >= 21 && !memcmp(in, "RIFF", 4) && !memcmp(in + 12, "VP8X", 4) && (in[20] & 0x02);
}

// libwebp's animation decoder, which composites onto a transparent canvas
// and disposes to transparent, for the canvas after the last frame.
static enum status webp_anim(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  WebPData data = {in, len};
  enum status result = STATUS_REJECTED;
  WebPAnimDecoderOptions opts;
  WebPAnimDecoder *dec = NULL;
  WebPBitstreamFeatures features;
  if (WebPGetFeatures(in, len, &features) != VP8_STATUS_OK) goto done;
  uint64_t w = (uint64_t)features.width, h = (uint64_t)features.height;
  if (w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  if (!WebPAnimDecoderOptionsInit(&opts)) goto done;
  opts.color_mode = format == PF_BGRA8 ? MODE_BGRA : MODE_RGBA;
  dec = WebPAnimDecoderNew(&data, &opts);
  if (!dec) goto done;
  WebPAnimInfo info;
  uint8_t *canvas = NULL;
  int timestamp;
  if (!WebPAnimDecoderGetInfo(dec, &info)) goto done;
  while (WebPAnimDecoderHasMoreFrames(dec))
    if (!WebPAnimDecoderGetNext(dec, &canvas, &timestamp)) goto done;
  if (!canvas) goto done;
  w = info.canvas_width;
  h = info.canvas_height;
  size_t bpp = pixel_bytes(format);
  out->len = (size_t)(w * h * bpp);
  out->pixels = malloc(out->len ? out->len : 1);
  // RGB8 drops the alpha.
  for (size_t i = 0; i < w * h; i++) memcpy(out->pixels + i * bpp, canvas + i * 4, bpp);
  out->width = (uint32_t)w;
  out->height = (uint32_t)h;
  result = STATUS_OK;
done:
  WebPAnimDecoderDelete(dec);
  return result;
}

// libwebp's advanced API, its defaults kept, into a buffer of our own.
static enum status webp_libwebp(const uint8_t *in, size_t len, enum pixel_format format,
                                uint64_t max_pixels, struct image *out) {
  WEBP_CSP_MODE mode = format == PF_RGBA8   ? MODE_RGBA
                       : format == PF_BGRA8 ? MODE_BGRA
                       : format == PF_RGB8  ? MODE_RGB
                                            : MODE_LAST;
  if (mode == MODE_LAST) return STATUS_SKIPPED;
  if (animated(in, len)) return webp_anim(in, len, format, max_pixels, out);
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

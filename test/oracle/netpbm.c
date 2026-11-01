// Netpbm's oracles: Wuffs, the bar, which reads raw PGM and PPM with maxval
// 255 or 65535; stb_image, which reads raw PGM and PPM; and MagickWand,
// which reads every kind. An oracle that cannot read a file's kind at all
// skips it rather than rejecting it, so only the libraries that read a kind
// vote on it.
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

// Static, so another format's oracle can link its own copy.
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#include "stb/stb_image.h"
#pragma GCC diagnostic pop

#include "oracle.h"

// Whether the input is a raw PGM or PPM, the kinds Wuffs and stb read.
static int raw_pgm_ppm(const uint8_t *in, size_t len) {
  return len >= 2 && in[0] == 'P' && (in[1] == '5' || in[1] == '6');
}

static enum status netpbm_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                                uint64_t max_pixels, struct image *out) {
  if (!raw_pgm_ppm(in, len)) return STATUS_SKIPPED;
  // Wuffs reports maxvals other than 255 and 65535 as unsupported.
  wuffs_netpbm__decoder *probe = wuffs_netpbm__decoder__alloc();
  wuffs_base__image_config ic = {0};
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)in, len, true);
  wuffs_base__status st = wuffs_netpbm__decoder__decode_image_config(probe, &ic, &src);
  free(probe);
  if (st.repr == wuffs_netpbm__error__unsupported_netpbm_file) return STATUS_SKIPPED;
  return wuffs_decode(wuffs_netpbm__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// stb_image writes 1 to 4 channels, gray or RGB with or without alpha, at
// 8 or 16 bits.
static enum status netpbm_stb(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  if (!raw_pgm_ppm(in, len)) return STATUS_SKIPPED;
  int channels, wide = 0;
  switch (format) {
    case PF_GRAY8: channels = 1; break;
    case PF_GRAY_ALPHA8: channels = 2; break;
    case PF_RGB8: channels = 3; break;
    case PF_RGBA8: channels = 4; break;
    case PF_GRAY16: channels = 1, wide = 1; break;
    case PF_GRAY_ALPHA16: channels = 2, wide = 1; break;
    case PF_RGB16: channels = 3, wide = 1; break;
    case PF_RGBA16: channels = 4, wide = 1; break;
    default: return STATUS_SKIPPED;
  }
  int n = len > 0x7fffffff ? 0x7fffffff : (int)len;
  int w, h, comp;
  if (!stbi_info_from_memory(in, n, &w, &h, &comp)) return STATUS_REJECTED;
  if ((uint64_t)w * h > max_pixels) return STATUS_TOO_LARGE;
  void *px = wide ? (void *)stbi_load_16_from_memory(in, n, &w, &h, &comp, channels)
                  : (void *)stbi_load_from_memory(in, n, &w, &h, &comp, channels);
  if (!px) return STATUS_REJECTED;
  out->width = w;
  out->height = h;
  out->len = (size_t)w * h * channels * (wide ? 2 : 1);
  out->pixels = px;
  return STATUS_OK;
}

// MagickWand (magick.c): the first image only, through the `[0]` subimage
// spec, and any error (not warning) is a rejection.
static enum status netpbm_magick(const uint8_t *in, size_t len, enum pixel_format format,
                                 uint64_t max_pixels, struct image *out) {
  return magick_decode(&(struct magick){.filename = "netpbm[0]"}, in, len, format, max_pixels,
                       out);
}

const struct op netpbm_ops[] = {
    {"netpbm-wuffs", netpbm_wuffs},
    {"netpbm-stb", netpbm_stb},
    {"netpbm-magick", netpbm_magick},
    {0},
};

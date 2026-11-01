// Wuffs's implementation, compiled once, and the decode every Wuffs oracle
// shares.
#include <stdlib.h>

#define WUFFS_IMPLEMENTATION
#include "wuffs-v0.4.c"

#include "oracle.h"

static uint32_t wuffs_format(enum pixel_format f) {
  switch (f) {
    case PF_GRAY8: return WUFFS_BASE__PIXEL_FORMAT__Y;
    case PF_GRAY_ALPHA8: return WUFFS_BASE__PIXEL_FORMAT__YA_NONPREMUL;
    case PF_RGB8: return WUFFS_BASE__PIXEL_FORMAT__RGB;
    case PF_BGR8: return WUFFS_BASE__PIXEL_FORMAT__BGR;
    case PF_RGBA8: return WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL;
    case PF_RGBA8_PREMUL: return WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL;
    case PF_BGRA8: return WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL;
    case PF_BGRA8_PREMUL: return WUFFS_BASE__PIXEL_FORMAT__BGRA_PREMUL;
    case PF_GRAY16: return WUFFS_BASE__PIXEL_FORMAT__Y_16LE;
    case PF_RGBA16: return WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL_4X16LE;
    case PF_BGRA16: return WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL_4X16LE;
    default: return 0;
  }
}

enum status wuffs_decode(wuffs_base__image_decoder *dec, const uint8_t *in, size_t len,
                         enum pixel_format format, uint64_t max_pixels, struct image *out) {
  enum status result = STATUS_REJECTED;
  uint8_t *work = NULL;
  uint32_t pixfmt = wuffs_format(format);
  if (!pixfmt) {
    result = STATUS_SKIPPED;
    goto done;
  }
  wuffs_base__image_config ic = {0};
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)in, len, true);
  wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(dec, &ic, &src);
  if (!wuffs_base__status__is_ok(&st)) goto done;
  uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  wuffs_base__pixel_config__set(&ic.pixcfg, pixfmt, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
  out->len = (size_t)w * h * pixel_bytes(format);
  out->pixels = calloc(1, out->len ? out->len : 1);
  wuffs_base__pixel_buffer pb;
  st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg,
                                                wuffs_base__make_slice_u8(out->pixels, out->len));
  if (!wuffs_base__status__is_ok(&st)) goto done;
  uint64_t work_len = wuffs_base__image_decoder__workbuf_len(dec).max_incl;
  work = malloc(work_len ? work_len : 1);
  st = wuffs_base__image_decoder__decode_frame(dec, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC,
                                               wuffs_base__make_slice_u8(work, work_len), NULL);
  if (!wuffs_base__status__is_ok(&st)) goto done;
  out->width = w;
  out->height = h;
  result = STATUS_OK;
done:
  free(work);
  free(dec);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

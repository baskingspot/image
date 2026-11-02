// JPEG XL's oracle: libjxl, the reference decoder. It decodes the first
// displayed frame, coalesced, keeping the stored orientation and without
// rendering spot colors into the color channels, as this package does.
// It writes 16-bit or float RGBA in the machine's byte order; RGBA8 is
// its 16-bit output narrowed by the high byte, since libjxl dithers its
// own 8-bit output. Premultiplied requests are answered only for images
// whose alpha is premultiplied and straight requests only for the others,
// since libjxl leaves alpha as stored.
#include <jxl/decode.h>
#include <stdlib.h>
#include <string.h>

#include "oracle.h"

static enum status jxl_libjxl(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  JxlDataType type;
  int premul = 0, narrow = 0;
  switch (format) {
    case PF_RGBA8:
      type = JXL_TYPE_UINT16;
      narrow = 1;
      break;
    case PF_RGBA16:
      type = JXL_TYPE_UINT16;
      break;
    case PF_RGBA16_PREMUL:
      type = JXL_TYPE_UINT16;
      premul = 1;
      break;
    case PF_RGBA_F32:
      type = JXL_TYPE_FLOAT;
      break;
    case PF_RGBA_F32_PREMUL:
      type = JXL_TYPE_FLOAT;
      premul = 1;
      break;
    default:
      return STATUS_SKIPPED;
  }
  enum status result = STATUS_REJECTED;
  uint8_t *buf = NULL;
  size_t buf_len = 0;
  JxlDecoder *dec = JxlDecoderCreate(NULL);
  JxlBasicInfo info;
  JxlPixelFormat pf = {4, type, JXL_NATIVE_ENDIAN, 0};
  if (!dec) return STATUS_REJECTED;
  if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS)
    goto done;
  JxlDecoderSetKeepOrientation(dec, JXL_TRUE);
  JxlDecoderSetRenderSpotcolors(dec, JXL_FALSE);
  if (JxlDecoderSetInput(dec, in, len) != JXL_DEC_SUCCESS) goto done;
  JxlDecoderCloseInput(dec);
  for (;;) {
    JxlDecoderStatus s = JxlDecoderProcessInput(dec);
    if (s == JXL_DEC_BASIC_INFO) {
      if (JxlDecoderGetBasicInfo(dec, &info) != JXL_DEC_SUCCESS) goto done;
      if ((uint64_t)info.xsize * info.ysize > max_pixels) {
        result = STATUS_TOO_LARGE;
        goto done;
      }
      if (info.alpha_bits && !info.alpha_premultiplied != !premul) {
        result = STATUS_SKIPPED;
        goto done;
      }
    } else if (s == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      if (JxlDecoderImageOutBufferSize(dec, &pf, &buf_len) != JXL_DEC_SUCCESS) goto done;
      buf = malloc(buf_len ? buf_len : 1);
      if (JxlDecoderSetImageOutBuffer(dec, &pf, buf, buf_len) != JXL_DEC_SUCCESS) goto done;
    } else if (s == JXL_DEC_FULL_IMAGE) {
      break;
    } else {
      goto done;
    }
  }
  out->width = info.xsize;
  out->height = info.ysize;
  if (narrow) {
    size_t n = buf_len / 2;
    uint8_t *px = malloc(n ? n : 1);
    const uint16_t *src = (const uint16_t *)buf;
    for (size_t i = 0; i < n; i++) px[i] = (uint8_t)(src[i] >> 8);
    free(buf);
    buf = px;
    buf_len = n;
  }
  out->pixels = buf;
  out->len = buf_len;
  buf = NULL;
  result = STATUS_OK;
done:
  free(buf);
  JxlDecoderDestroy(dec);
  return result;
}

const struct op jxl_ops[] = {
    {"jxl-libjxl", jxl_libjxl},
    {0},
};

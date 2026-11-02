// JPEG XL's JPEG reconstruction oracle: libjxl, the reference decoder,
// which rebuilds the original JPEG from the jbrd box and the codestream
// (djxl's path to a .jpg). The protocol carries pixels, so the JPEG's
// bytes go as a gray8 image one row high and as wide as the file
// (test/oracle/jxl_jbrd.zig does the same on this package's side).
#include <jxl/decode.h>
#include <stdlib.h>
#include <string.h>

#include "oracle.h"

static enum status jxl_jbrd_libjxl(const uint8_t *in, size_t len, enum pixel_format format,
                                   uint64_t max_pixels, struct image *out) {
  if (format != PF_GRAY8) return STATUS_SKIPPED;
  enum status result = STATUS_REJECTED;
  size_t cap = 1 << 16, used = 0;
  uint8_t *buf = malloc(cap);
  int have_jpeg = 0;
  JxlDecoder *dec = JxlDecoderCreate(NULL);
  if (!dec || !buf) goto done;
  if (JxlDecoderSubscribeEvents(dec, JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) !=
      JXL_DEC_SUCCESS)
    goto done;
  if (JxlDecoderSetInput(dec, in, len) != JXL_DEC_SUCCESS) goto done;
  JxlDecoderCloseInput(dec);
  for (;;) {
    JxlDecoderStatus s = JxlDecoderProcessInput(dec);
    if (s == JXL_DEC_JPEG_RECONSTRUCTION) {
      have_jpeg = 1;
      if (JxlDecoderSetJPEGBuffer(dec, buf, cap) != JXL_DEC_SUCCESS) goto done;
    } else if (s == JXL_DEC_JPEG_NEED_MORE_OUTPUT) {
      used = cap - JxlDecoderReleaseJPEGBuffer(dec);
      if (cap > max_pixels) {
        result = STATUS_TOO_LARGE;
        goto done;
      }
      uint8_t *grown = realloc(buf, cap * 2);
      if (!grown) goto done;
      buf = grown;
      cap *= 2;
      if (JxlDecoderSetJPEGBuffer(dec, buf + used, cap - used) != JXL_DEC_SUCCESS) goto done;
    } else if (s == JXL_DEC_FULL_IMAGE) {
      // The first frame ends the JPEG; a file without a jbrd box has none.
      if (!have_jpeg) goto done;
      used = cap - JxlDecoderReleaseJPEGBuffer(dec);
      break;
    } else {
      // An error, a need for a pixel buffer (no jbrd box), or the end
      // before a frame.
      goto done;
    }
  }
  if (used > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  out->width = (uint32_t)used;
  out->height = 1;
  out->pixels = buf;
  out->len = used;
  buf = NULL;
  result = STATUS_OK;
done:
  free(buf);
  if (dec) JxlDecoderDestroy(dec);
  return result;
}

const struct op jxl_jbrd_ops[] = {
    {"jxl_jbrd-libjxl", jxl_jbrd_libjxl, NULL},
    {NULL, NULL, NULL},
};

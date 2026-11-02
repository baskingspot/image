// libjxl, one thread (no parallel runner), rebuilding the JPEG a file was
// transcoded from, as djxl does for a .jpg output: the jbrd box and the
// codestream's coefficients into the caller's buffer, with no pixels. A
// decoder is made per call.
#include <jxl/decode.h>

#include "arm.h"

static size_t jbrd(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  JxlDecoder *dec = JxlDecoderCreate(NULL);
  size_t result = 0;
  if (!dec) return 0;
  if (JxlDecoderSubscribeEvents(dec, JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE) !=
      JXL_DEC_SUCCESS)
    goto done;
  if (JxlDecoderSetInput(dec, in, len) != JXL_DEC_SUCCESS) goto done;
  JxlDecoderCloseInput(dec);
  int have_jpeg = 0;
  for (;;) {
    JxlDecoderStatus s = JxlDecoderProcessInput(dec);
    if (s == JXL_DEC_JPEG_RECONSTRUCTION) {
      have_jpeg = 1;
      if (JxlDecoderSetJPEGBuffer(dec, out, cap) != JXL_DEC_SUCCESS) goto done;
    } else if (s == JXL_DEC_FULL_IMAGE && have_jpeg) {
      result = cap - JxlDecoderReleaseJPEGBuffer(dec);
      goto done;
    } else {
      // An error, a pixel buffer request (no jbrd box), or output past
      // `cap` (JXL_DEC_JPEG_NEED_MORE_OUTPUT).
      goto done;
    }
  }
done:
  JxlDecoderDestroy(dec);
  return result;
}

static size_t jbrd_progressive(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return jbrd(in, len, out, cap);
}

BENCH_OP("jxl-jbrd", jbrd)
BENCH_OP("jxl-jbrd-progressive", jbrd_progressive)

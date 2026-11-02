// libjxl, one thread (no parallel runner), decoding the first frame to
// RGBA16 as its decode API returns it: coalesced, oriented as stored. A
// decoder is made per call; its output is the caller's buffer.
#include <jxl/decode.h>

#include "arm.h"

static size_t decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  JxlDecoder *dec = JxlDecoderCreate(NULL);
  size_t result = 0;
  if (!dec) return 0;
  JxlPixelFormat pf = {4, JXL_TYPE_UINT16, JXL_NATIVE_ENDIAN, 0};
  if (JxlDecoderSubscribeEvents(dec, JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) goto done;
  JxlDecoderSetKeepOrientation(dec, JXL_TRUE);
  JxlDecoderSetRenderSpotcolors(dec, JXL_FALSE);
  if (JxlDecoderSetInput(dec, in, len) != JXL_DEC_SUCCESS) goto done;
  JxlDecoderCloseInput(dec);
  size_t need = 0;
  for (;;) {
    JxlDecoderStatus s = JxlDecoderProcessInput(dec);
    if (s == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      if (JxlDecoderImageOutBufferSize(dec, &pf, &need) != JXL_DEC_SUCCESS || need > cap) goto done;
      if (JxlDecoderSetImageOutBuffer(dec, &pf, out, need) != JXL_DEC_SUCCESS) goto done;
    } else if (s == JXL_DEC_FULL_IMAGE) {
      result = need;
      goto done;
    } else {
      goto done;
    }
  }
done:
  JxlDecoderDestroy(dec);
  return result;
}

// BENCH_OP names its registration after the function, so each operation
// has its own.
static size_t decode_lossless(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode(in, len, out, cap);
}

BENCH_OP("jxl-decode", decode)
BENCH_OP("jxl-decode-lossless", decode_lossless)

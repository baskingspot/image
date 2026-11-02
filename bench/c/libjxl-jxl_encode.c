// libjxl's encoder, lossless (`cjxl -d 0`) at efforts 1 to 9, one thread
// (no parallel runner), writing a bare codestream into the output buffer
// from raw 8-bit RGB or RGBA pixels (their bytes per pixel tell which),
// tagged sRGB as this package's encoder tags them. An encoder is made per
// call.
#include <jxl/encode.h>

#include "arm.h"

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int effort) {
  size_t px = (size_t)bench_width * bench_height;
  if (px == 0 || len % px != 0) return 0;
  size_t channels = len / px;
  if (channels != 3 && channels != 4) return 0;
  JxlEncoder *enc = JxlEncoderCreate(NULL);
  if (!enc) return 0;
  size_t result = 0;
  if (JxlEncoderUseContainer(enc, JXL_FALSE) != JXL_ENC_SUCCESS) goto done;
  JxlBasicInfo info;
  JxlEncoderInitBasicInfo(&info);
  info.xsize = bench_width;
  info.ysize = bench_height;
  info.bits_per_sample = 8;
  info.num_color_channels = 3;
  info.uses_original_profile = JXL_TRUE;
  if (channels == 4) {
    info.num_extra_channels = 1;
    info.alpha_bits = 8;
  }
  if (JxlEncoderSetBasicInfo(enc, &info) != JXL_ENC_SUCCESS) goto done;
  JxlColorEncoding color;
  JxlColorEncodingSetToSRGB(&color, JXL_FALSE);
  if (JxlEncoderSetColorEncoding(enc, &color) != JXL_ENC_SUCCESS) goto done;
  JxlEncoderFrameSettings *settings = JxlEncoderFrameSettingsCreate(enc, NULL);
  if (JxlEncoderSetFrameLossless(settings, JXL_TRUE) != JXL_ENC_SUCCESS) goto done;
  if (JxlEncoderFrameSettingsSetOption(settings, JXL_ENC_FRAME_SETTING_EFFORT, effort) != JXL_ENC_SUCCESS)
    goto done;
  JxlPixelFormat pf = {(uint32_t)channels, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  if (JxlEncoderAddImageFrame(settings, &pf, in, len) != JXL_ENC_SUCCESS) goto done;
  JxlEncoderCloseInput(enc);
  uint8_t *next = out;
  size_t avail = cap;
  JxlEncoderStatus s;
  while ((s = JxlEncoderProcessOutput(enc, &next, &avail)) == JXL_ENC_NEED_MORE_OUTPUT) {
    if (avail == 0) goto done;
  }
  if (s == JXL_ENC_SUCCESS) result = cap - avail;
done:
  JxlEncoderDestroy(enc);
  return result;
}

// BENCH_OP names its registration after the function, so each effort has
// its own.
#define EFFORT(n)                                                                \
  static size_t encode_e##n(const uint8_t *in, size_t len, uint8_t *out, size_t cap) { \
    return encode(in, len, out, cap, n);                                         \
  }                                                                              \
  BENCH_OP("jxl-encode-e" #n, encode_e##n)

EFFORT(1)
EFFORT(2)
EFFORT(3)
EFFORT(4)
EFFORT(5)
EFFORT(6)
EFFORT(7)
EFFORT(8)
EFFORT(9)

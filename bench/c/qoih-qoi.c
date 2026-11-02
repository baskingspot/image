// qoi.h, the reference QOI codec. Its API allocates the pixels or the
// file, so a call is qoi_decode or qoi_encode and free; only `check`
// copies the result out.
#include <stdlib.h>
#include <string.h>

#define QOI_IMPLEMENTATION
#define QOI_NO_STDIO
#include "qoi.h"

#include "arm.h"

static size_t qoi_decode_native(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  qoi_desc desc;
  void *px = qoi_decode(in, (int)len, &desc, 0);
  if (!px) return 0;
  size_t n = (size_t)desc.width * desc.height * desc.channels;
  if (bench_checking && n <= cap) memcpy(out, px, n);
  free(px);
  return n <= cap ? n : 0;
}

// Raw RGB or RGBA pixels (bench/corpus/qoi_encode.sh).
static size_t qoi_encode_raw(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  size_t pixels = (size_t)bench_width * bench_height;
  if (!pixels || len % pixels) return 0;
  qoi_desc desc = {bench_width, bench_height, (unsigned char)(len / pixels), QOI_SRGB};
  int n = 0;
  void *file = qoi_encode(in, &desc, &n);
  if (!file) return 0;
  if (bench_checking && (size_t)n <= cap) memcpy(out, file, n);
  free(file);
  return (size_t)n <= cap ? (size_t)n : 0;
}

BENCH_OP("qoi-decode", qoi_decode_native)
BENCH_OP("qoi-encode", qoi_encode_raw)

// qoi.h, the reference QOI decoder. Its API allocates the pixels, so a
// call is qoi_decode and free; only `check` copies them out.
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

BENCH_OP("qoi-decode", qoi_decode_native)

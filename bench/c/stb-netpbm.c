// stb_image's Netpbm decoder, which reads raw PGM and PPM: to gray, RGB,
// and RGBA. Not 16-bit PPM, whose samples it leaves big endian. Its API
// allocates the pixels, so a call is a load and a free; only `check` copies
// them out.
#include <string.h>

#include "stb/stb_image.h"

#include "arm.h"

static size_t load(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int channels) {
  int w, h, n;
  stbi_uc *px = stbi_load_from_memory(in, (int)len, &w, &h, &n, channels);
  if (!px) return 0;
  size_t size = (size_t)w * h * channels;
  if (bench_checking && size <= cap) memcpy(out, px, size);
  stbi_image_free(px);
  return size <= cap ? size : 0;
}

static size_t ppm(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return load(in, len, out, cap, 3);
}
static size_t ppm_rgba(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return load(in, len, out, cap, 4);
}
static size_t pgm(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return load(in, len, out, cap, 1);
}

BENCH_OP("netpbm-decode-ppm", ppm)
BENCH_OP("netpbm-decode-ppm-rgba", ppm_rgba)
BENCH_OP("netpbm-decode-pgm", pgm)

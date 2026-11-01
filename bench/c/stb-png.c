// stb_image's PNG decoder, to RGBA8. Its API allocates the pixels, so a
// call is stbi_load_from_memory and free; only `check` copies them out.
#include <stdlib.h>
#include <string.h>

#include "stb/stb_image.h"

#include "arm.h"

static size_t png_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  int w, h, n;
  stbi_uc *px = stbi_load_from_memory(in, (int)len, &w, &h, &n, 4);
  if (!px) return 0;
  size_t size = (size_t)w * h * 4;
  if (bench_checking && size <= cap) memcpy(out, px, size);
  stbi_image_free(px);
  return size <= cap ? size : 0;
}

BENCH_OP("png-decode", png_decode)

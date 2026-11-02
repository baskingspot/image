// stb_image's GIF decoder, to RGBA8. `gif-decode` is stbi_load_from_memory,
// the first frame; `gif-decode-anim` is stbi_load_gif_from_memory, which
// composites every frame into a canvas of its own and returns them all, and
// the answer is the last. Its API allocates the pixels, so a call is a load
// and a free; only `check` copies them out. stbi_load_gif_from_memory reads
// out of bounds and crashes on a frame that restores to previous
// (sprite-1600x900.gif), so the arm fails those files without calling it,
// and the harness skips them; on the other animations it agrees with the
// other arms.
#include <stdlib.h>
#include <string.h>

#include "stb/stb_image.h"

#include "arm.h"

static size_t gif_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  int w, h, n;
  stbi_uc *px = stbi_load_from_memory(in, (int)len, &w, &h, &n, 4);
  if (!px) return 0;
  size_t size = (size_t)w * h * 4;
  if (bench_checking && size <= cap) memcpy(out, px, size);
  stbi_image_free(px);
  return size <= cap ? size : 0;
}

// The end of the sub-blocks starting at p[i], past their terminator.
static size_t skip_blocks(const uint8_t *p, size_t n, size_t i) {
  while (i < n && p[i]) i += (size_t)p[i] + 1;
  return i + 1;
}

// Whether a graphic control extension in the file says restore to previous.
static int restores_previous(const uint8_t *p, size_t n) {
  if (n < 13) return 0;
  size_t i = 13;
  if (p[10] & 0x80) i += (size_t)3 << ((p[10] & 7) + 1);
  while (i < n) {
    uint8_t b = p[i++];
    if (b == 0x21) {
      if (i + 2 < n && p[i] == 0xf9 && p[i + 1] == 4 && (p[i + 2] >> 2 & 7) == 3) return 1;
      i = skip_blocks(p, n, i + 1);
    } else if (b == 0x2c) {
      if (i + 9 > n) return 0;
      uint8_t flags = p[i + 8];
      i += 9;
      if (flags & 0x80) i += (size_t)3 << ((flags & 7) + 1);
      i = skip_blocks(p, n, i + 1);
    } else {
      return 0;
    }
  }
  return 0;
}

static size_t gif_decode_anim(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (restores_previous(in, len)) return 0;
  int *delays = NULL;
  int w, h, frames, n;
  stbi_uc *px = stbi_load_gif_from_memory(in, (int)len, &delays, &w, &h, &frames, &n, 4);
  if (!px) return 0;
  size_t size = (size_t)w * h * 4;
  if (bench_checking && size <= cap) memcpy(out, px + (size_t)(frames - 1) * size, size);
  stbi_image_free(px);
  stbi_image_free(delays);
  return size <= cap ? size : 0;
}

BENCH_OP("gif-decode", gif_decode)
BENCH_OP("gif-decode-anim", gif_decode_anim)

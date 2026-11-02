// BMP's oracles: Wuffs, the bar; stb_image; and ImageMagick through
// MagickWand (magick.c).
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

// Static, so another format's file can compile stb_image too.
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_ONLY_BMP
// Static leaves the parts STBI_ONLY_BMP drops declared and unused.
#pragma GCC diagnostic ignored "-Wunused-function"
#include "stb/stb_image.h"

#include "oracle.h"

static enum status bmp_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  return wuffs_decode(wuffs_bmp__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// Whether stb_image, decoding `in`, reads a palette entry it never set.
// Its palette is an uninitialized array on its stack: it sets as many
// entries as the pixel offset leaves room for (not biClrUsed; none when
// that count is negative) and indexes it with every pixel unchecked, so an
// index past them reads whatever the stack held, which differs from run to
// run (valgrind: "uninitialised value was created by a stack allocation"
// in stbi__bmp_load). This replays stbi__bmp_load's palette and pixel
// reads with its own header parser and readers.
static int stb_reads_unset_palette(const uint8_t *in, int len) {
  stbi__context s;
  stbi__bmp_data info;
  stbi__start_mem(&s, in, len);
  info.all_a = 255;
  if (!stbi__bmp_parse_header(&s, &info) || info.bpp >= 16) return 0;
  int entry = info.hsz == 12 ? 3 : 4;
  int psize = info.hsz == 12 ? (info.offset - info.extra_read - 24) / 3
                             : (info.offset - info.extra_read - info.hsz) >> 2;
  if (info.bpp != 1 && info.bpp != 4 && info.bpp != 8) return 0;
  if (psize >= 1 << info.bpp) return 0;
  for (int i = 0; i < psize * entry; i++) stbi__get8(&s);
  stbi__skip(&s, info.offset - info.extra_read - info.hsz - psize * entry);
  int w = (int)s.img_x, h = abs((int)s.img_y);
  int width = info.bpp == 1 ? (w + 7) >> 3 : info.bpp == 4 ? (w + 1) >> 1 : w;
  for (int j = 0; j < h; j++) {
    if (info.bpp == 1) {
      for (int i = 0, bit = 7, v = stbi__get8(&s); i < w; i++) {
        if (((v >> bit) & 1) >= psize) return 1;
        if (i + 1 == w) break;
        if (--bit < 0) {
          bit = 7;
          v = stbi__get8(&s);
        }
      }
    } else {
      for (int i = 0; i < w; i += 2) {
        int v = stbi__get8(&s), v2 = 0;
        if (info.bpp == 4) {
          v2 = v & 15;
          v >>= 4;
        }
        if (v >= psize) return 1;
        if (i + 1 == w) break;
        v = info.bpp == 8 ? stbi__get8(&s) : v2;
        if (v >= psize) return 1;
      }
    }
    stbi__skip(&s, -width & 3);
  }
  return 0;
}

// stb_image writes RGBA; BGRA is a swap away. It gives no answer for an
// input whose pixels depend on its unset palette entries.
static enum status bmp_stb(const uint8_t *in, size_t len, enum pixel_format format,
                           uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8 && format != PF_BGRA8) return STATUS_SKIPPED;
  int w, h, comp;
  if (len > 0x7fffffff) return STATUS_REJECTED;
  if (!stbi_info_from_memory(in, (int)len, &w, &h, &comp)) return STATUS_REJECTED;
  if ((uint64_t)w * (uint64_t)h > max_pixels) return STATUS_TOO_LARGE;
  uint8_t *px = stbi_load_from_memory(in, (int)len, &w, &h, &comp, 4);
  if (!px) return STATUS_REJECTED;
  if (stb_reads_unset_palette(in, (int)len)) {
    stbi_image_free(px);
    return STATUS_SKIPPED;
  }
  size_t n = (size_t)w * h;
  if (format == PF_BGRA8) {
    for (size_t i = 0; i < n; i++) {
      uint8_t t = px[4 * i];
      px[4 * i] = px[4 * i + 2];
      px[4 * i + 2] = t;
    }
  }
  out->width = w;
  out->height = h;
  out->len = n * 4;
  out->pixels = px;
  return STATUS_OK;
}

// MagickWand, warnings included: it reports truncated and malformed BMPs
// as warnings and decodes what it can.
static enum status bmp_magick(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  return magick_decode(&(struct magick){.format = "BMP", .reject_warnings = 1}, in, len, format,
                       max_pixels, out);
}

const struct op bmp_ops[] = {
    {"bmp-wuffs", bmp_wuffs},
    {"bmp-stb", bmp_stb},
    {"bmp-magick", bmp_magick},
    {0},
};

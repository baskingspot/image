// QOI's oracles: Wuffs, the bar, and qoi.h, the reference decoder; and
// qoi.h's encoder for the QOI encoder (test/oracle/qoi_encode.zig).
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

#define QOI_IMPLEMENTATION
#define QOI_NO_STDIO
#include "qoi.h"

#include "oracle.h"

static enum status qoi_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  return wuffs_decode(wuffs_qoi__decoder__alloc_as__wuffs_base__image_decoder(), in, len, format,
                      max_pixels, out);
}

// qoi.h writes three or four channels.
static enum status qoi_reference(const uint8_t *in, size_t len, enum pixel_format format,
                                 uint64_t max_pixels, struct image *out) {
  int channels = format == PF_RGB8 ? 3 : format == PF_RGBA8 ? 4 : 0;
  if (!channels) return STATUS_SKIPPED;
  if (len >= 12) {
    uint64_t w = (uint64_t)in[4] << 24 | in[5] << 16 | in[6] << 8 | in[7];
    uint64_t h = (uint64_t)in[8] << 24 | in[9] << 16 | in[10] << 8 | in[11];
    if (w * h > max_pixels) return STATUS_TOO_LARGE;
  }
  qoi_desc desc;
  void *px = qoi_decode(in, (int)(len > 0x7fffffff ? 0x7fffffff : len), &desc, channels);
  if (!px) return STATUS_REJECTED;
  out->width = desc.width;
  out->height = desc.height;
  out->len = (size_t)desc.width * desc.height * channels;
  out->pixels = px;
  return STATUS_OK;
}

// qoi.h's encoder on qoi.h's decode of the input: the file, as a one-row
// gray image whose width is its length (test/oracle/qoi_encode.zig).
static enum status qoi_reencode(const uint8_t *in, size_t len, enum pixel_format format,
                                uint64_t max_pixels, struct image *out) {
  if (format != PF_GRAY8) return STATUS_SKIPPED;
  if (len >= 12) {
    uint64_t w = (uint64_t)in[4] << 24 | in[5] << 16 | in[6] << 8 | in[7];
    uint64_t h = (uint64_t)in[8] << 24 | in[9] << 16 | in[10] << 8 | in[11];
    if (w * h > max_pixels) return STATUS_TOO_LARGE;
  }
  qoi_desc desc;
  void *px = qoi_decode(in, (int)(len > 0x7fffffff ? 0x7fffffff : len), &desc, 0);
  if (!px) return STATUS_REJECTED;
  int n = 0;
  out->pixels = qoi_encode(px, &desc, &n);
  free(px);
  if (!out->pixels) return STATUS_REJECTED;
  out->width = (uint32_t)n;
  out->height = 1;
  out->len = (size_t)n;
  return STATUS_OK;
}

const struct op qoi_ops[] = {
    {"qoi-wuffs", qoi_wuffs},
    {"qoi-qoih", qoi_reference},
    {0},
};

const struct op qoi_encode_ops[] = {
    {"qoi-qoih-encode", qoi_reencode},
    {0},
};

// The resize rows' destination sizes, as bench/zig/resize.zig computes
// them, for the C arms.
#ifndef RESIZE_SIZES_H
#define RESIZE_SIZES_H

#include <stdint.h>

enum resize_size { RESIZE_QUARTER, RESIZE_HALF, RESIZE_DOUBLE, RESIZE_THUMB256, RESIZE_THUMB1024 };

// Within n by n, the aspect ratio kept, rounded.
static inline void resize_fit(uint32_t w, uint32_t h, uint64_t n, uint32_t *dw, uint32_t *dh) {
  if (w >= h) {
    uint64_t v = (2 * h * n + w) / (2 * (uint64_t)w);
    *dw = (uint32_t)n;
    *dh = v ? (uint32_t)v : 1;
  } else {
    uint64_t v = (2 * w * n + h) / (2 * (uint64_t)h);
    *dw = v ? (uint32_t)v : 1;
    *dh = (uint32_t)n;
  }
}

static inline void resize_size_of(enum resize_size s, uint32_t w, uint32_t h, uint32_t *dw, uint32_t *dh) {
  switch (s) {
    case RESIZE_QUARTER: *dw = (w + 2) / 4; *dh = (h + 2) / 4; break;
    case RESIZE_HALF: *dw = (w + 1) / 2; *dh = (h + 1) / 2; break;
    case RESIZE_DOUBLE: *dw = 2 * w; *dh = 2 * h; break;
    case RESIZE_THUMB256: resize_fit(w, h, 256, dw, dh); break;
    case RESIZE_THUMB1024: resize_fit(w, h, 1024, dw, dh); break;
  }
  if (!*dw) *dw = 1;
  if (!*dh) *dh = 1;
}

#endif

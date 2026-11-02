// Wuffs's GIF decoder, to RGBA8. The decoder lives in static memory and is
// initialized per call, as a caller that reuses it would. `gif-decode`
// writes the first frame; `gif-decode-anim` plays every frame into the
// canvas, applying each frame's disposal before the next (Wuffs leaves
// disposal, and the canvas outside the first frame, to its caller).
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

#include "arm.h"
#include "wuffs-arm.h"

static wuffs_gif__decoder *dec;

static int init(void) {
  if (!dec) dec = malloc(sizeof__wuffs_gif__decoder());
  wuffs_base__status st =
      wuffs_gif__decoder__initialize(dec, sizeof__wuffs_gif__decoder(), WUFFS_VERSION,
                                     WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
  return wuffs_base__status__is_ok(&st);
}

static size_t gif_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (!init()) return 0;
  return wuffs_arm_decode(wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(dec), in, len,
                          out, cap, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL);
}

// The region under a frame whose disposal is restore-previous, kept
// between calls.
static uint8_t *saved;
static size_t saved_cap;

static size_t gif_decode_anim(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  if (!init()) return 0;
  wuffs_base__image_decoder *d = wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(dec);
  wuffs_base__image_config ic = {0};
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)in, len, true);
  wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(d, &ic, &src);
  if (!wuffs_base__status__is_ok(&st)) return 0;
  uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
  wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
  size_t n = (size_t)w * h * 4;
  if (n > cap) return 0;
  wuffs_base__pixel_buffer pb;
  st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg, wuffs_base__make_slice_u8(out, n));
  if (!wuffs_base__status__is_ok(&st)) return 0;
  wuffs_base__rect_ie_u32 prev = {0};
  int disposal = 0;
  for (int i = 0;; i++) {
    wuffs_base__frame_config fc = {0};
    st = wuffs_base__image_decoder__decode_frame_config(d, &fc, &src);
    if (st.repr == wuffs_base__note__end_of_data) break;
    if (!wuffs_base__status__is_ok(&st)) return 0;
    wuffs_base__rect_ie_u32 r = wuffs_base__frame_config__bounds(&fc);
    if (i == 0 && (r.min_incl_x || r.min_incl_y || r.max_excl_x != w || r.max_excl_y != h)) memset(out, 0, n);
    size_t row = (size_t)(prev.max_excl_x - prev.min_incl_x) * 4;
    for (uint32_t y = prev.min_incl_y; y < prev.max_excl_y; y++) {
      uint8_t *p = out + ((size_t)y * w + prev.min_incl_x) * 4;
      if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_BACKGROUND) memset(p, 0, row);
      if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) {
        memcpy(p, saved + (y - prev.min_incl_y) * row, row);
      }
    }
    prev = r;
    disposal = wuffs_base__frame_config__disposal(&fc);
    if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) {
      row = (size_t)(r.max_excl_x - r.min_incl_x) * 4;
      size_t need = row * (r.max_excl_y - r.min_incl_y);
      if (need > saved_cap) {
        free(saved);
        saved = malloc(need);
        saved_cap = need;
      }
      for (uint32_t y = r.min_incl_y; y < r.max_excl_y; y++) {
        memcpy(saved + (y - r.min_incl_y) * row, out + ((size_t)y * w + r.min_incl_x) * 4, row);
      }
    }
    // The first frame replaces the canvas: its transparent pixels become
    // transparent black.
    wuffs_base__pixel_blend blend = i == 0 || wuffs_base__frame_config__overwrite_instead_of_blend(&fc)
                                        ? WUFFS_BASE__PIXEL_BLEND__SRC
                                        : WUFFS_BASE__PIXEL_BLEND__SRC_OVER;
    st = wuffs_base__image_decoder__decode_frame(d, &pb, &src, blend, wuffs_base__empty_slice_u8(), NULL);
    if (!wuffs_base__status__is_ok(&st)) return 0;
  }
  return n;
}

BENCH_OP("gif-decode", gif_decode)
BENCH_OP("gif-decode-anim", gif_decode_anim)

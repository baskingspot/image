// GIF's oracles: Wuffs, the bar, and giflib. Each decodes every frame and
// composites the animation as a player does, into RGBA8 or BGRA8: the canvas
// starts transparent black, a frame's transparent pixels leave the canvas
// as it is, and a frame's disposal is applied before the next frame
// (restore to background clears its region to transparent black, restore to
// previous puts back what was there before it). The answer is the canvas
// after the last frame, and a failure in any frame rejects the file, so
// every frame's pixels and every frame's errors count.
// test/oracle/gif.zig composites this package's frames the same way.
#include <gif_lib.h>
#include <stdlib.h>
#include <string.h>

#include "wuffs-v0.4.c"

#include "oracle.h"

struct rect {
  uint32_t x0, y0, x1, y1;
};

// The intersection of a frame's region with a w by h canvas.
static struct rect clip(uint64_t x, uint64_t y, uint64_t fw, uint64_t fh, uint32_t w, uint32_t h) {
  struct rect r = {0};
  r.x0 = x < w ? (uint32_t)x : w;
  r.y0 = y < h ? (uint32_t)y : h;
  r.x1 = x + fw < w ? (uint32_t)(x + fw) : w;
  r.y1 = y + fh < h ? (uint32_t)(y + fh) : h;
  return r;
}

static void fill(uint8_t *px, uint32_t w, struct rect r) {
  for (uint32_t y = r.y0; y < r.y1; y++) memset(px + ((size_t)y * w + r.x0) * 4, 0, (size_t)(r.x1 - r.x0) * 4);
}

// Copies the region r of a canvas w pixels wide between `canvas` and
// `saved`, in the direction `restore` says.
static void copy_rect(uint8_t *canvas, uint8_t *saved, uint32_t w, struct rect r, int restore) {
  for (uint32_t y = r.y0; y < r.y1; y++) {
    size_t at = ((size_t)y * w + r.x0) * 4, n = (size_t)(r.x1 - r.x0) * 4;
    if (restore) memcpy(canvas + at, saved + at, n);
    else memcpy(saved + at, canvas + at, n);
  }
}

static void to_bgra(struct image *img) {
  for (size_t i = 0; i < img->len; i += 4) {
    uint8_t t = img->pixels[i];
    img->pixels[i] = img->pixels[i + 2];
    img->pixels[i + 2] = t;
  }
}

static enum status gif_wuffs(const uint8_t *in, size_t len, enum pixel_format format,
                             uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8 && format != PF_BGRA8) return STATUS_SKIPPED;
  enum status result = STATUS_REJECTED;
  uint8_t *saved = NULL;
  wuffs_base__image_decoder *dec = wuffs_gif__decoder__alloc_as__wuffs_base__image_decoder();
  wuffs_base__image_config ic = {0};
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)in, len, true);
  wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(dec, &ic, &src);
  if (!wuffs_base__status__is_ok(&st)) goto done;
  uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
  out->len = (size_t)w * h * 4;
  out->pixels = calloc(1, out->len ? out->len : 1);
  saved = calloc(1, out->len ? out->len : 1);
  wuffs_base__pixel_buffer pb;
  st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg,
                                                wuffs_base__make_slice_u8(out->pixels, out->len));
  if (!wuffs_base__status__is_ok(&st)) goto done;
  struct rect dispose = {0};
  int disposal = 0;
  for (;;) {
    wuffs_base__frame_config fc = {0};
    st = wuffs_base__image_decoder__decode_frame_config(dec, &fc, &src);
    if (st.repr == wuffs_base__note__end_of_data) break;
    if (!wuffs_base__status__is_ok(&st)) goto done;
    // The previous frame's disposal, now that there is a next frame.
    if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_BACKGROUND) fill(out->pixels, w, dispose);
    if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) copy_rect(out->pixels, saved, w, dispose, 1);
    wuffs_base__rect_ie_u32 b = wuffs_base__frame_config__bounds(&fc);
    dispose = clip(b.min_incl_x, b.min_incl_y, b.max_excl_x - b.min_incl_x, b.max_excl_y - b.min_incl_y, w, h);
    disposal = wuffs_base__frame_config__disposal(&fc);
    if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) copy_rect(out->pixels, saved, w, dispose, 0);
    wuffs_base__pixel_blend blend = wuffs_base__frame_config__overwrite_instead_of_blend(&fc)
                                        ? WUFFS_BASE__PIXEL_BLEND__SRC
                                        : WUFFS_BASE__PIXEL_BLEND__SRC_OVER;
    st = wuffs_base__image_decoder__decode_frame(dec, &pb, &src, blend, wuffs_base__empty_slice_u8(), NULL);
    if (!wuffs_base__status__is_ok(&st)) goto done;
  }
  out->width = w;
  out->height = h;
  if (format == PF_BGRA8) to_bgra(out);
  result = STATUS_OK;
done:
  free(saved);
  free(dec);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

struct source {
  const uint8_t *p;
  size_t len, at;
};

static int giflib_read(GifFileType *gif, GifByteType *dst, int n) {
  struct source *s = gif->UserData;
  size_t k = (size_t)n < s->len - s->at ? (size_t)n : s->len - s->at;
  memcpy(dst, s->p + s->at, k);
  s->at += k;
  return (int)k;
}

// giflib's DGifSlurp reads every frame's indices and extensions; the
// compositing is the same as Wuffs's above. giflib applies no palette, so
// a frame with none, or with an index past its palette, is left to Wuffs
// (STATUS_SKIPPED).
static enum status gif_giflib(const uint8_t *in, size_t len, enum pixel_format format,
                              uint64_t max_pixels, struct image *out) {
  if (format != PF_RGBA8 && format != PF_BGRA8) return STATUS_SKIPPED;
  // The screen size, checked before giflib allocates frames.
  if (len >= 10) {
    uint64_t sw = in[6] | in[7] << 8, sh = in[8] | in[9] << 8;
    if (sw * sh > max_pixels) return STATUS_TOO_LARGE;
  }
  enum status result = STATUS_REJECTED;
  uint8_t *saved = NULL;
  struct source src = {in, len, 0};
  int err = 0;
  GifFileType *gif = DGifOpen(&src, giflib_read, &err);
  if (!gif) return STATUS_REJECTED;
  if (DGifSlurp(gif) != GIF_OK) goto done;
  uint32_t w = (uint32_t)gif->SWidth, h = (uint32_t)gif->SHeight;
  if ((uint64_t)w * h > max_pixels) {
    result = STATUS_TOO_LARGE;
    goto done;
  }
  out->len = (size_t)w * h * 4;
  out->pixels = calloc(1, out->len ? out->len : 1);
  saved = calloc(1, out->len ? out->len : 1);
  struct rect dispose = {0};
  int disposal = 0;
  for (int i = 0; i < gif->ImageCount; i++) {
    SavedImage *im = &gif->SavedImages[i];
    GifImageDesc *d = &im->ImageDesc;
    GraphicsControlBlock gcb = {DISPOSAL_UNSPECIFIED, false, 0, NO_TRANSPARENT_COLOR};
    DGifSavedExtensionToGCB(gif, i, &gcb);
    ColorMapObject *map = d->ColorMap ? d->ColorMap : gif->SColorMap;
    if (!map) {
      result = STATUS_SKIPPED;
      goto done;
    }
    if (disposal == DISPOSE_BACKGROUND) fill(out->pixels, w, dispose);
    if (disposal == DISPOSE_PREVIOUS) copy_rect(out->pixels, saved, w, dispose, 1);
    struct rect r = clip((uint64_t)d->Left, (uint64_t)d->Top, (uint64_t)d->Width, (uint64_t)d->Height, w, h);
    dispose = r;
    disposal = gcb.DisposalMode;
    if (disposal == DISPOSE_PREVIOUS) copy_rect(out->pixels, saved, w, dispose, 0);
    for (int y = 0; y < d->Height; y++) {
      for (int x = 0; x < d->Width; x++) {
        int k = im->RasterBits[(size_t)y * d->Width + x];
        if (k == gcb.TransparentColor) continue;
        if (k >= map->ColorCount) {
          result = STATUS_SKIPPED;
          goto done;
        }
        uint64_t cx = (uint64_t)d->Left + x, cy = (uint64_t)d->Top + y;
        if (cx >= w || cy >= h) continue;
        uint8_t *p = out->pixels + (cy * w + cx) * 4;
        p[0] = map->Colors[k].Red;
        p[1] = map->Colors[k].Green;
        p[2] = map->Colors[k].Blue;
        p[3] = 255;
      }
    }
  }
  out->width = w;
  out->height = h;
  if (format == PF_BGRA8) to_bgra(out);
  result = STATUS_OK;
done:
  free(saved);
  DGifCloseFile(gif, &err);
  if (result != STATUS_OK) {
    free(out->pixels);
    out->pixels = NULL;
  }
  return result;
}

const struct op gif_ops[] = {
    {"gif-wuffs", gif_wuffs},
    {"gif-giflib", gif_giflib},
    {0},
};

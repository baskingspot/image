// giflib, to RGBA8, through its streaming calls: DGifGetLine into a row of
// indices, mapped through the color table into the caller's buffer, with
// giflib's own interlace order. `gif-decode` writes the first frame and
// stops; `gif-decode-anim` plays every frame into the canvas, applying each
// frame's disposal before the next (giflib applies neither color tables
// nor disposal, so this is the code a giflib caller writes).
#include <gif_lib.h>
#include <stdlib.h>
#include <string.h>

#include "arm.h"

struct source {
  const uint8_t *p;
  size_t len, at;
};

static int read_fn(GifFileType *gif, GifByteType *dst, int n) {
  struct source *s = gif->UserData;
  size_t k = (size_t)n < s->len - s->at ? (size_t)n : s->len - s->at;
  memcpy(dst, s->p + s->at, k);
  s->at += k;
  return (int)k;
}

// Kept between calls: a row of indices, and the region under a frame whose
// disposal is restore-previous.
static GifPixelType *line;
static size_t line_cap;
static uint8_t *saved;
static size_t saved_cap;

static int grow(void **p, size_t *cap, size_t need) {
  if (need <= *cap) return 1;
  free(*p);
  *p = malloc(need);
  *cap = need;
  return *p != NULL;
}

static size_t decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int all) {
  struct source src = {in, len, 0};
  int err = 0;
  GifFileType *gif = DGifOpen(&src, read_fn, &err);
  if (!gif) return 0;
  size_t result = 0;
  int w = gif->SWidth, h = gif->SHeight;
  size_t n = (size_t)w * h * 4;
  if (n > cap) goto done;
  GraphicsControlBlock gcb = {DISPOSAL_UNSPECIFIED, false, 0, NO_TRANSPARENT_COLOR};
  int frames = 0, disposal = 0, px = 0, py = 0, pw = 0, ph = 0;
  GifRecordType rt;
  do {
    if (DGifGetRecordType(gif, &rt) == GIF_ERROR) goto done;
    if (rt == EXTENSION_RECORD_TYPE) {
      int code;
      GifByteType *ext;
      if (DGifGetExtension(gif, &code, &ext) == GIF_ERROR) goto done;
      if (code == GRAPHICS_EXT_FUNC_CODE && ext && ext[0] == 4) DGifExtensionToGCB(4, ext + 1, &gcb);
      while (ext) {
        if (DGifGetExtensionNext(gif, &ext) == GIF_ERROR) goto done;
      }
    } else if (rt == IMAGE_DESC_RECORD_TYPE) {
      if (DGifGetImageDesc(gif) == GIF_ERROR) goto done;
      GifImageDesc *d = &gif->Image;
      ColorMapObject *map = d->ColorMap ? d->ColorMap : gif->SColorMap;
      if (!map || d->Left + d->Width > w || d->Top + d->Height > h) goto done;
      if (frames == 0 && (d->Left || d->Top || d->Width != w || d->Height != h)) memset(out, 0, n);
      size_t row = (size_t)pw * 4;
      for (int y = py; y < py + ph; y++) {
        uint8_t *p = out + ((size_t)y * w + px) * 4;
        if (disposal == DISPOSE_BACKGROUND) memset(p, 0, row);
        if (disposal == DISPOSE_PREVIOUS) memcpy(p, saved + (y - py) * row, row);
      }
      px = d->Left, py = d->Top, pw = d->Width, ph = d->Height;
      disposal = gcb.DisposalMode;
      row = (size_t)pw * 4;
      if (disposal == DISPOSE_PREVIOUS) {
        if (!grow((void **)&saved, &saved_cap, row * ph)) goto done;
        for (int y = py; y < py + ph; y++) memcpy(saved + (y - py) * row, out + ((size_t)y * w + px) * 4, row);
      }
      if (!grow((void **)&line, &line_cap, (size_t)pw + 1)) goto done;
      int over = frames > 0 && gcb.TransparentColor >= 0;
      for (int pass = d->Interlace ? 0 : 3; pass < 4; pass++) {
        static const int start[4] = {0, 4, 2, 1}, step[4] = {8, 8, 4, 2};
        int y0 = d->Interlace ? start[pass] : 0, dy = d->Interlace ? step[pass] : 1;
        for (int y = y0; y < ph; y += dy) {
          if (DGifGetLine(gif, line, pw) == GIF_ERROR) goto done;
          uint8_t *p = out + ((size_t)(py + y) * w + px) * 4;
          for (int x = 0; x < pw; x++, p += 4) {
            int k = line[x];
            if (k == gcb.TransparentColor) {
              if (!over) memset(p, 0, 4);
              continue;
            }
            if (k >= map->ColorCount) {
              p[0] = p[1] = p[2] = 0;
            } else {
              p[0] = map->Colors[k].Red;
              p[1] = map->Colors[k].Green;
              p[2] = map->Colors[k].Blue;
            }
            p[3] = 255;
          }
        }
      }
      gcb = (GraphicsControlBlock){DISPOSAL_UNSPECIFIED, false, 0, NO_TRANSPARENT_COLOR};
      frames++;
      if (!all) break;
    }
  } while (rt != TERMINATE_RECORD_TYPE);
  if (frames > 0) result = n;
done:
  DGifCloseFile(gif, &err);
  return result;
}

static size_t gif_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode(in, len, out, cap, 0);
}

static size_t gif_decode_anim(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return decode(in, len, out, cap, 1);
}

BENCH_OP("gif-decode", gif_decode)
BENCH_OP("gif-decode-anim", gif_decode_anim)

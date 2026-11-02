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

// Encode (bench/corpus/gif_encode.sh): raw RGBA8 to a file in memory
// through EGifOpen's write callback, the calls a giflib caller makes.
// giflib has no quantizer of its own but GifQuantizeBuffer, a median cut
// over RGB without dithering, which ignores alpha, so: an image with at
// most 256 colors (alpha below 128 as one transparent color) is stored
// exactly, with a graphic control extension for its transparent index,
// and any other is quantized by GifQuantizeBuffer, its alpha dropped.
// `gif-encode-anim` writes every frame whole, 10 hundredths of a second
// each, looping forever, each disposed to background when it has
// transparency; giflib does not crop.
struct sink {
  uint8_t *p;
  size_t cap, len;
};

static int write_fn(GifFileType *gif, const GifByteType *src, int n) {
  struct sink *s = gif->UserData;
  if ((size_t)n > s->cap - s->len) return 0;
  memcpy(s->p + s->len, src, (size_t)n);
  s->len += (size_t)n;
  return n;
}

// libgif exports GifQuantizeBuffer, but giflib 6's header no longer
// declares it; this is its declaration from giflib's quantize.c.
int GifQuantizeBuffer(unsigned int width, unsigned int height, int *color_map_size, GifByteType *red,
                      GifByteType *green, GifByteType *blue, GifByteType *output, GifColorType *output_color_map);

// Kept between calls: the frame's indices and GifQuantizeBuffer's planes.
static GifByteType *indices, *planes;
static size_t indices_cap, planes_cap;

// The frame's palette and indices: exact when it has at most 256 colors,
// else GifQuantizeBuffer's. Returns the transparent index or -1, and 0 in
// *count on failure.
static int palette(const uint8_t *in, size_t n, GifColorType *colors, int *count) {
  enum { slots = 1024 };
  uint32_t keys[slots];
  uint8_t vals[slots];
  memset(keys, 0xff, sizeof keys);
  int k = 0, transparent = -1;
  *count = 0;
  if (!grow((void **)&indices, &indices_cap, n)) return -1;
  for (size_t i = 0; i < n; i++) {
    const uint8_t *p = in + i * 4;
    uint32_t key = p[3] < 128 ? 0x1000000u : (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
    uint32_t h = (key * 2654435761u) >> 22;
    while (keys[h] != key && keys[h] != 0xffffffffu) h = (h + 1) & (slots - 1);
    if (keys[h] == 0xffffffffu) {
      if (k == 256) goto quantize;
      keys[h] = key;
      vals[h] = (uint8_t)k;
      if (key == 0x1000000u) {
        transparent = k;
        colors[k] = (GifColorType){0, 0, 0};
      } else {
        colors[k] = (GifColorType){p[0], p[1], p[2]};
      }
      k++;
    }
    indices[i] = vals[h];
  }
  *count = k;
  return transparent;
quantize:
  if (!grow((void **)&planes, &planes_cap, n * 3)) return -1;
  for (size_t i = 0; i < n; i++) {
    planes[i] = in[i * 4];
    planes[n + i] = in[i * 4 + 1];
    planes[2 * n + i] = in[i * 4 + 2];
  }
  k = 256;
  if (GifQuantizeBuffer((unsigned)n, 1, &k, planes, planes + n, planes + 2 * n, indices, colors) == GIF_ERROR)
    return -1;
  *count = k;
  return -1;
}

static int put_frame(GifFileType *gif, const uint8_t *in, int w, int h, int anim, int global) {
  GifColorType colors[256];
  int count;
  int transparent = palette(in, (size_t)w * h, colors, &count);
  if (count == 0) return 0;
  int bits = 1;
  while ((1 << bits) < count) bits++;
  ColorMapObject *map = GifMakeMapObject(1 << bits, NULL);
  if (!map) return 0;
  memcpy(map->Colors, colors, (size_t)count * sizeof colors[0]);
  int ok = 0;
  if (global && EGifPutScreenDesc(gif, w, h, bits, 0, map) == GIF_ERROR) goto done;
  if (global && anim) {
    static const uint8_t loop[3] = {1, 0, 0};
    if (EGifPutExtensionLeader(gif, APPLICATION_EXT_FUNC_CODE) == GIF_ERROR ||
        EGifPutExtensionBlock(gif, 11, "NETSCAPE2.0") == GIF_ERROR ||
        EGifPutExtensionBlock(gif, 3, loop) == GIF_ERROR || EGifPutExtensionTrailer(gif) == GIF_ERROR)
      goto done;
  }
  if (anim || transparent >= 0) {
    GraphicsControlBlock gcb = {transparent >= 0 && anim ? DISPOSE_BACKGROUND : DISPOSAL_UNSPECIFIED, false,
                                anim ? 10 : 0, transparent};
    GifByteType ext[4];
    EGifGCBToExtension(&gcb, ext);
    if (EGifPutExtension(gif, GRAPHICS_EXT_FUNC_CODE, 4, ext) == GIF_ERROR) goto done;
  }
  if (EGifPutImageDesc(gif, 0, 0, w, h, false, global ? NULL : map) == GIF_ERROR) goto done;
  for (int y = 0; y < h; y++)
    if (EGifPutLine(gif, indices + (size_t)y * w, w) == GIF_ERROR) goto done;
  ok = 1;
done:
  GifFreeMapObject(map);
  return ok;
}

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int anim) {
  size_t canvas = (size_t)bench_width * bench_height * 4;
  if (canvas == 0 || len % canvas != 0 || (!anim && len != canvas)) return 0;
  struct sink s = {out, cap, 0};
  int err = 0;
  GifFileType *gif = EGifOpen(&s, write_fn, &err);
  if (!gif) return 0;
  EGifSetGifVersion(gif, true);
  int ok = 1;
  for (size_t at = 0; ok && at < len; at += canvas)
    ok = put_frame(gif, in + at, (int)bench_width, (int)bench_height, anim, at == 0);
  if (EGifCloseFile(gif, &err) == GIF_ERROR) ok = 0;
  return ok ? s.len : 0;
}

static size_t gif_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 0);
}

static size_t gif_encode_anim(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 1);
}

static size_t gif_encode_few(const uint8_t *in, size_t len, uint8_t *out, size_t cap) {
  return encode(in, len, out, cap, 0);
}

BENCH_OP("gif-encode", gif_encode)
BENCH_OP("gif-encode-few", gif_encode_few)
BENCH_OP("gif-encode-anim", gif_encode_anim)

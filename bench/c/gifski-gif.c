// gifski, libimagequant's GIF encoder, through its C API: raw RGBA8
// (bench/corpus/gif_encode.sh) to a file in memory by its write callback,
// at quality 90, the value its documentation recommends and its command
// line's default, at the input's size. gifski always quantizes, so its few-color row is not
// exact. `gif-encode-anim` adds each whole canvas as a frame 0.1 s apart,
// and gifski crops and disposes on its own. gifski encodes on threads of
// its own; the harness pins the arm to one core, as every arm.
//
// nixpkgs ships libgifski without gifski.h, so its declarations are here,
// from gifski 1.34's header.
#include <stdbool.h>
#include <string.h>

#include "arm.h"

typedef struct gifski gifski;
typedef struct {
  uint32_t width, height;
  uint8_t quality;
  bool fast;
  int16_t repeat;
} GifskiSettings;
gifski *gifski_new(const GifskiSettings *settings);
int gifski_add_frame_rgba(gifski *g, uint32_t frame, uint32_t width, uint32_t height, const unsigned char *pixels,
                          double pts);
int gifski_set_write_callback(gifski *g, int (*cb)(size_t len, const uint8_t *buf, void *user), void *user);
int gifski_finish(gifski *g);

struct sink {
  uint8_t *p;
  size_t cap, len;
  int overflow;
};

static int write_cb(size_t len, const uint8_t *buf, void *user) {
  struct sink *s = user;
  if (len > s->cap - s->len) {
    s->overflow = 1;
    return 1;
  }
  memcpy(s->p + s->len, buf, len);
  s->len += len;
  return 0;
}

static size_t encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap, int anim) {
  size_t canvas = (size_t)bench_width * bench_height * 4;
  if (canvas == 0 || len % canvas != 0 || (!anim && len != canvas)) return 0;
  // Without a size, gifski scales an image down to about half a megapixel.
  gifski *g = gifski_new(&(GifskiSettings){.width = bench_width, .height = bench_height, .quality = 90});
  if (!g) return 0;
  struct sink s = {out, cap, 0, 0};
  int ok = gifski_set_write_callback(g, write_cb, &s) == 0;
  for (size_t i = 0; ok && i * canvas < len; i++)
    ok = gifski_add_frame_rgba(g, (uint32_t)i, bench_width, bench_height, in + i * canvas, (double)i / 10) == 0;
  if (gifski_finish(g) != 0) ok = 0;
  return ok && !s.overflow ? s.len : 0;
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

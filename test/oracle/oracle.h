// The image oracle: decodes inputs with the reference libraries so the
// harness in test/oracle/compare.zig can hold this package's decoders
// against them. oracle.c has the protocol; each format's file
// (test/oracle/<format>.c) defines its decoders as an `ops` table, and
// formats.def lists the formats.
#ifndef ORACLE_H
#define ORACLE_H

#include <stddef.h>
#include <stdint.h>

// image.PixelFormat's values, in its order.
enum pixel_format {
  PF_GRAY8,
  PF_GRAY_ALPHA8,
  PF_GRAY_ALPHA8_PREMUL,
  PF_RGB8,
  PF_BGR8,
  PF_RGBA8,
  PF_RGBA8_PREMUL,
  PF_BGRA8,
  PF_BGRA8_PREMUL,
  PF_GRAY16,
  PF_GRAY_ALPHA16,
  PF_GRAY_ALPHA16_PREMUL,
  PF_RGB16,
  PF_BGR16,
  PF_RGBA16,
  PF_RGBA16_PREMUL,
  PF_BGRA16,
  PF_BGRA16_PREMUL,
  PF_RGBA_F32,
  PF_RGBA_F32_PREMUL,
  PF_RGB_F32,
  PF_GRAY_F32,
  // Inverted inks, so all-zero bytes are black (src/pixel.zig).
  PF_CMYK8,
  PF_CMYK16,
};

enum status {
  // Decoded: the pixels follow, tightly packed in the requested format.
  STATUS_OK = 0,
  // The library refused the input.
  STATUS_REJECTED = 1,
  // The library cannot write the requested format.
  STATUS_SKIPPED = 2,
  // The image is over the request's pixel limit.
  STATUS_TOO_LARGE = 3,
};

struct image {
  uint32_t width, height;
  // malloc'd, freed by the caller.
  uint8_t *pixels;
  size_t len;
};

// Decodes the first frame of `in` as `format` into `out`, refusing images
// of more than `max_pixels` before allocating them.
typedef enum status (*decode_fn)(const uint8_t *in, size_t len, enum pixel_format format,
                                 uint64_t max_pixels, struct image *out);

// Encodes `pixels`, a `width` by `height` image tightly packed in
// `format`, into `out->pixels` (malloc'd) and `out->len`: the file a
// reference encoder writes. oracle.c fills in the width and height.
typedef enum status (*encode_fn)(const uint8_t *pixels, enum pixel_format format, uint32_t width,
                                 uint32_t height, struct image *out);

// An op decodes, or with `encode` set (`{"name", .encode = fn}`) encodes.
struct op {
  const char *name;
  decode_fn decode;
  encode_fn encode;
};

// The bytes a pixel of `format` takes.
size_t pixel_bytes(enum pixel_format format);

// wuffs.c: the first frame through any Wuffs image decoder, which it frees.
struct wuffs_base__image_decoder__struct;
enum status wuffs_decode(struct wuffs_base__image_decoder__struct *dec, const uint8_t *in,
                         size_t len, enum pixel_format format, uint64_t max_pixels,
                         struct image *out);

// magick.c: the first image through ImageMagick's MagickWand, in any
// format but the premultiplied ones. The image's size is checked against
// `max_pixels` from a ping before it is read.
struct magick {
  // What to read the input as, for MagickSetFormat ("BMP", or "TGA", which
  // has no signature), or NULL to let Magick detect it.
  const char *format;
  // A file name for MagickSetFilename, such as "netpbm[0]" to read only
  // the first image of a sequence, or NULL.
  const char *filename;
  // Reject warnings as well as errors. Magick reports some truncated and
  // malformed files only as warnings, and decodes what it can.
  int reject_warnings;
};
enum status magick_decode(const struct magick *how, const uint8_t *in, size_t len,
                          enum pixel_format format, uint64_t max_pixels, struct image *out);

#define FORMAT(name) extern const struct op name##_ops[];
#include "formats.def"
#undef FORMAT

#endif

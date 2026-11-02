# WebP decode: notes and decisions

`src/webp/` is a streaming WebP decoder written from RFC 9649 (the container
and the lossless bitstream) and, for lossy, RFC 6386. This file records what
it does where the specifications leave room, and why. Results:
`results/webp-20261102.md`.

Stage 1 decodes lossless (VP8L) files, simple and extended; stage 2 adds
lossy (VP8) files with ALPH alpha. Animation (ANIM/ANMF) is `Unsupported`
until stage 3.

## Shape

- `Decoder.zig` reads the RIFF header and chunks from the caller's
  `std.Io.Reader`: the first chunk is VP8L, VP8, or VP8X; after VP8X, chunks
  up to the image chunk are read in any order (ICCP, EXIF, and XMP go to the
  blob sink and the first of each into `Config.metadata`; the rest are
  skipped). `decodeConfig` stops after the VP8L chunk's 5-byte header, which
  gives the size and so `work_len`; for a lossy image it stops after the
  VP8 frame header, or at an ALPH chunk's header, sizing the work from the
  VP8X canvas and the bytes left in the payload.
- `lossless.zig` is the bitstream. `BitReader` pulls from the container's
  reader directly, no further than the chunk's end, eight bytes at a time
  when the reader's buffer has them; past the end it reads zeros and counts
  them, and a stream that consumed any is `Truncated` at the next check (or
  in place of the format error those zeros caused).
- Prefix codes are two-level tables of 16-bit entries (value and length),
  with a root of at most 8 bits. A group whose red, blue, and alpha codes
  have one symbol each (`trivial`) decodes a literal with one green lookup.
  The pixel loop keeps the bit reader's state in locals (`Hot`), which was
  the largest single gain.
- Pixels are decoded into a ring of ARGB words, and each finished row goes
  through the inverse transforms (in reverse order of the stream) into a
  row buffer, then to the destination: copied when it is BGRA8, the native
  format (ARGB words in little-endian memory), converted with
  `image.convert` otherwise. Predictor modes run a pixel at a time as
  `@Vector(4, u8)`, and the modes that read only the row above (2, 3, 4)
  run eight pixels at a time; the color transform is vectorized over a
  block's span; a color-indexed image unbundles in place from right to
  left.

## Work memory

`Config.work_len` is fixed by the width, the height, and
`Options.max_prefix_groups` before any of the bitstream is read:

| Piece                                    | Bytes                                       |
| ---------------------------------------- | ------------------------------------------- |
| Entropy-coded pixels (LZ77 reaches back) | 4 × min(W·H, 2^20 + 2W)                     |
| Two transform rows                       | 4 × (2W + 1)                                |
| Predictor, color, and entropy images     | 3 × 4 × ⌈W/4⌉·⌈H/4⌉                         |
| Color table, color cache                 | 1 KiB + 8 KiB                               |
| Group remap (bitmap and rank)            | 12 KiB                                      |
| Prefix code tables                       | (G + 1) × 10,024, G = min(⌈W/4⌉·⌈H/4⌉, cap) |

No backward distance is longer than 2^20 − 120 pixels plus the 7-row
neighborhood, so an image above about a megapixel keeps a ring rather than
every pixel. The table bound per code is zlib's `enough` count for a 15-bit
code with an 8-bit root (n + 374 entries for n symbols, 410 for 40). The
extra group is scratch for groups the entropy image names but never uses.

Only what a stream uses is touched, so peak RSS follows the image, not the
bound: the bound is what the caller allocates, and it is large for a
modest image (a 1024 by 1024 file states 4 MiB of pixels and 26 MiB of
tables, of which a cwebp file touches a few hundred KiB). A caller that
wants less lowers `max_prefix_groups`.

## Decisions

- **The prefix group cap: 2600 by default.** RFC 9649 lets an entropy image
  name up to 2^16 groups, which would need 650 MiB of tables. libwebp's
  encoder never writes more than 2600 (its `MAX_HUFF_IMAGE_SIZE`), and the
  decoder allocates per file. Wuffs caps at 256 and fails the bench's
  50-megapixel cwebp file (278 groups named, 260 used). We count only the
  distinct groups the entropy image uses, remap them densely, and fail with
  `Unsupported` past the cap. Owner decision: the default value.
- **Strict, as libwebp is.** An incomplete or oversubscribed prefix code
  (except the one-symbol code), a code-length code that reads past
  `max_symbol`, a backward reference before the first pixel or past the
  last, a repeated transform, a color cache of 0 or more than 11 bits, or a
  version other than 0 is an error. A simple code's symbol outside its
  alphabet (the 8-bit form in the 40-symbol distance code) is dropped, as
  libwebp drops it, which may leave a valid one-symbol code. Predictor
  modes 14 and 15 decode as mode 0 (opaque black), as libwebp does.
- **A simple code's two symbols** get canonical codes from their lengths, so
  the smaller symbol is code 0, as libwebp does; Wuffs assigns them in
  written order. Only generated streams differ: cwebp writes them in order.
- **The chunk bounds the bitstream.** libwebp hands a VP8L decoder every
  byte after the chunk header, so a stream longer than its chunk decodes
  into the following bytes. We stop at the chunk's end, as Wuffs does: such
  a file is `Truncated`.
- **The RIFF payload must be all there.** libwebp fails a still image whose
  RIFF size runs past the end of the file, even when the image chunk is
  whole, so `decodeFrame` reads to the payload's end, passing ICCP, EXIF,
  and XMP chunks after the image to the blob sink (they do not change a
  config already returned). A chunk header after the image whose size runs
  past the payload ends the walk, and the payload's last bytes are skipped.
  A simple file's image chunk may end the payload without its padding byte;
  after VP8X every chunk counts its padding, as libwebp counts them.
- **VP8X.** The canvas must equal the bitstream's size for a still image
  (`BadHeader`). The flags other than animation are not checked against the
  chunks present: ICCP, EXIF, and XMP are read whether announced or not,
  and an ALPH chunk beside VP8L is skipped, as the specification says.
  Wuffs rejects both; libwebp reads them as we do.
- **Native format and alpha.** The native format is BGRA8, the order the
  pixels are decoded in. `Config.is_opaque` is the header's alpha hint
  inverted: a hint of 0 promises every alpha is 255. RGB8 output drops
  alpha (`image.convert`), as libwebp's RGB mode does; Wuffs composites onto
  black.

## Lossy (VP8) and alpha

- `vp8.zig` is RFC 6386's key frame decoder: the boolean decoder, the frame
  header, per-macroblock modes and tokens, the inverse transforms,
  prediction, and the loop filter, run a macroblock row at a time. Rows
  go to a sink as soon as the filter is done with them and their chroma
  neighbors are final, eight luma rows behind the macroblock row.
- `yuv.zig` converts rows to RGB as libwebp does by default: "fancy"
  upsampling (9:3:3:1 with libwebp's two-step rounding) and BT.601 in
  14-bit fixed point, written straight into RGB8, BGR8, RGBA8, or BGRA8
  rows; other formats go through `image.convert` from RGB8 or RGBA8. The
  native format is RGB8, or RGBA8 with an ALPH chunk.
- `alpha.zig` decodes an ALPH chunk, raw or lossless (the lossless decoder
  with the green channel kept), into a plane of W·H bytes, then unfilters
  it in place (horizontal, vertical, or gradient). The plane is whole
  because ALPH precedes VP8 in the stream; libwebp also allocates the
  whole plane.

### Bit-exact with libwebp on x86

VP8's reconstruction is exactly specified only for streams that do not
overflow, and libwebp's x86 code (the oracle) decides what happens when
they do. We match it:

- A coefficient times its dequantization factor wraps to 16 bits.
- The full inverse DCT runs in 16-bit wrapping arithmetic (SSE2); the
  three-coefficient transform (used when the last nonzero coefficient is
  the second or third in zigzag order), the DC-only transform, and the
  inverse WHT run in 32 bits, so a product past 16 bits is kept there.
- Chroma: if any of a plane's four blocks has an AC coefficient, all four
  get the full transform; otherwise only the blocks with a nonzero DC
  get the DC transform.
- The loop filter level adds the segment and mode deltas, then clamps once;
  the filter type comes from the frame header. Inner edges are filtered when
  any block has coefficients. Segmentation enabled without new data means
  absolute quantizers of 0.
- The boolean decoder loads 7 bytes whenever 8 remain in the partition and
  one byte otherwise, then zeros past the end, as libwebp does: on a stream
  that breaks the coder's interval, what it shifts out depends on this, and
  a frame that reads past a partition's end fails (`Truncated`).

### Work memory

`decodeConfig` reads up to the VP8 frame header (after VP8X, through the
ALPH chunk's header), so `Config.work_len` is known before any pixel data:

| Piece                                        | Bytes                                       |
| -------------------------------------------- | ------------------------------------------- |
| Output row and two upsampled chroma rows     | 6W                                          |
| Alpha plane (ALPH only)                      | W·H                                         |
| Compressed partitions (below)                | min(L, P0 + bytes for the token partitions) |
| Context rows (above, intra, nonzero, filter) | about 40 × MBW                              |
| Pixel band (24 luma, 16 + 16 chroma rows)    | 640 × MBW                                   |

and, with an ALPH chunk, the lossless decoder's work for a W×H image in
place of the VP8 pieces when it is larger (they are not live at once). L is
the bytes left in the RIFF payload (or the VP8 chunk), P0 the most the
first partition can be read (7/8 of a byte per boolean for its worst-case
boolean count, capped at its 19-bit size), and the token partitions'
bound is what MBW × (MBH + 7) macroblocks of worst-case tokens can read.
Every partition but the last is kept: they interleave by macroblock row,
and the stream is read once. The last streams from the reader. So for a
typical file the partition buffer is about the file's size, and the pixel
state is O(W), not O(W·H).

### Splits

- **Partitions past the chunk.** libwebp gives a still image's partitions
  every byte to the end of its input, not just the VP8 chunk's, and so does
  Wuffs: a partition that runs past the chunk decodes from the padding
  byte, the chunks after it, or bytes past the RIFF payload. This decoder
  reads on past the chunk too (`vp8.decode`'s `after`). The bytes past it
  are peeked, not consumed, while they fit in 64 bytes (what any reader
  can peek), so a valid file's last loads, which libwebp makes seven bytes
  at a time while eight remain, leave the chunks after the image to be
  read; past that, they are consumed, the chunks after the image are lost,
  and the rest of the payload is skipped. Kept partitions are bounded by
  the payload, so a partition past the RIFF payload's end is cut there
  (`Truncated`, where libwebp may decode).
- Wuffs matches libwebp on opaque lossy files, but not everywhere under
  an alpha of 0 in files with ALPH.
- ALPH errors: as libwebp does, the last ALPH chunk before the image is
  the one used, and a lossless image chunk ignores ALPH chunks entirely.
- Reading past a lossless ALPH stream's end. libwebp decodes an alpha
  stream a byte a pixel when its only transform is color indexing, it has
  no color cache, and its literals are green alone, and then checks for the
  end only between symbols that leave pixels to decode, so the last symbol
  may read past it. Its bit window is the stream's last eight bytes with
  zeros above: a last literal that starts inside them decodes as if the
  stream went on in zeros, which this decoder accepts too; one that starts
  at their end, or needs a second-level lookup past it, wraps around to
  the window's start in libwebp, and a backward reference resets the
  window, so this decoder rejects those (`Truncated`), as Wuffs does. Every
  other lossless stream fails if it reads past its end at all, in libwebp
  too.

## Speed

`results/webp-20261102.md` has the numbers. Against libwebp 1.6.0 on one
core, lossless: icons 1.46× faster (no per-call allocation), 0.88× to a
megapixel, 0.91× over one, 0.97× on the 50-megapixel mosaic, at about half
libwebp's peak RSS. What is left: color-indexed images with flat areas
(0.54–0.80×, libwebp's palette fast paths), the predictor transform on
photographs (mode-by-mode SIMD only for the above-only modes), and the
per-symbol table lookups for groups that are not trivial.

Lossy, with the same output as libwebp on every row: icons 1.36× faster,
0.92× to a megapixel, 0.86× over one, 1.02× overall, at or below libwebp's
peak RSS in every size class. What is left: the loop filter and the token
reader, which run a pixel or a coefficient at a time where libwebp's SSE2
filters take 16 pixels.

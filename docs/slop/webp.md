# WebP decode: notes and decisions

`src/webp/` is a streaming WebP decoder written from RFC 9649 (the container
and the lossless bitstream) and, for lossy, RFC 6386. This file records what
it does where the specifications leave room, and why. Results:
`results/webp-20261102.md`.

Stage 1 (this branch's first push) decodes lossless (VP8L) files, simple and
extended. Lossy (VP8, with ALPH) and animation (ANIM/ANMF) are `Unsupported`
until stages 2 and 3.

## Shape

- `Decoder.zig` reads the RIFF header and chunks from the caller's
  `std.Io.Reader`: the first chunk is VP8L, VP8, or VP8X; after VP8X, chunks
  up to the image chunk are read in any order (ICCP, EXIF, and XMP go to the
  blob sink and the first of each into `Config.metadata`; the rest are
  skipped). `decodeConfig` stops after the VP8L chunk's 5-byte header, which
  gives the size and so `work_len`.
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

## Speed

`results/webp-20261102.md` has the numbers. Against libwebp 1.6.0 on one
core, lossless: icons 1.46× faster (no per-call allocation), 0.88× to a
megapixel, 0.91× over one, 0.97× on the 50-megapixel mosaic, at about half
libwebp's peak RSS. What is left: color-indexed images with flat areas
(0.54–0.80×, libwebp's palette fast paths), the predictor transform on
photographs (mode-by-mode SIMD only for the above-only modes), and the
per-symbol table lookups for groups that are not trivial.

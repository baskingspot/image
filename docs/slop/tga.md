# TGA

Decode and encode, `src/tga/`. Written from the Truevision TGA File Format
Specification, version 2.0 (1989), which also defines the original format
that has no footer. Measurements are in `results/tga-20261101.md`.

## Decoder

Streaming and allocation-free, as `docs/slop/adding-a-format.md` asks. The
color map is the only work memory: `work_len` is 4 bytes for each map entry
(at most 65535 entries, 256 KiB), stored as native pixels so an index is one
4-byte load. True-color and gray images need no work memory.

Native formats: `bgr8` or `bgra8` for color (the file's own byte order, so an
uncompressed 24- or 32-bit row into a `bgr8` or `bgra8` destination is a
copy), `gray8` or `gray_alpha8` for gray. 15- and 16-bit pixels widen to
`bgr8`, or to `bgra8` when they carry alpha.

What the specification leaves open, and what this decoder does:

| Question                                 | Choice                                                                          | Agrees with                                         |
| ---------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------- |
| 32-bit pixels and map entries            | Always alpha, whatever the descriptor's attribute-bit count says                | Wuffs, stb_image, ImageMagick                       |
| 16-bit pixels' top bit                   | Alpha only when the descriptor names one or more attribute bits                 | ImageMagick (Wuffs and stb_image ignore it)         |
| 15- and 16-bit map entries               | Opaque: the specification says the 16th bit of a map entry is not alpha         | Wuffs, stb_image                                    |
| Five-bit channels                        | Bit replication, `c << 3 \| c >> 2`                                             | Wuffs (stb_image truncates, ImageMagick rounds)     |
| The map's first entry index              | Offsets the indices: pixel value `i` is entry `i - first`                       | ImageMagick (Wuffs rejects it, stb_image misreads)  |
| An index outside the map                 | Opaque black                                                                    | Wuffs (stb_image uses entry 0, ImageMagick rejects) |
| A run-length packet crossing a scan line | Allowed: older writers produce them, and the specification only advises against | stb_image, ImageMagick (Wuffs rejects)              |
| A packet past the last pixel             | `error.RunPastEnd`                                                              | Wuffs (stb_image and ImageMagick drop the extra)    |
| Right-to-left origins                    | Mirrored                                                                        | ImageMagick (Wuffs rejects, stb_image ignores)      |
| A map in a true-color or gray file       | Skipped                                                                         | Wuffs                                               |
| Interleave bits, screen origin           | Ignored                                                                         |                                                     |
| Zero width or height                     | Accepted, nothing to write                                                      | Wuffs, in some origins                              |
| Type 0 (no image)                        | A config with no frames                                                         |                                                     |
| A truncated file                         | `error.Truncated`                                                               | Wuffs, ImageMagick (stb_image fills with zeros)     |

`test/oracle/tga.zig` lists the same splits from the oracle's side, with what
`adapt` and `comparable` do so each library still checks the rest.

### Speed

Uncompressed rows convert straight from the reader's buffer when the buffer
holds a whole row, which avoids a copy per row; that took 16×16 icons from
852 to 1288 MP/s. Otherwise a span of up to 256 pixels decodes into a stack
buffer and converts from there. Run-length packets decode into the same
stack span, so a run costs one fill.

## Footer and extension area

Both follow the pixels, so they cannot shape `Config`, and reading forward
only, the decoder cannot jump to the offsets the footer gives. The
`decodeFrame` call after the image (the first, for type 0) reads to the end
of the input, keeping the first bytes after the image data and the last 51
(the extension area's last 25 bytes and the 26-byte footer), and `Decoder.trailer()` reports what it found: whether there is a
footer, its two offsets, and an `Extension` when the extension area starts
right after the image data or ends right before the footer, the two places
writers put it. An extension area elsewhere (after a developer area, say)
is reported by offset only.

From the extension area:

- `Extension.metadata.gamma`: the gamma value as PNG's gAMA stores it,
  100000 / gamma, so the file's 2.2 is 45455. Zero denominator means unset.
  This assumes the file's gamma is the display exponent, as the
  specification's example (2.2) suggests; the owner should confirm the
  direction.
- `Extension.metadata.density`: the pixel aspect ratio (x = denominator,
  y = numerator), with no unit.
- `Extension.background`: the key color as straight RGBA, unless zero.
- `Extension.alpha`: the attributes type (none, ignore, retain, straight,
  premultiplied).

The text fields, time stamps, postage stamp, and the scan-line, color, and
developer tables are skipped. The decoder does not premultiply or drop alpha
on the attributes type's say: it reports it, and the caller decides.

## Encoder

`encode(writer, src, options, work)`, `EncodeOptions{ .rle = true }`:

- Gray sources store 8-bit gray (type 3 or 11), color 24-bit BGR (2 or 10),
  and anything with alpha 32-bit BGRA with straight alpha and eight attribute
  bits. Gray with alpha goes to BGRA because TGA's 16-bit gray has no
  descriptor convention the three oracles agree on.
- Top-left origin, so rows go out in order, and the TGA 2.0 footer with no
  extension area or developer directory.
- Run-length packets stay within a scan line, as the specification asks. A
  run packet takes a run of two or more pixels (three for gray, where a run
  of two costs as much as raw), and a raw packet takes everything up to the
  next run. Comparing pixels as one 24- or 32-bit integer took RLE encode
  of the 50 MP photo from 163 to 293 MP/s. The files are the smallest of
  the three encoders compared (results file).
- `workLen` is a row in the file's format plus, for RLE, its worst-case
  packets; null when a side exceeds 65535.

## After the frames

`applyTrailer` (plan.md decision 10) sets the extension area's gamma and
density in `Config.metadata` and its key color in `Config.background`, so
`image.Decoder.finalConfig` reports them; the attributes type has no place
in `Config` and stays on `Decoder.trailer()`.

## Open questions for the owner

- Gamma direction (above).
- 16-bit attribute bit: we follow the descriptor, Wuffs and stb_image never
  read it as alpha. Files from writers that set the bit and leave the
  descriptor at 0 read as opaque, which is what the specification says.

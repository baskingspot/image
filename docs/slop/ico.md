# ICO and CUR

Notes and decisions for `src/ico/`. The format is a six-byte header, a
directory of 16-byte entries, and each entry's data: a DIB (an info header,
a color table, XOR pixels, and a 1-bit AND mask) or a PNG stream. The DIB
goes through BMP's reader, `src/bmp/dib.zig`, with `Container.ico` for the
rules that differ.

## Decode

- Default: every entry is a frame, in directory order, written to the
  top-left of a canvas as large as the largest directory size (0 means
  256). `Frame.index` is the directory index and the frame's region is the
  entry's own size; an entry larger than the canvas is
  `error.EntryTooLarge`. `entry(i)`, `entryCount`, and `isCursor` report
  the directory, with a CUR's hotspot in `planes` and `bits`.
- `decodeFrameConfig` (plan.md decision 11) reads the next entry's header,
  moving to it as `decodeFrame` would, and returns its frame; the header is
  kept for `decodeFrame`, so nothing is read twice and no seek is needed.
  With `Options.entry` the frame is the canvas. Every frame here replaces
  its region and has disposal `none`, so a caller has nothing to save, but
  `image.Decoder` cannot synthesize the call for a multi-frame format.
  ICO has no `applyTrailer`: nothing follows its entries.
- `Options.entry = i`: entry `i` alone, on a canvas of its own size, which
  comes from its header. A PNG entry decodes through `image.png` this way
  (behind `@hasDecl`, so the build works without it); without it, PNG
  entries are `error.Unsupported`. A still PNG is read through IEND, whose
  CRC is checked as in a PNG file; an APNG entry gives its first frame.
- An entry's size is its header's: a DIB's width and half its height, or a
  PNG's IHDR. The directory's sizes and byte count are not trusted, since
  encoders get them wrong.
- DIB entries: a 40-byte BITMAPINFOHEADER, uncompressed, 1, 4, 8, 24, or 32
  bits, width above 0, height at least 2; planes is not checked. 32-bit
  entries take their alpha from the pixels and do not read the AND mask;
  the rest are opaque except where the mask is set (alpha 0, color kept for
  straight formats; all zeros for premultiplied ones). A color table has
  `biClrUsed` entries (or 2^bits); the first 256 are kept and the rest
  skipped.
- The directory is held inline (256 entries, 4 KiB); more is
  `error.Unsupported`. No work memory for DIB entries.

## Seeking: entries whose offsets do not ascend

Decision: **read forward, in directory order; an entry behind the reader
needs a caller-supplied seeker, and is `error.EntryBehind` without one.**
`Options.entry` never needs one, because the picked entry is the only data
read after the directory.

- The seeker is the shared `image.Seeker`, passed in `Options.seeker`
  (`DecodeOptions.seeker` through `image.Decoder`): a context and a
  `seek(offset)` function that moves the reader so its next byte is the
  input's byte `offset`, counted from the input's first byte, and drops
  what it buffered. `Seeker.fixed(reader)` serves a `std.Io.Reader.fixed`
  over the whole file (no copy: the caller who has the file in memory
  already has a seekable source), and `Seeker.file(file_reader)` a file.
  It began here as `ico.Seeker` and moved to `src/decode.zig` when the owner
  took it for TIFF too (plan.md decision 8); `ico.Seeker` is gone, with no
  alias, since nothing released named it.
- Forward gaps are skipped with `discard`, so a file whose entries ascend,
  which is every encoder's output we have seen, decodes from any stream.
- An entry whose data starts inside the directory is `error.BadHeader`,
  checked when the entry is reached.

Why not the alternatives:

- **Sort by offset and decode forward.** Handles any layout without seeking
  except entries that share or overlap data, but frames then come out of
  directory order, and it does not carry over to TIFF, whose IFD chain and
  strip offsets are discovered one IFD at a time and cannot be sorted up
  front.
- **The whole file in memory.** Breaks the bounded, caller-owned memory
  model for the case that needs it least; a caller who has the bytes passes
  `Seeker.fixed` and gets the same result without a copy.
- **A documented error only.** Rejects valid files. The seeker costs about
  30 lines and nothing on the forward path.

For TIFF (wave 3): the same contract fits IFD offsets and strip offsets.
The fuzz target (`test/fuzz/ico.zig`, `checkSeeking`) decodes every input
with and without a seeker and requires the same frames up to the first
`EntryBehind`, so hostile offsets reach the seek path.

## PNG entries in the all-entries mode (decision 37)

`decodeConfig` must report `work_len` before any entry is read, and a PNG
entry's work memory depends on its IHDR, which a forward-only reader cannot
see until it reaches the entry. So a file with several entries reports a
bound: `png.Decoder.maxWorkLen(canvas width)`, the work memory of a 16-bit
RGBA PNG that wide, which covers any PNG no wider than the canvas (at most
256, so about 76 KiB). It is reported whether or not the file has a PNG
entry, since the directory cannot say; a file with one entry reports its
own entry's needs (0 for a DIB, the PNG's own for a PNG).

`decodeFrameConfig` peeks the IHDR for a PNG entry's size, and an entry
larger than the canvas is `error.EntryTooLarge`, as for a DIB. `decodeFrame`
draws the PNG on the `bgra8` canvas through `image.png`, reading it through
a `std.Io.Reader.Limited` capped at the entry's directory length with a
4 KiB buffer on the stack. The bytes it took from the reader, which is
what the cap has used, advance the decoder's position, so the next entry
is skipped to or sought as before. A PNG longer than its directory length
is `error.Truncated`; an animated PNG gives its first frame, as when
picked.

## Encode

`encode` writes one image and `encodeAll` several (1 to 256, sides 1 to
256). `Options.cursor` writes a CUR, with `hotspot` per image. Each entry's
`Payload` (`Image.payload`, or `Options.payload` for `encode`) is:

- `.bmp`: a 32-bit BMP entry with straight alpha and an AND mask set where
  alpha is 0, for readers that ignore alpha. No work memory.
- `.png`: `png.encode` with its default options and `max_depth = .@"8"`
  on the image's own pixels, unconverted: a 16-bit or float source is
  narrowed row by row inside the PNG encoder (decision 38), and PNG's
  reduction to gray or a palette keeps icons small. Work memory is `png.workLen` (868,871
  bytes at 256 by 256 at the default effort).
- `.auto`, the default (plan.md decision 17): PNG at 256 by 256, BMP below,
  as Windows' own icons are made and as readers before Vista need.

The directory gives every entry's length before any entry, and the writer
cannot go back, so a PNG entry is encoded twice over the same work memory:
into an `Io.Writer.Discarding` to measure it, then into the file.
`png.encode`'s bytes depend only on the pixels, options, and work length
(its doc comment promises it, and its tests check it), so the two agree. A
single pass would need the encoded entries buffered (about the size of the
PNGs) or a `png.maxEncodedLen` bound and padding; the second encode costs
time only, on an icon's largest entry.

Decoding: a file whose only entry is a PNG decodes as if `Options.entry` were
0, so its config (size, native format, work memory) is the PNG's and
`ico.encode`'s 256 by 256 output reads back without options. A file with
several entries decodes every entry in order, PNG ones too (above).

## Oracle

ImageMagick is the only reference that reads ICO; test/oracle/ico.zig lists
where it reads fields differently and how `comparable` and `adapt` keep that
from hiding real disagreements. It compares entry 0 only (Magick's first
image) through `test/fuzz/ico.zig`'s `FirstEntry`.

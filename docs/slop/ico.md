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
- `Options.entry = i`: entry `i` alone, on a canvas of its own size, which
  comes from its header. A PNG entry decodes through `image.png` this way
  (behind `@hasDecl`, so the build works without it); without it, PNG
  entries are `error.Unsupported`.
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

- `ico.Seeker` is a context and a `seek(offset)` function that moves the
  reader so its next byte is the input's byte `offset` and drops what it
  buffered. `Seeker.fixed(reader)` serves a `std.Io.Reader.fixed` over the
  whole file (no copy: the caller who has the file in memory already has a
  seekable source), and `Seeker.file(file_reader)` a file.
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
The type is private to `src/ico/` until the orchestrating thread moves it;
the request is `image.Seeker` in `src/decode.zig` with the same two
constructors, and `DecodeOptions.seeker: ?Seeker`, so `image.Decoder`
passes it through (today the generic decoder cannot give ICO one, and
out-of-order ICO files fail there with `EntryBehind`).

## PNG entries in the all-entries mode

`decodeConfig` must report `work_len` before any entry is read, and a PNG
entry's work memory depends on its IHDR, which a forward-only reader cannot
see until it reaches the entry. So the all-entries mode rejects PNG entries
with `error.Unsupported`, and `Options.entry` decodes them. The fix, once
`image.png` lands, is a bound: a PNG `workLen(width, height)` upper bound
for any PNG of that size, so the all-entries mode can report the bound for
the canvas (at most 256 by 256) and reject a PNG entry whose IHDR is larger
than its directory size.

## Encode

`encode` writes one image and `encodeAll` several (1 to 256, sides 1 to
256): each a 32-bit BMP entry with straight alpha and an AND mask set where
alpha is 0, for readers that ignore alpha. `Options.cursor` writes a CUR,
with `hotspot` per image. PNG entries, which large icons use, wait for the
PNG encoder in wave 5. No work memory.

## Oracle

ImageMagick is the only reference that reads ICO; test/oracle/ico.zig lists
where it reads fields differently and how `comparable` and `adapt` keep that
from hiding real disagreements. It compares entry 0 only (Magick's first
image) through `test/fuzz/ico.zig`'s `FirstEntry`.

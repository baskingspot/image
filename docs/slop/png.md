# PNG and APNG decode: notes and decisions

`src/png/` is a streaming PNG and APNG decoder written from the PNG
specification, third edition (W3C, 2025), which includes APNG. This file
records what it does where the specification leaves room, and why. Results:
`results/png-20261101.md`.

## Shape

- `Decoder.zig` reads chunks from the caller's `std.Io.Reader`. A
  `DataReader` is an `Io.Reader` over the data of consecutive IDAT chunks (or
  fdAT chunks after their sequence numbers), checking each chunk's CRC as it
  ends; `compress`'s `zlib.Reader` inflates on top of it, with its 64 KiB
  window in the caller's work memory. Each row is a `takeByte` for the filter
  type and a `readSliceAll`, then unfiltered in place.
- Work memory (`Config.work_len`): the 64 KiB inflate window, an 8 KiB
  staging buffer between the chunks and inflate, and two rows. Nothing scales
  with the height, unlike Wuffs, whose work buffer is the whole image's
  filtered rows.
- When the image is not interlaced, has 8-bit samples without tRNS, and the
  destination is the native format, rows unfilter straight into the
  destination. Otherwise rows go through a 256-pixel span: expand to the
  native format (bit depths below 8, 16-bit byte order, tRNS, palettes),
  then convert to the destination, scatter for Adam7, or blend.
- `filter.zig`: Up is a 32-byte vector add; Sub and Paeth for pixels of 2
  to 8 bytes, and Average for 3 to 8, run a pixel at a time with the
  pixel's bytes as vector lanes and Paeth's choice made with `@select`;
  the rest stay scalar, where vectors measured no faster.
- A palette image written as RGBA8 expands its RGBA palette entries straight
  into the destination rows.
- `crc32.zig`: slice-by-16 CRC-32, private until `compress` exports one.

## Decisions

- **Checksums: strict, as Wuffs is.** The CRC-32 of every critical chunk
  (IHDR, PLTE, IDAT, IEND) is checked: a mismatch is `BadCrc`. Ancillary
  chunks' CRCs are not checked, as in Wuffs; libpng and libspng also accept
  a bad ancillary CRC by default, so checking it would reject files every
  reference reads. APNG's chunks are ancillary by name, so acTL, fcTL, and
  fdAT are not checked either; Wuffs decodes a frame whose fdAT CRC is wrong
  too (checked by hand on a two-chunk APNG). The zlib stream's
  Adler-32 is checked (`BadChecksum`).
- **`Options.ignore_checksums`** (owner, decision 9), off by default, skips
  both, as Wuffs's `IGNORE_CHECKSUM` quirk does: critical chunks' CRCs are
  not computed at all, and a wrong Adler-32 at the stream's end is
  accepted. `compress`'s `zlib.Reader` has no way to skip the Adler-32, so
  it is still computed and its mismatch ignored; skipping it would need a
  `zlib.Reader` option that leaves flate's checksum hook unset and reads
  the trailer without comparing. The rest is unchanged: a stream that ends
  before the last row is still `NotEnoughData` even when its checksum is
  also wrong. Skipping the CRCs saves about 4.5% of a decode at every size
  (`results/png-ignore-checksums-20261101.md`).
- **Image data must be exact.** The zlib stream must decompress to exactly
  the rows the frame needs: fewer is `NotEnoughData`, more (or bytes after
  the zlib stream in the data chunks) is `TooMuchData`. Empty IDAT or fdAT
  chunks after a frame's data are allowed and skipped, as libpng allows
  them; a non-empty one is `TooMuchData`.
- **The one exception: an interlaced frame one row tall** (owner, decision
  9), as in Wuffs. Wuffs reads such an image only to its last row: when the
  zlib stream has more data there, the rest of the stream, its Adler-32,
  and any bytes after it in the data chunks go unread, and the image
  decodes; at every other height, interlaced or not, the same file is
  rejected. When the stream ends at the last row it is checked as usual
  (a bad Adler-32 or bytes after it are still errors). The decoder does
  the same, and still checks the CRCs of the data chunks it skips. Checked
  against Wuffs on hand-built files: extra data, extra data with a bad
  Adler-32, extra data with bytes after the stream, and bytes after a
  stream that ends at the last row, at heights 1 and 2 and widths 1, 5,
  and 9.
- **The APNG default image.** When acTL comes before IDAT but no fcTL does,
  the IDAT image is not part of the animation, and the decoder skips it, as
  Wuffs does and as the APNG section says decoders that support APNG do:
  `decodeFrame` returns the animation's frames, and `Config.frame_count` is
  acTL's count. A caller that wants the static fallback image has no way to
  get it yet; that is an owner decision (an `Options` flag), noted in the
  wave-1 report. Its IDAT chunks are skipped wherever they are, even when
  another chunk splits them, as Wuffs skips them, since they are never
  decoded. When an fcTL comes before IDAT, the IDAT image is frame 0
  and its fcTL must cover the canvas.
- **APNG frames.** `decodeFrame` writes each frame into its region of the
  caller's canvas. `Frame.blend` is `src_over` only for a frame after the
  first whose fcTL says blend over and whose image has alpha; otherwise
  `src`. Over is composited in straight 16-bit RGBA and rounded to nearest.
  Frame 0 clears the canvas outside its region to transparent black, as
  Wuffs does. So that every format can hold that, and disposal to
  background, an APNG's native format always has alpha, even when its
  pixels have none (an RGB APNG's native format is RGBA, and
  `Config.is_opaque` is false); `Frame.is_opaque` still says whether the
  frame's own pixels are. A first attempt cleared to opaque black for
  images without alpha, which Wuffs's output contradicted on 53 of 20,000
  fuzzed inputs. Disposal is the caller's job, before the next
  call; frame 0's dispose-previous is reported as background (there is
  nothing to revert to). fcTL and fdAT sequence numbers must count up from 0
  (`BadChunk`), and the frame count must match acTL's at IEND (`BadChunk`).
  `Limits.max_frames` counts frames as they are reached: the frame past it
  is `TooManyFrames` from the call that reaches it, and an acTL count over
  the limit makes `Config.frame_count` null rather than a number the
  caller's limit forbids. It was checked at acTL until the PNG encoder's
  oracle run found a file with a mutated acTL count whose first frame all
  three references decode; frames take no memory of their own, so the
  early check bought no safety. A frame
  count of 0 or past 2^31 − 1 is `BadChunk`; a play count past 2^31 − 1
  cannot change the pixels and is reported as written, as Wuffs reads it.
- **Chunk order and contents.** Chunks that shape the pixels (IHDR, PLTE,
  tRNS, IDAT, IEND, acTL, fcTL, fdAT) must follow the specification, or the
  decode is `BadChunk`: a palette image without PLTE, PLTE after tRNS or in a
  gray image, a tRNS longer than the palette or of the wrong length, a
  second tRNS, and so on. A chunk that cannot change the pixels is ignored
  when malformed: a metadata chunk with a bad length or value, a tRNS beside
  an alpha channel (all three references ignore it), a suggested PLTE in a
  truecolor image. For metadata the first of a duplicate wins. An unknown
  ancillary chunk is skipped; an unknown critical one is `Unsupported`.
  Chunk type bytes are not checked to be letters, as in Wuffs and libspng.
- **Palette indices past the palette** decode as opaque black, as the
  specification requires (Wuffs does the same; libpng errors by default).
- **tRNS keys** are compared after masking to the bit depth, as the
  specification says only the low bits are significant.
- **Metadata.** gAMA, cHRM, sRGB, pHYs, and bKGD go in `Config` and are never
  applied. iCCP's blob is the zlib-compressed profile (`encoding = .zlib`,
  offset just after the name and method byte); eXIf's is the whole chunk,
  and the orientation is read from its first 4 KiB. Both are passed to the
  blob sink as they stream past. Only chunks before the first IDAT count
  toward `Config.metadata`, and `decodeConfig` gives the same answer after
  the frames. The third edition puts every one of these chunks before IDAT;
  after it, gAMA, cHRM, sRGB, pHYs, bKGD, and iCCP are skipped unread, as
  libpng skips them. eXIf is the exception, since PNG's extensions before
  the third edition allowed it after the image data and writers still put
  it there: it goes to the sink, and `applyTrailer` (plan.md decision 10)
  sets it and its orientation in `image.Decoder.finalConfig`. tIME and the
  text chunks, the only chunks allowed there, have no place in `Config`.
- **`decodeFrameConfig`** (decision 11) reads up to the next frame's first
  data chunk (IDAT or fdAT, through its header) and returns its `Frame`;
  the frame stays pending, and `decodeFrame` draws it without reading those
  chunks again.
- **When a frame ends.** `decodeFrame` returns once the frame's last data
  chunk's CRC is read and it has seen that the next chunk is of another
  kind; it does not read that chunk. A still image's IEND is read by the
  second `decodeFrame`, which returns null, so a file cut right after its
  image data decodes its image and then reports `Truncated`.

## Speed

`results/png-20261101.md` has the numbers. Inflate dominated: with
`compress` 0.2.0, 75–100% of a decode was inflate, and the decoder ran at
0.38× Wuffs. The `image-png-inflate` branch of `compress` adds a fast path
to `flate.Reader` (2.3–2.9× on PNG image data), which takes the decoder to
0.79× Wuffs and 1.3–1.4× libpng and libspng. Vector Sub, Average, and Paeth
added 13.8%, and palettes expanded straight into RGBA8 rows 44–48% on
palette images. What is left against Wuffs: inflate on literal-heavy data,
the copy of each row out of inflate's window, and per-call setup on icons.

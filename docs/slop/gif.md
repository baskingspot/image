# GIF decode: notes and decisions

`src/gif/` is a streaming GIF decoder written from the GIF87a (CompuServe, 1987) and GIF89a (1990) specifications, with the NETSCAPE2.0 application
extension's loop count. This file records what it does where the
specifications leave room, and why. Results: `results/gif-20261101.md`.

## Shape

- `Decoder.zig` reads blocks from the caller's `std.Io.Reader`: the header
  and global color table in `decodeConfig`, then each frame's extensions,
  image descriptor, local color table, and data sub-blocks. Sub-blocks are
  gathered into a 4 KiB buffer, so the LZW decoder sees one run of bytes
  however the file splits them.
- `lzw.zig`: the variable-width LZW decoder. Each table entry is up to
  8 bytes of the string's tail (`tail: [4096]u64`) and a `meta: u32`
  holding its prefix code and length, so a string is written 8 bytes at a
  time from its end backward. Literals are entries too, so the hot loop has
  one case for both. The bit accumulator refills 8 bytes at a time, and
  the previous code's entry stays in registers. `decode` is `noinline`, so
  its loop's registers are not shared with the frame loop around it.
- Indices are decoded into an 8 KiB buffer and turned into pixels when it
  fills: each row's span is looked up in the palette, which is converted
  to the destination format once per color table (for RGBA8 the entries
  are written straight from the file). A frame with a transparent index
  takes a separate path that skips those pixels.
- Work memory (`Config.work_len`, about 68 KiB): the LZW table (48 KiB),
  the index buffer, the data buffer, and the converted palette. Nothing
  scales with the image.
- Interlaced frames write the rows of each pass to their places in the
  destination; nothing is buffered.

## Decisions

- **Frames follow the APNG model.** `decodeFrame` writes each frame into
  its region of the caller's canvas, which must hold the previous frame
  with its disposal applied. Frame 0 clears the canvas outside its region
  to transparent black and writes its transparent pixels as transparent
  black, so its `Frame.blend` is `src`; a later frame with a transparent
  index leaves the canvas under those pixels alone (`src_over`), and one
  without is `src`. This is what Wuffs produces when composited with SRC
  for frame 0 and the frame's blend after. The native format is always
  RGBA8 and `Config.is_opaque` false, since uncovered canvas is
  transparent; `Frame.is_opaque` says whether the frame has no
  transparent index.
- **Disposal.** Method 2 is `background`, which the caller clears to
  transparent black, as Wuffs and every browser do; the global background
  color is reported in `Config.background` but never applied. Method 3 is `previous`. Method 4 is undefined in the
  specification; Wuffs and Chromium read it as `previous`, and so does
  this decoder (giflib reports it as written and its callers mostly
  ignore it). Methods 0, 1, 5, 6, and 7 are `none`. Frame 0's `previous`
  is reported as `background`, as in APNG: before frame 0 the canvas is
  transparent black.
- **`decodeFrameConfig`.** Restore-to-previous needs the region saved
  before the frame is drawn, but `decodeFrame` returns the frame after.
  `decodeFrameConfig` reads the next frame's extensions, descriptor, and
  color table and returns its `Frame` without writing pixels; the next
  `decodeFrame` returns the same frame. It returns null where
  `decodeFrame` would. This is a GIF addition to the decoder contract for
  now; plan.md should decide whether every animated format offers it
  (APNG has the same need, and its fcTL is read before the data too).
- **The canvas.** The canvas is the logical screen, grown to hold the
  first frame when the first frame reaches past it, as Wuffs and Chromium
  do (giflib reports the screen as written). Later frames are clipped to
  the canvas: `Frame.x`, `y`, `width`, and `height` are the clipped
  region, and the pixels outside it are decoded and dropped. A frame
  entirely outside has an empty region. The grown size is checked against
  `Limits` like any other, and every frame's own size is checked too, so a
  small canvas cannot hide a frame of 65535 × 65535.
- **LZW data must be exact.** A frame's codes must decode to exactly its
  pixels: fewer, when the sub-blocks end, is `NotEnoughData`; more is
  `TooMuchData` (Wuffs's behavior; giflib drops the excess). Data after
  the end-of-information code is skipped. A stream that holds every pixel
  but no end code is accepted, since many encoders stop there. A code past
  the next free entry is `BadLzw`, as is a minimum code size past 8. A
  minimum code size of 0, which no encoder should write (2 to 8 is usual,
  and 1 is common in bilevel files), decodes as Wuffs and
  giflib both read it: clear code 1, end code 2, codes starting 1 bit
  wide. A first version rejected it, and the oracle found a file both
  references decode to the same pixels, so 0 is
  accepted. When the table is full, codes are read at 12 bits and nothing
  is added until a clear code, as the specification's "deferred clear"
  allows.
- **Truncation.** A file cut anywhere is `Truncated`, including after the
  last frame where the trailer should be: the frames before it decode, and
  the call that would read the trailer returns the error, as PNG's missing
  IEND does. A byte where a block should start (not `!`, `,`, or `;`) ends
  the image as the trailer does, as Wuffs reads it; giflib rejects it.
- **Extensions.** The graphic control extension must be one 4-byte block
  and its terminator (`BadBlock`); when several come before one frame the
  last wins (Wuffs; giflib takes the first). A plain text extension does
  not consume the pending graphic control extension, as Wuffs reads it;
  it is skipped, as are comments and unknown application extensions. The
  loop count is read from NETSCAPE2.0 or ANIMEXTS1.0 before the first
  frame: `Config.loop_count` is the count plus one plays (0 forever), or
  1 when there is none, as browsers play such a file once (decision 12;
  a first version reported null). One after the first
  frame is skipped, since the config is already returned. ICC (`ICCRGBG1012`)
  and XMP (`XMP DataXMP`) application extensions are skipped, not passed to
  the blob sink: a blob is announced with its length, and a GIF extension's
  length is known only at its end. Reporting them needs a blob with an
  unknown length (a harness request).
- **Color tables.** A frame uses its local table when it has one and the
  global table otherwise. A frame with neither, or an index past the table
  it uses, is opaque black, as in Wuffs. The transparent index may be past
  the table; it is still transparent. Only `GIF87a` and `GIF89a`
  signatures are accepted (giflib takes any `GIF8?a`), and a GIF87a file
  with GIF89a extensions decodes them.
- **Frame count.** `Config.frame_count` is null; GIF does not say. More
  frames than `Limits.max_frames` is `TooManyFrames` when the extra
  frame's descriptor is read. Delays convert from hundredths of a second
  to flicks, as written: a delay of 0 is reported as 0 and a player picks
  its own minimum.

## Speed

`results/gif-20261101.md` has the numbers: 1.12× Wuffs over all 52 rows
(1.21–1.24× on stills of 1 MP and up, 1.11–1.21× on animations past
icons, 0.88–0.95× on icons), and 2.3–15× giflib, stb_image, Rust's
`image`, and Go. Peak memory is the lowest of every arm in every size
class. What made the difference: table entries that write 8 bytes at a
time, the read-ahead bit accumulator, the palette converted once per
table, and `decode` kept out of line. A packed 12-byte entry struct
measured 0.4× Wuffs on icons (store-forwarding stalls on the unaligned
loads) and was dropped. Icons are bound by the LZW loop, not setup: a 1×1
GIF costs 110 ns here and 263 ns in Wuffs. Left on the table: a
branchless transparent path for RGBA8 (the bounce animation, 0.88× Wuffs)
and a gather for the palette lookup.

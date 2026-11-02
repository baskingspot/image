# GIF: notes and decisions

`src/gif/` is a streaming GIF decoder written from the GIF87a (CompuServe, 1987) and GIF89a (1990) specifications, with the NETSCAPE2.0 application
extension's loop count, and a GIF89a encoder (`encode.zig`, "Encoder"
below). This file records what they do where the specifications leave
room, and why. Results: `results/gif-20261101.md` (decode) and
`results/gif-encode-20261102.md` (encode).

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
- **LZW data must be exact** by default (decision 12). A frame's codes
  must decode to exactly its pixels: fewer, when the sub-blocks end, is
  `NotEnoughData`; more is `TooMuchData` (Wuffs's behavior; giflib drops
  the excess). `Options.ignore_too_much_data`, off by default, does what
  Wuffs's IGNORE_TOO_MUCH_PIXEL_DATA quirk does: the extra pixels are
  dropped, and a bad code once the frame is whole ends its data instead of
  failing. "Whole" is Wuffs's reading, checked by probing it: every row
  of every pass written; for a frame 0 columns wide, once any index comes;
  for one 0 rows tall, from the start, unless it is interlaced, and then
  never. The oracle holds both settings against Wuffs (test/oracle/gif.zig
  picks one per input). Data after
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
  it is skipped, as are comments and unknown application extensions. A
  0 right after an application extension's identifier is its terminator,
  as the specification says, even for NETSCAPE2.0, where Wuffs reads it as
  the loop count's sub-block size and reads on past it (the oracle hands
  Wuffs such an extension renamed, only where a block starts, since the
  same bytes inside other data can hold a sub-block length;
  test/oracle/gif.zig). The
  loop count is read from NETSCAPE2.0 or ANIMEXTS1.0 before the first
  frame: `Config.loop_count` is the count plus one plays (0 forever), or
  1 when there is none, as browsers play such a file once (decision 12;
  a first version reported null). One after the first
  frame is skipped, since the config is already returned.
- **ICC and XMP.** `ICCRGBG1012` and `XMP DataXMP` application extensions
  are blobs (decision 13): each piece goes to the blob sink as it is read,
  with `Blob.len` null until the last, and the finished blob lands in
  `Config.metadata` when it comes before the first frame, or in
  `applyTrailer` (so `image.Decoder.finalConfig`, decision 10) after it.
  The first of each kind wins, wherever it comes; later ones are skipped
  and never reach the sink. ICC's payload is the sub-blocks' data and its
  offset is the first data byte; a profile with no sub-blocks is a 0-byte
  blob. XMP's payload is every byte after the identifier block, length
  bytes and terminator included, less the last 258, the magic trailer
  (1, then 255 down to 0, then the terminator) that makes the packet's
  bytes parse as sub-blocks; those 258 are held back and not checked, and
  the offset is the first byte after the identifier block. An XMP
  extension shorter than 258 bytes is no packet and gives no blob. A file
  cut short inside either leaves pieces in the sink with no last piece and
  no blob in the metadata.
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

## Encoder

`encode.zig` writes GIF89a from the specification: `encode` for a still,
`encodeAnimation` for frames shaped like PNG's (`AnimationFrame` with
pixels, position, duration in flicks, and disposal), allocation-free with
`workLen` up front, from any `PixelFormat`.

### Shape

- `lzw_encode.zig`: the LZW encoder. The dictionary is a hash table of
  `u32` slots, `key << 12 | code` with 0 for empty (a stored code is past
  the end code, so never 0), sized to
  the image (`tableLen`, 64 to 8192 slots). The stream starts with a clear
  code and clears again when the table is full. The code width follows the
  decoder, which learns each entry a code late: the encoder tracks the
  decoder's next code, not its own, so the width changes exactly where a
  decoder widens.
- `quantize.zig`: a histogram of the opaque pixels at 5 bits a channel
  (33³ cumulative moments, Wu's layout), the three quantizers, k-means
  `refine` over the nonempty cells, a lookup from a pixel's 6-bit cell to
  its nearest palette entry (filled lazily, the search 16 entries at a
  time), and the ditherer. Only the touched-cell bitset is cleared per
  frame, not the 1.4 MB table: `add` writes a cell's first pixel, and
  readers mask cells it never wrote.
- Work memory: two RGBA8 rows, a row of indices, two rows of dither
  errors, the LZW table, and the exact color set, about 6 KiB for a small
  image; an image of more than 256 pixels adds the quantizer (about 2.4 MiB
  in all). Interlacing a dithered image adds a byte a pixel, since error
  diffusion runs top to bottom and the file wants the passes.
- **One pass on exact frames.** Counting a frame's colors maps each pixel
  to its index in the color set, so the count keeps the indices it makes
  in memory an exact frame leaves idle (the quantizer's 2.4 MiB, or 256
  bytes for an image too small to quantize), and the LZW encoder reads
  them back; only rows past what fits (images over about 2.4 megapixels)
  are converted and mapped a second time. Mapping and counting were each
  about a fifth of an exact encode, and LZW the rest. An image-sized
  index buffer would make large images one pass too, at a byte a pixel of
  work memory; that trade is not taken (results/gif-encode2-20261102.md).

### Decisions

- **At most 256 colors is exact.** Alpha below 128 is transparent and
  counts as one color; other pixels are opaque with their RGB kept. A
  frame whose colors fit is stored with them in the order they first
  appear, never quantized. Otherwise the frame is quantized to 256 colors,
  or 255 and a transparent entry. The transparent entry and the table's
  padding to a power of two repeat a real color, so every table entry is
  one of the frame's colors (a decoder that ignores transparency shows a
  plausible color).
- **Tables.** Frame 0's palette is the global table; a later frame with a
  different palette has a local one. A graphic control extension is
  written for every animation frame and for a still with transparency.
  NETSCAPE2.0 is written unless `loop_count` is 1, with `loop_count - 1`
  repeats (0 is forever), clamped to 65535. Delays are flicks rounded to
  hundredths, clamped to 65535.
- **No blend field.** GIF composites one way: a frame's transparent pixels
  show what is beneath. PNG's `AnimationFrame` has `blend` (`.src` by
  default); GIF cannot store `.src` over an opaque canvas, so its frame has
  no such field, and a caller whose next frame turns opaque pixels
  transparent disposes the frame to background (the oracle and the bench do
  exactly that: `clears` in test/oracle/gif_encode.zig and
  bench/zig/gif.zig). An alternative is for the encoder to set that
  disposal itself; that would override the caller's disposal, so it is left
  to the owner (the report asks).
- **Cropping** (`crop`, on by default). A frame keeps only the bounding box
  of pixels that are opaque and, when the previous frame has the same
  region and disposal none, differ from it; inside the box, unchanged
  pixels become transparent, which compresses better, and only the changed
  pixels are histogrammed, so a frame that changes a few colors is often
  stored exactly. Unchanged pixels show as the canvas shows them, which
  after a quantized frame is its approximation: so a frame with at most 256
  colors after a quantized one is stored whole, to stay exact, and
  `prev_exact` tracks whether the canvas shows the previous frame exactly.
  A frame disposed to background is not trimmed, since that would clear
  less than the frame. Before this was settled, unchanged pixels were
  skipped only after an exact frame, and a truecolor screen recording was
  stored as whole frames (2.88 MB for screen-1280x720 against
  ImageMagick's 260 KB and gifski's 765 KB; 309 KB after).
- **Quantizer and dither (decision 6).** Wu's quantizer with no k-means
  passes and Floyd-Steinberg dithering are the defaults, as measured in
  `results/gif-encode-20261102.md`: Wu beats median cut and octree on every
  metric at the same speed, `refine` adds at most 0.15 dB, and dithering
  trades about 2 dB of PSNR for smooth gradients (blurred PSNR +4 dB, the
  eye's low-pass), as ImageMagick, Go, and gifski all dither by default.
  `.none` is for screen content and smaller files (about 17% smaller).
  The owner decides.
- **Bounded error diffusion.** Floyd-Steinberg passes on at most 16 a
  channel per pixel. Unbounded, error that builds up where the palette is
  sparse reaches a far palette entry and leaves stray dots (blue specks in
  a gray sky, yellow in a red parrot); bounded, they go, and mean PSNR rose
  from 38.15 to 39.01 dB, blurred PSNR from 50.96 to 51.17, and SSIM from
  0.9666 to 0.9715 (limits 8 to 64 measured; 16 has the best blurred PSNR).
  The lookup maps from the 6-bit cell's center, so a pixel's color is off
  by at most 1.5 a channel before its nearest entry is found.

### Checks

- **Oracle** (test/oracle/gif_encode.zig, `just oracle N 1 gif_encode`):
  every GIF input the gif oracle has (corpus and fuzzed) is decoded by our
  decoder, its composited canvases re-encoded by our encoder (a still, or
  whole-canvas frames with their delays, which the encoder crops), and the
  file decoded by Wuffs, giflib, and ours; all three must agree on the
  final canvas. When every canvas has at most 256 colors, ours must also
  read back each canvas and disposal exactly. A planted code-width bug at
  the power-of-two boundary gave mismatches within 2,000 inputs.
- **Fuzz** (test/fuzz/gif_encode.zig): stills through
  `harness.checkEncoderWith` in several option sets, with an `expect` hook
  that accepts the exact image when it has at most 256 colors and
  otherwise bounds the error: same transparency, colors within the
  source's range, the mean within 8 a channel, and each pixel no farther
  from its source than the nearest table entry plus the lookup's and the
  dither bound's slack. Animations of 2 to 4 frames with regions and
  disposals compare composited canvases, exactly when every frame is
  exact. The hook reads the decoded pixels through a capturing decoder
  wrapper, since it is not handed them.
- **Unit tests** in encode.zig, quantize.zig, and lzw_encode.zig, including
  the crop after a quantized frame and the dither bound, each failing
  without its change.

### Speed

`results/gif-encode-20261102.md` has the numbers against giflib, gifski,
ImageMagick, and Go, with output sizes and peak RSS, and decision 6's
measurements: 1.75–89× faster than gifski, ImageMagick, and Go on every
quantized row; against giflib, faster on animations that change little
(1.43–1.75×, cropping) and on exact icons (1.14×), slower on truecolor
stills (0.39–0.68×, where giflib does not dither) and on exact stills past
icons (0.73–0.81×: our exact path reads the pixels twice, and giflib's LZW
loop is faster). Peak RSS is the lowest or tied in every class but
quantized icons (4.0 MiB against giflib's 3.3).

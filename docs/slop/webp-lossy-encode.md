# WebP lossy encode: notes and decisions

`image.webp.lossy` writes one VP8 key frame (RFC 6386) in a RIFF container
(RFC 9649), written from the specifications; libwebp is the oracle and the
bar. Results: `results/webp-lossy-encode-20261102.md`.

## Shape

- `src/webp/vp8_encode.zig`: the options, the work memory layout, mode
  decision, segments, the first partition, alpha, and the container.
- `vp8_encode_dsp.zig`: the forward DCT and WHT (16-lane vectors), the
  decoder's inverse transforms and predictors copied privately (the WebP
  orb owns `vp8.zig`), quantization with 16-lane step, reciprocal, and
  rounding vectors in zigzag order, a 4x4 Hadamard SATD, and SSE.
- `vp8_encode_bool.zig`: the boolean encoder (`Writer`, which streams
  through a one-byte cache and a count of pending 0xff bytes for carries),
  a `Counter` that follows only the range to size a partition without
  writing it, one token walker shared by the writer, the counter, and the
  tallies, and coefficient costs from the current probabilities.
- `vp8_encode_tables.zig`: the specification's tables (copied from
  `vp8_tables.zig`), the zigzag order and bands, and a cost table in 1/256
  bit.

One encode:

1. Each macroblock row is converted from the source format (RGB8, RGBA8
   when it has alpha) to BT.601 limited-range YUV 4:2:0, each chroma
   sample the rounded mean of its 2x2 pixels. Partial macroblocks repeat
   the last column and row.
2. Segments (not at `fast`): each macroblock's luma activity is 16·log2 of
   its 4x4 blocks' mean variance; k-means over the histogram of those
   makes four segments, and a segment's quantizer index is the quality's
   plus 3/32 of its center's distance from the mean activity (1.5 indices
   per doubling). Its loop filter level is 3/8 of its quantizer index; the
   frame's level is the largest, since a frame level of 0 turns the filter
   off whatever the segments say.
3. The main pass decides every macroblock's modes against the token
   probabilities' costs, keeps its quantized levels in work memory (a
   count and one or two bytes per level, at most 793 bytes a macroblock),
   and counts its tokens. `best` runs the pass twice, the second with
   costs from the probabilities the first chose.
4. The token probabilities are updated where the counts save more than
   the update costs; the skip flag is used when it costs less than the
   empty macroblocks' end-of-block tokens.
5. Both partitions are sized by a `Counter` pass, then the file is written
   in one pass to the caller's writer: nothing is buffered whole.

Work memory (`workLen`) is about 45 KiB of state, 803 bytes per
macroblock (the level store's worst case, the modes, and the activity),
and 37 bytes per pixel of width: 3.2 bytes per pixel in all. With
`alpha_compression` it adds the alpha plane, its stream (a byte a pixel
each), and the lossless encoder's work memory at the alpha effort: 24, 30,
and 38 MB at 1024×1024 for `fast`, `default`, and `best`, and 1.1 GB for
the 50-megapixel mosaic. An encode touches the state, the rows, and about
its output's size again in levels, and the alpha parts only when the
source has alpha, so peak RSS stays below libwebp's.

## Decisions

- **Quality means what it means to cwebp.** `quantizerIndex` maps quality
  to the base quantizer index that `cwebp -q N -sns 0 -segments 1` chose,
  measured at 16 points and interpolated, so `quality = 75` lands near
  `cwebp -q 75` in size and PSNR; segments then move each segment from that
  base.
- **Rate and distortion.** Every choice the effort tries is transformed,
  quantized, reconstructed, and costed as squared error plus lambda times
  bits. Lambda is 0.018 of the squared AC step per bit (150 to 220 measured
  equal; 300 and up worse). Quantization rounds DC at half a step and AC at
  3/8: rounding down saves more bits than it costs error.
- **Effort.** `fast`: no segments; the 16x16 and chroma modes by least
  SATD plus mode cost, each 4x4 block's mode from DC, TM, VE, and HE by
  SATD, and rate and distortion only between 16x16 and 4x4. `default`:
  segments, all four 16x16 and chroma modes by rate and distortion, and
  each 4x4 block's three best modes by SATD tried by rate and distortion
  (all ten measured 0.3% smaller on PSNR and 0.5% on SSIM). `best`: every
  4x4 mode, and two passes, under 1% smaller than `default` for 2.5× the
  time.
- **Segments balance PSNR and SSIM.** On the tuning images, equal
  quantizers in every segment gave the best PSNR (5.2% under cwebp -m4)
  but the worst SSIM (3.1% under); 3/32 gives 3.8% and 4.7%. More
  measured no better on either. On held-out images it is 1.5% over on
  PSNR and 4.5% under on SSIM: the segments spend PSNR on SSIM, as
  cwebp's SNS does.
- **The first partition's 19-bit length.** A 4x4-predicted macroblock's
  modes take about 3 bytes, so images past about 6 megapixels hold the
  modes to a budget of 15/16 of the partition: a macroblock whose row-major
  share is spent is not predicted 4x4. If the partition overflows anyway,
  the frame is encoded again with no 4x4 prediction and no segment map;
  past about 150 megapixels that can overflow too, and `encode` returns
  `ImageTooLarge`, as libwebp does.
- **One token partition.** Several partitions only help a multithreaded
  decoder; one is smallest.
- **Alpha** goes in ALPH compressed by the lossless encoder
  (`image.webp.encodeAlpha`, compression 1) at effort 0, 1, and 5 for
  `fast`, `default`, and `best`, kept only when it is smaller than the raw
  plane (compression 0), as libwebp keeps it. It is never filtered: on ten
  images with transparency, prefiltering made the lossless streams
  10-22% larger in total at every effort, since its own predictors do better, and the
  best of the four filters per image saved 0.3% at effort 5 for four
  encodes; raw alpha is the same size filtered or not. Efforts 0, 1, and
  5 gave 147,524, 138,528, and 134,951 bytes on those images (libwebp at
  -m 2, 4, and 6: 138,509, 131,943, 124,968); effort 9 gave 135,972.
  Fully opaque alpha writes no ALPH. A file with alpha or metadata is
  VP8X; otherwise it is the simple format.
- **Hidden colors are free.** A pixel whose alpha is 0 shows nothing, so
  every candidate prediction is taken as exact there (the source is
  replaced by the prediction for that mode), and a chroma sample is
  hidden when all four of its pixels are. On those ten images this made
  the default effort's files 16% smaller (277,414 to 232,200 bytes) at
  higher PSNR over the visible pixels. Opaque macroblocks run a separate
  instance of the mode search without the masks, so they cost nothing.
- **`alpha_compression`** (on by default) needs the lossless encoder's
  work memory, the plane, and its stream: `workLen` grows from about 3.2
  to 23-36 bytes per pixel at a megapixel, and 0.5-1.3 MB for an icon,
  whatever the source, since `workLen` cannot know whether the pixels
  have alpha. An RGB caller that sizes work memory tightly can turn it off.
- **Not done**, left for a later pass:
  trellis quantization, perceptual (SNS-like) tuning of quantizers and
  filter strength beyond the segments, sharp RGB to YUV, the loop filter's
  sharpness, and target-size encoding.

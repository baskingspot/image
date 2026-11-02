# WebP lossy encode: notes and decisions

`image.webp.lossy` writes one VP8 key frame (RFC 6386) in a RIFF container
(RFC 9649), written from the specifications; libwebp is the oracle and the
bar. Results: `results/webp-lossy-encode-20261102.md`, and for trellis
quantization and the speed pass, `results/webp-lossy-trellis-20261102.md`.

## Shape

- `src/webp/vp8_encode.zig`: the options, the work memory layout, mode
  decision, segments, the first partition, alpha, and the container.
- `vp8_encode_dsp.zig`: the forward DCT and WHT (16-lane vectors), the
  decoder's inverse transforms and predictors copied privately (the WebP
  orb owns `vp8.zig`), quantization with 16-lane step, reciprocal, and
  rounding vectors in zigzag order, a 4x4 Hadamard SATD (and the same
  over a strip of blocks four rows high), and SSE.
- `vp8_encode_trellis.zig`: trellis quantization, the levels of a block
  that cost least in squared error plus lambda times their bits.
- `vp8_encode_bool.zig`: the boolean encoder (`Writer`, which streams
  through a one-byte cache and a count of pending 0xff bytes for carries),
  a `Counter` that follows only the range to size a partition without
  writing it, one token walker shared by the writer and the counter, the
  tallies (a count per token, by class, turned into the tree's counts
  afterwards), and coefficient costs from the current probabilities.
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
5. The token partition is coded into the level store's spare room (its
   worst case leaves 2.7 bytes a pixel at quality 75), the first partition
   is sized by a `Counter` pass, and the file is written to the caller's
   writer. When the token partition does not fit, its length is still
   counted, and it is coded a second time straight to the output.

Work memory (`workLen`) is about 45 KiB of state, 803 bytes per
macroblock (the level store's worst case, the modes, and the activity),
and 37 bytes per pixel of width: 3.2 bytes per pixel in all. With
`alpha_compression` it adds the alpha plane, its stream (a byte a pixel
each), and the lossless encoder's work memory at the alpha effort: 30, 30,
and 40 MB at 1024×1024 for `fast`, `default`, and `best`, and 1.1 GB for
the 50-megapixel mosaic. An encode touches the state, the rows, about its
output's size in levels and again in the token partition, and the alpha
parts only when the source has alpha, so peak RSS stays below libwebp's.

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
  (all ten measured 0.3% smaller on PSNR and 0.5% on SSIM), and the
  chosen modes coded again with trellis quantization. `best`: every
  4x4 mode, trellis quantization in every choice, and two passes. Below
  `best`, a macroblock whose 16x16 choice costs under 64 bits' worth is
  not tried as 4x4: free at `fast`, 0.1% at `default`, and 4-13% faster.
- **Trellis quantization** chooses each block's levels by dynamic
  programming over its coding positions: at each, the magnitude rounded
  to nearest and one less, scored by squared error plus lambda times the
  token's bits in the context the previous level leaves, ending after any
  nonzero level. Its lambda is 10/16 of the mode decisions' in luma and
  5/16 in chroma: more made files smaller at equal PSNR and larger at
  equal SSIM (a trade, not a gain), and chroma, which PSNR over RGB
  weighs heavily, keeps more of its levels. In the mode search (`best`)
  it gains 2.5% at equal PSNR and 0.5% at equal SSIM for 35% more time;
  only for the chosen modes (`default`), 1.6% and none for 20%. Coding
  the chosen modes again after the 16x16 or 4x4 decision, rather than
  within it, measured worse than no trellis on SSIM.
- **Perceptual (SNS-like) tuning** found nothing past the segments: on
  the dev set, a loop filter level from 1/4 to 5/8 of the quantizer
  index, filter levels or lambdas that follow the segments' activity, a
  sharpness, stronger segments, and more chroma rounding each moved
  files along the PSNR-SSIM trade or lost on both.- **Segments balance PSNR and SSIM.** On the tuning images, equal
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
  (`image.webp.encodeAlpha`, compression 1) at effort 1, 1, and 8 for
  `fast`, `default`, and `best` (plan.md decision 65), kept only when it is smaller than the raw
  plane (compression 0), as libwebp keeps it. It is never filtered: on ten
  images with transparency, prefiltering made the lossless streams
  10-22% larger in total at every effort, since its own predictors do better, and the
  best of the four filters per image saved 0.3% at effort 5 for four
  encodes; raw alpha is the same size filtered or not. Efforts 0, 1, and
  5 gave 147,524, 138,528, and 134,951 bytes on those images (libwebp at
  -m 2, 4, and 6: 138,509, 131,943, 124,968); effort 9 gave 135,972.
  Since the lossless encoder stopped searching a hash chain for alpha
  (623e5e6), effort 1 writes 132,681 bytes in 115 ms and effort 8
  127,123 in 0.79 s (results/webp-encode-alpha-20261102.md).
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
  to 29-38 bytes per pixel at a megapixel, and 0.3-0.9 MB for an icon,
  whatever the source, since `workLen` cannot know whether the pixels
  have alpha. An RGB caller that sizes work memory tightly can turn it off.
- **Not done**, left for a later pass: sharp RGB to YUV, target-size
  encoding, and choosing the loop filter level by measuring it, which
  needs the reconstructed frame kept.

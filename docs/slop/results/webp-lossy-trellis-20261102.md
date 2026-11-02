# WebP lossy encode: trellis quantization and a speed pass, 2026-11-02

The second pass on `image.webp.lossy`, after
`webp-lossy-encode-20261102.md`: trellis quantization, perceptual
(SNS-like) tuning, and `fast`'s speed against `cwebp -m 0`. Same machine,
images, metrics, and method as there; docs/slop/webp-lossy-encode.md has
the design.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512, a shared cloud
host), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU, libwebp 1.6.0 from
the flake built `-O3 -march=native` through `bench/c/arm.c`.

## What changed

- **Trellis quantization** (`vp8_encode_trellis.zig`): a block's levels
  by dynamic programming over its coding positions, each the magnitude
  rounded to nearest or one less, scored by squared error plus lambda
  times the token's bits in the context the previous level leaves, and
  the block ended after any nonzero level. `default` codes each chosen
  mode again with it (the best 16x16 mode, each 4x4 block's best mode
  before the next block is predicted, the best chroma mode); `best` uses
  it in every choice. A test checks it against every combination of its
  candidates, cut off after every position, under random probabilities.
- **4x4 skipped on flat macroblocks** below `best`: a macroblock whose
  16x16 choice costs under 64 bits' worth is not tried as 4x4.
- **Token counts by class**: the main pass counts each token once, by
  class, instead of each tree node it passes, and turns the counts into
  the tree's afterwards.
- **The token partition is coded once**, into the spare room of the
  level store (sized for the worst case), and copied out, instead of
  sized by a counting pass and then coded to the output; when it does not
  fit, it is coded again straight to the output.
- **SATD over strips**: the 16x16 and chroma mode ranking takes the
  Hadamard SATD of four blocks at once, a row to a vector, with the last
  butterfly folded into the sum (|x + y| + |x − y| = 2·max(|x|, |y|)):
  2.9× faster than four 4x4 calls on a 16x16 block; the 4x4 SATD folds
  its last stage too (6%).
- **Alpha efforts** are 1, 1, and 8 for `fast`, `default`, and `best`
  (plan.md decision 65, was 0, 1, and 5), after the lossless encoder
  stopped searching a hash chain for alpha (623e5e6): on the ten images
  with transparency, effort 1 writes 132,681 bytes in 115 ms and 8
  127,123 in 0.79 s, against libwebp -m 2's 138,509 and -m 6's 124,968
  (`webp-encode-alpha-20261102.md`). `workLen` with `alpha_compression`
  is 30, 30, and 40 MB at 1024×1024 (was 24, 30, and 38).

Byte for byte, the token counts, the single coding of the token
partition, and the SATD changes write the same files as main (checked on
three images at each effort with trellis off and no 4x4 skipping).

## Rate and distortion

`run.sh` (with `encdev.zig` and `encdev-build.sh`) reruns these: the
cwebp rows of the first measurement, main's three efforts (`main-*`,
encdev built against main 77ea205), and this branch's (`ours-*`). Raw
points in `webp-lossy-trellis-20261102/rd-{dev,hold,alpha}.txt`, every
BD-rate in `bd.txt`. Negative means our files are smaller at equal
quality.

Against main, BD-rate on both sets (18 images), by set, and on the
images with transparency (PSNR over pixels whose alpha is not 0):

| effort  | both PSNR | both SSIM | dev PSNR | dev SSIM | held-out PSNR | held-out SSIM | alpha PSNR |
| ------- | --------- | --------- | -------- | -------- | ------------- | ------------- | ---------- |
| fast    | +0.1%     | +0.1%     | +0.0%    | +0.0%    | +0.1%         | +0.2%         | −3.6%      |
| default | −1.6%     | +0.2%     | −1.4%    | −0.4%    | −1.8%         | +0.7%         | −0.8%      |
| best    | −2.5%     | −0.5%     | −2.3%    | −1.0%    | −2.8%         | +0.1%         | −1.2%      |

The alpha column at `fast` is the alpha effort (1 for 0); the others mix
trellis quantization with the alpha effort (8 for 5 at `best`).

BD-rate of our efforts against each cwebp method, both sets:

| ours \ cwebp | -m 0 PSNR | SSIM   | -m 2 PSNR | SSIM   | -m 4 PSNR | SSIM  | -m 6 PSNR | SSIM  |
| ------------ | --------- | ------ | --------- | ------ | --------- | ----- | --------- | ----- |
| fast         | −17.5%    | −16.0% | −4.4%     | −1.1%  | +3.4%     | +6.5% | +6.2%     | +7.4% |
| default      | −23.2%    | −25.7% | −10.2%    | −10.9% | −2.7%     | −4.4% | −0.1%     | −3.5% |
| best         | −24.2%    | −25.7% | −11.6%    | −11.4% | −4.2%     | −5.8% | −1.6%     | −5.0% |

By set, against the method each effort is benchmarked with:

| pair            | dev PSNR | dev SSIM | held-out PSNR | held-out SSIM | alpha PSNR |
| --------------- | -------- | -------- | ------------- | ------------- | ---------- |
| fast vs -m 2    | −6.2%    | −2.2%    | −2.7%         | −0.1%         | −7.2%      |
| default vs -m 4 | −5.1%    | −5.0%    | −0.3%         | −3.9%         | −6.1%      |
| best vs -m 6    | −3.8%    | −6.4%    | +0.5%         | −3.7%         | −2.7%      |

The held-out PSNR gap at `default` against -m 4 (+1.5% before) is closed
(−0.3%), and `best` against -m 6 went from +3.2% to +0.5%.

At quality 75, total bytes and mean PSNR and SSIM over the 18 images:

| encoder      | bytes     | PSNR   | SSIM    |
| ------------ | --------- | ------ | ------- |
| cwebp -m 0   | 1,781,230 | 36.513 | 0.96333 |
| cwebp -m 2   | 1,449,290 | 36.099 | 0.96326 |
| cwebp -m 4   | 1,399,518 | 36.316 | 0.96473 |
| cwebp -m 6   | 1,344,564 | 36.157 | 0.96251 |
| main fast    | 1,511,680 | 36.469 | 0.96310 |
| main default | 1,297,806 | 36.025 | 0.96304 |
| main best    | 1,308,590 | 36.111 | 0.96364 |
| ours fast    | 1,511,586 | 36.465 | 0.96309 |
| ours default | 1,296,870 | 36.102 | 0.96255 |
| ours best    | 1,299,542 | 36.165 | 0.96308 |

On the ten images with transparency at quality 75, total bytes and mean
visible PSNR:

| encoder      | bytes   | PSNR  |
| ------------ | ------- | ----- |
| cwebp -m 2   | 265,264 | 35.32 |
| cwebp -m 4   | 248,808 | 35.30 |
| cwebp -m 6   | 237,424 | 35.09 |
| main fast    | 264,380 | 35.38 |
| main default | 226,348 | 34.91 |
| main best    | 221,498 | 34.93 |
| ours fast    | 249,580 | 35.38 |
| ours default | 224,792 | 34.99 |
| ours best    | 218,098 | 34.99 |

### Tuning

Every constant was tuned on the dev set and checked on the held-out set.
Lambdas are in 1/16 of the mode decisions' (`lambda`), BD-rates against
main's `default` on the dev set unless named:

- Trellis lambda equal to the mode decisions': +2.2% PSNR and −1.2%
  SSIM for the chosen modes only, +1.8% and −1.9% in every choice; in
  chroma alone (at 8) it was +2.0% PSNR, so chroma takes a lower one.
  With luma at 8 to 16 and chroma at 1 to 8, the points move along a
  PSNR-SSIM trade: 4x4 at 16, 16x16 at 12, and chroma at 1 gave −3.9%
  and +1.0%, luma and chroma at 8 +0.3% and −1.7%. Luma 10 and chroma 5
  in every choice gave −1.9% and −0.9% on dev, and −2.2% and 0.0% held
  out: both no worse. Trellis in the Y2 block gained 0.2%.
- Only for the chosen modes (`default`), the same lambdas gave −1.4% and
  −0.4% on dev, −1.8% and +0.7% held out; luma 8 gave −0.8%/−0.6% and
  −1.2%/+0.1%. Coding the chosen modes again after the 16x16 or 4x4
  decision instead of within it gave 0.0%/+0.9% and −0.5%/+2.3%, worse.
  Two RD tries per 4x4 block instead of three, with trellis in every
  choice, lost 0.4-0.7%.
- Perceptual tuning, each alone on top of main's `default`: the loop
  filter at 1/4 of the quantizer index (+0.0% PSNR, +0.1% SSIM), 1/2
  (+0.7%, +0.5%), and 5/8 (+1.5%, +1.2%) against 3/8; sharpness 2
  (+0.4%, +0.4%) and 5 (+0.7%, +1.0%); filter levels that follow the
  segments' activity, ±3/32 of a level per activity step (+0.2%, +1.1%
  and +0.6%, +0.2%); segment lambdas that follow it (+0.2%, +0.4% and
  +0.7%, +0.5%); segment strength 4/32 and 5/32 against 3/32 with
  trellis (+0.9% and +1.7% PSNR, SSIM unchanged) and 2/32 (−0.7% PSNR,
  +0.1% SSIM; held out −1.1% and +1.1%); chroma AC rounding at
  56/128 and 64/128 against 48 (−0.9%, +0.6% and −1.4%, +1.6%). None
  gained on both, so none was kept.
- 4x4 skipped below 64, 128, and 256 bits' worth at `fast`: +0.0%,
  +0.3%, and +1.6% PSNR; 64 at `default` +0.0% PSNR and +0.1% SSIM, at
  `best` +0.1% and +0.1% (not used there). Skipping 4x4 altogether made
  `fast` 9.6% larger at equal PSNR (11.9% at equal SSIM) for 1.25-1.5×
  its speed.

## Speed

`just bench-compare 10 webp-encode-lossy webp-encode-lossy-fast
webp-encode-lossy-best webp-encode-lossy-rgba webp-encode-lossy-fast-m0`
on this branch, and the first four rows on main 77ea205 just before it
(the same corpus, 44 images from 16×16 icons to the 50-megapixel mosaic,
quality 75, all pinned to the last core). The new row
`webp-encode-lossy-fast-m0` times our `fast` against libwebp's method 0.
A ratio is our throughput over libwebp's on the same run (above 1, ours
is faster), the geometric mean over rows of each row's median paired
ratio.

| row, class              | main MP/s | main vs libwebp | branch MP/s | branch vs libwebp | slowest row now      |
| ----------------------- | --------- | --------------- | ----------- | ----------------- | -------------------- |
| default, icons          | 5.8       | 1.15            | 4.9         | 0.96              | 0.90 (32×32 icon)    |
| default, to 1 MP        | 17.1      | 1.42            | 15.6        | 1.28              | 0.92 (kodim01)       |
| default, over 1 MP      | 18.4      | 1.46            | 17.6        | 1.38              | 1.06 (Wikipedia 001) |
| fast, icons             | 8.1       | 1.23            | 9.0         | 1.34              | 0.98 (16×16 icon)    |
| fast, to 1 MP           | 31.9      | 1.11            | 42.3        | 1.47              | 1.24 (kodim02)       |
| fast, over 1 MP         | 34.6      | 1.11            | 47.2        | 1.53              | 1.32 (Wikipedia 001) |
| best, icons             | 2.5       | 1.08            | 1.3         | 0.57              | 0.49 (16×16 icon)    |
| best, to 1 MP           | 6.8       | 1.03            | 4.2         | 0.62              | 0.56 (kodim23)       |
| best, over 1 MP         | 7.4       | 1.00            | 4.7         | 0.64              | 0.59 (Wikipedia 001) |
| RGBA, icons             | 3.1       | 1.62            | 2.7         | 1.43              | 0.96 (64×64 texture) |
| RGBA, to 1 MP           | 13.0      | 1.51            | 12.0        | 1.37              | 0.92 (kodim01)       |
| RGBA, over 1 MP         | 17.0      | 1.41            | 16.5        | 1.36              | 1.07 (Wikipedia 001) |
| fast vs -m 0, icons     | -         | -               | 9.0         | 1.28              | 0.94 (16×16 icon)    |
| fast vs -m 0, to 1 MP   | -         | -               | 42.4        | 0.91              | 0.73 (Wikipedia 002) |
| fast vs -m 0, over 1 MP | -         | -               | 47.6        | 0.92              | 0.79 (Wikipedia 001) |

- `fast` is 1.33-1.36× main's speed from a megapixel down to icons'
  size (1.11× on icons), for the same files: now at 0.91-0.92 of
  libwebp's method 0 over icons' size (1.28 on icons), against about
  0.7 before, with files 17% smaller (0.829 of -m 0's bytes at quality
  75, and −17.5% BD-rate on PSNR). Of the gain, coding the token
  partition once is about 12%, counting tokens by class 7%, skipping 4x4
  on flat macroblocks 4-8%, and SATD over strips 4-8% (encdev on three
  images).
- `default` pays for trellis quantization with 4-9% of its speed from a
  megapixel down, and 16% on icons, where it now runs at 0.96 of libwebp
  -m 4: icons are dense, so trellis runs on more nonzero coefficients.
  Without trellis, the speed changes alone make it 9-18% faster than
  main (encdev).
- `best` takes 1.6× main's time: trellis in every choice is 35%, and
  every macroblock still tries 4x4. It is now 0.57-0.64 of libwebp -m 6,
  which also uses trellis in every choice, for files 1.6% smaller at
  equal PSNR and 5.0% at equal SSIM.
- RGBA: alpha at effort 1 is what main used at `default`, so the row
  moves with `default` (0.87-0.97 of main).

Sizes at quality 75, total bytes over each row against libwebp's (main
in brackets): default 0.944 of -m 4's (0.955), fast 0.964 of -m 2's
(0.964) and 0.829 of -m 0's, best 0.960 of -m 6's (0.986), RGBA 0.942 of
-m 4's (0.953).

**Peak RSS** (MiB, GNU time over each class's inputs, `rss.txt` and
`rss-main.txt`): within 1.6 MiB of main in every class (the token
partition now lands in the level store's spare room), and below
libwebp's everywhere but RGBA to 1 MP (30.4 against 30.1, as before):

| row     | icons main / now / libwebp | to 1 MP            | over 1 MP             |
| ------- | -------------------------- | ------------------ | --------------------- |
| default | 2.8 / 2.9 / 3.5            | 10.2 / 10.3 / 13.9 | 347.5 / 348.8 / 446.1 |
| fast    | 2.8 / 2.9 / 3.5            | 10.2 / 10.4 / 12.0 | 348.2 / 349.8 / 417.1 |
| best    | 2.8 / 2.9 / 3.5            | 10.2 / 10.3 / 13.8 | 347.5 / 348.2 / 446.1 |
| RGBA    | 3.3 / 3.4 / 4.6            | 30.4 / 30.4 / 30.1 | 395.4 / 396.7 / 494.1 |

Raw output in `webp-lossy-trellis-20261102/`: `summary.txt` and
`summary-main.txt`, `rows.txt`, `benchstat.txt` (ours against libwebp),
`benchstat-main-vs-branch.txt` (our arm, main against this branch),
`raw-image.txt`, `raw-libwebp.txt`, their `-main` copies, `rss.txt`,
`rss-main.txt`, and `config.txt`.

## Where each effort stands

- `fast` (against -m 2): 4.4% smaller at equal PSNR, 1.1% at equal SSIM,
  1.34-1.53× its speed; against -m 0, 17.5% and 16.0% smaller at
  0.91-0.92 of its speed (1.28 on icons).
- `default` (against -m 4): 2.7% smaller at equal PSNR and 4.4% at equal
  SSIM (held out: 0.3% and 3.9%), 1.28-1.38× its speed from icons' size
  up, 0.96 on icons.
- `best` (against -m 6): 1.6% and 5.0% smaller (held out: 0.5% larger on
  PSNR, 3.7% smaller on SSIM), at 0.57-0.64 of its speed.

## Recommendation

Keep quality 75 at `default` (decisions 54-55). With trellis it closes
the held-out PSNR gap to -m 4 and stays 1.28-1.38× libwebp's speed, but
icons drop to 0.96. If icon speed must stay above libwebp's, `default`
can leave trellis to `best`: 9-18% faster than main for main's files.
`best` is now slower than -m 6; trellis only for the chosen modes there
too would bring it back near main's speed for about half its gain
(measured at `default`: 1.6% against 2.5%).

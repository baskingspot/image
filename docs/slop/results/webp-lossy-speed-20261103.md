# WebP lossy encode: icon speed, and `best`'s first pass

The lossy encoder (`src/webp/vp8_encode*.zig`) after trellis quantization
(`webp-lossy-trellis-20261102.md`) ran at 0.95 of libwebp -m 4 on icons
at `default`, and `best` ran at 0.57-0.64 of -m 6. Plan decisions 72-73
keep trellis at `default` and in every mode choice at `best`; this pass
makes both faster within them.

CPU: Intel Xeon @ 2.60 GHz (4 threads), Zig 0.16 ReleaseFast native,
libwebp via `cc -O3 -march=native`, everything pinned to the last core.

## What changed

1. **Token costs from class paths** (same output). `Costs.init` walked
   the token tree for each of 68 magnitudes in each of 96 contexts, 49%
   of a 16×16 encode at `default`. A token's cost is its class's path
   through the tree, which the probabilities set, plus its bits at fixed
   probabilities (category extra bits and the sign), which they do not.
   Now the 11 paths are added up per context, spread over the 68
   magnitudes by a vector shuffle, and added to a constant table.
2. **Each partition coded once** (same output). The first partition was
   sized by a `Counter` pass and then written; it is now coded into the
   level store's spare room after the token partition and copied out,
   as the token partition already was. `Writer` counts its bytes even
   past a full output, so a partition that does not fit still has its
   length, and it is coded again straight to the output. `Counter` is
   gone. The fallback was checked by forcing it: the same bytes on 45
   encodes.
3. **The token histograms zeroed with vector stores** (same output).
   Without libc, `memset` is compiler_rt's, which stores a byte at a time
   (`lib/zig/compiler_rt.zig`, `memset`): the two 9 KiB histograms each
   pass took 7% of a 16×16 encode.
4. **`best`'s first pass searches as `default` does** (different
   output). It only sets the token costs that the coding pass estimates
   rates with, and the coding pass still uses trellis in every choice
   (decision 73). It takes about a quarter of the time a `best` pass
   takes.

Encdev on three icons (RGB, best of 3000, MP/s; main, then after each
step):

| effort  | image | main | 1    | 2    | 3     |
| ------- | ----- | ---- | ---- | ---- | ----- |
| default | 16×16 | 2.67 | 4.93 | 5.41 | 5.80  |
| default | 32×32 | 5.60 | 7.35 | 7.71 | 7.88  |
| default | 64×64 | 7.84 | 8.59 | 8.89 | 8.76  |
| fast    | 16×16 | 3.41 | 8.20 | 9.51 | 10.88 |
| fast    | 64×64 | 21.3 | 27.8 | 29.5 | 30.2  |

## Rate and distortion

Only `best` writes different files. BD-rate (`bd.txt`, `rd-*.txt`; the
sets, qualities, and metrics of `webp-lossy-encode-20261102.md`;
negative is smaller at equal quality):

| `best` against | dev + held out | dev          | held out     | alpha (PSNR) |
| -------------- | -------------- | ------------ | ------------ | ------------ |
| main's `best`  | −0.0% / −0.0%  | +0.0 / +0.1% | −0.1 / −0.2% | −0.1%        |
| cwebp -m 6     | −1.7% / −4.8%  | −3.7 / −5.8% | +0.4 / −3.9% | −3.0%        |

(PSNR / SSIM.) A first pass at `fast`'s search instead measured +0.3% /
+0.1% on the dev set against main's `best`, for about 13% more speed;
not taken.

## Speed

`just bench-compare 10 webp-encode-lossy webp-encode-lossy-fast
webp-encode-lossy-best webp-encode-lossy-rgba webp-encode-lossy-fast-m0`
on main 93289ad (in a worktree), then on this branch, back to back on
the same orb. A ratio is our throughput over libwebp's on the same run,
the geometric mean over a class's rows of each row's median paired
ratio.

| row, class              | main MP/s | main vs libwebp | branch MP/s | branch vs libwebp | slowest row now      |
| ----------------------- | --------- | --------------- | ----------- | ----------------- | -------------------- |
| default, icons          | 4.9       | 0.95            | 7.4         | 1.44              | 1.06 (64×64 icon)    |
| default, to 1 MP        | 15.5      | 1.28            | 15.9        | 1.30              | 0.94 (kodim01)       |
| default, over 1 MP      | 17.5      | 1.38            | 17.9        | 1.40              | 1.10 (Wikipedia 001) |
| fast, icons             | 8.8       | 1.33            | 18.3        | 2.74              | 2.01 (64×64 icon)    |
| fast, to 1 MP           | 42.1      | 1.48            | 44.0        | 1.53              | 1.27 (kodim01)       |
| fast, over 1 MP         | 47.5      | 1.53            | 48.7        | 1.55              | 1.33 (Wikipedia 001) |
| best, icons             | 1.3       | 0.57            | 2.3         | 0.97              | 0.81 (64×64 icon)    |
| best, to 1 MP           | 4.1       | 0.62            | 5.6         | 0.83              | 0.75 (kodim23)       |
| best, over 1 MP         | 4.7       | 0.64            | 6.3         | 0.85              | 0.79 (50 MP mosaic)  |
| RGBA, icons             | 2.8       | 1.44            | 3.4         | 1.76              | 1.10 (64×64 texture) |
| RGBA, to 1 MP           | 12.0      | 1.37            | 12.2        | 1.39              | 0.92 (kodim01)       |
| RGBA, over 1 MP         | 16.5      | 1.36            | 16.8        | 1.38              | 1.08 (Wikipedia 001) |
| fast vs -m 0, icons     | 8.9       | 1.28            | 18.3        | 2.61              | 1.94 (64×64 icon)    |
| fast vs -m 0, to 1 MP   | 42.6      | 0.91            | 44.1        | 0.94              | 0.75 (Wikipedia 002) |
| fast vs -m 0, over 1 MP | 48.3      | 0.92            | 49.0        | 0.93              | 0.79 (Wikipedia 001) |

- Icons: a 16×16 icon at `default` takes 48 µs, against 106 µs on main
  (`benchstat-main-vs-branch.txt`: −55%), and `fast` 26 µs against 82
  (−69%). The fixed costs were the cost tables, the first partition's
  extra pass, and byte-wise zeroing; what is left of a 16×16 encode is
  mostly the macroblock itself, then the frame header's 1,056
  probability-update flags (10%) and turning token counts into
  probabilities (10%).
- `best` is 1.3-1.8× main's speed (−31% time on kodim01): 0.83-0.97 of
  libwebp -m 6, for files 1.7% smaller at equal PSNR and 4.8% at equal
  SSIM. Trellis quantization is still about half of its time; making
  the dynamic program skip positions whose candidates are both zero
  measured 7% slower (branches it cannot predict) and was dropped.
- Above icon size, every row gains 1-5% from the cheaper setup; the
  geometric mean over all 220 rows is 19% less time.

**Peak RSS** (MiB, `rss.txt` and `rss-main.txt`): unchanged in every
class (within 0.2 MiB), and below libwebp's everywhere but RGBA to 1 MP
(30.4 against 30.1, as before).

Raw output in `webp-lossy-speed-20261103/`: `summary.txt` and
`summary-main.txt`, `rows.txt`, `benchstat.txt` (ours against libwebp),
`benchstat-main-vs-branch.txt` (our arm, main against this branch),
`raw-image.txt`, `raw-libwebp.txt`, their `-main` copies, `rss.txt`,
`rss-main.txt`, `config.txt`, and for the rate-distortion runs `run.sh`,
`encdev.zig`, `encdev-build.sh`, `rd-*.txt`, and `bd.txt`.

## Where each effort stands

- `fast`: 1.53-1.55× libwebp -m 2 from 1 MP up and 2.74× on icons;
  against -m 0, 0.93-0.94 from 1 MP up and 2.61× on icons, for files
  17.5% smaller at equal PSNR.
- `default`: 1.30-1.44× libwebp -m 4 in every class, for files 2.7%
  smaller at equal PSNR and 4.4% at equal SSIM.
- `best`: 0.83-0.97 of libwebp -m 6, for files 1.7% and 4.8% smaller.

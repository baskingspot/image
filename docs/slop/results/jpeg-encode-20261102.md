# JPEG encode against libjpeg-turbo and mozjpeg, 2026-11-02

`image.jpeg.encode` (wave 5) against libjpeg-turbo 3.2.0, the speed bar and
the oracle, and stb_image_write, Rust's `image` (`JpegEncoder`), and Go's
`image/jpeg`; mozjpeg 4.1.5, the size bar for decision 3, measured out of
tree because the flake does not provide it. Every arm encodes raw pixels
from memory per call (bench/ops.tsv): `jpeg-encode` (quality 85, 4:2:0,
standard tables), `jpeg-encode-444` (quality 95, 4:4:4, where stb stops
subsampling), `jpeg-encode-optimized` (quality 85, 4:2:0, optimized
tables), `jpeg-encode-progressive` (quality 85, 4:2:0, libjpeg's default
script), and `jpeg-encode-gray` (quality 85, one component). libjpeg-turbo
(libjpeg API, islow forward DCT, SIMD on) writes the same bytes as this
package on all 220 rows; stb, `image`, and Go use their own tables,
rounding, or subsampling and differ on every row, so the operations are
marked `own`. `image`'s encoder cannot subsample, so its 4:2:0 rows are
4:4:4; Go always subsamples to 4:2:0, so it has no 4:4:4 row, and neither
stb, `image`, nor Go has optimized or progressive rows. Throughput is
megapixels per second; a ratio is this package's throughput over the arm's
(above 1, ours is faster), the geometric mean over rows of each row's
median paired ratio over 10 rounds. docs/slop/jpeg.md, "Encoding", has the
design.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host whose rows swing by ±10% between rounds, so only paired ratios are
steady), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU; C arms `cc -O3
-march=native`, Rust `target-cpu=native`, Go `GOAMD64=v3`. Inputs:
`bench/corpus-gen/netpbm/raw-rgb8/` and `raw-gray8/`, 44 images per
operation (the QOI benchmark suite's icons, photos, screenshots, and
textures, 16 and 32 pixel icons, and the 50-megapixel mosaic). Raw output
in `jpeg-encode-20261102/`: `summary.txt`, `rows.txt`, `benchstat.txt`,
`raw-*.txt`, `rss.txt`, `sizes.md`, and the decision-3 scripts and output.

## Speed

| operation, rows (count)   | image MP/s | vs libjpeg-turbo | vs stb | vs `image` | vs Go |
| ------------------------- | ---------- | ---------------- | ------ | ---------- | ----- |
| baseline, icons (13)      | 194.3      | 6.43             | 1.86   | 3.26       | 4.31  |
| baseline, to 1 MP (23)    | 445.4      | 1.07             | 5.04   | 6.00       | 9.04  |
| baseline, over 1 MP (8)   | 396.5      | 0.93             | 4.80   | 5.24       | 8.28  |
| 4:4:4, icons (13)         | 131.3      | 4.93             | 2.58   | 2.64       | -     |
| 4:4:4, to 1 MP (23)       | 246.4      | 1.06             | 4.97   | 3.84       | -     |
| 4:4:4, over 1 MP (8)      | 236.2      | 0.98             | 4.99   | 3.64       | -     |
| optimized, icons (13)     | 73.7       | 2.87             | -      | -          | -     |
| optimized, to 1 MP (23)   | 319.3      | 1.67             | -      | -          | -     |
| optimized, over 1 MP (8)  | 286.9      | 1.51             | -      | -          | -     |
| progressive, icons (13)   | 39.6       | 2.32             | -      | -          | -     |
| progressive, to 1 MP (23) | 130.8      | 1.70             | -      | -          | -     |
| progressive, over 1 MP    | 126.3      | 1.55             | -      | -          | -     |
| gray, icons (13)          | 304.4      | 9.11             | 2.71   | 2.14       | 3.51  |
| gray, to 1 MP (23)        | 758.6      | 1.29             | 7.95   | 4.29       | 7.64  |
| gray, over 1 MP (8)       | 711.3      | 1.09             | 7.94   | 4.00       | 7.22  |
| all (220)                 | 236.2      | 1.87             | 4.45   | 3.86       | 6.55  |

Below libjpeg-turbo: baseline color over a megapixel. 30 of the 220 rows
have a median below 1 against it, and on 7 the whole interval is below 1,
all baseline photos and screenshots of 0.4 MP and more (0.88-0.99×: the
Apple and CNN screenshots, kodim01, Tecnick 001, and Wikipedia 008). There
the entropy coder is about half the time, the DCT a quarter, and color
conversion and downsampling the rest (rdtsc around each stage on a 1 MP
photo). Packing each symbol's code and length into one word measured no
faster. We have not profiled libjpeg-turbo, so where its lead there comes
from is open. Optimized and progressive files are 1.5-2.9× faster: our
symbol-counting pass and progressive AC scans visit only the nonzero
coefficients, through a zigzag bit mask. Icons are 2-9× faster, likely
libjpeg-turbo's per-image compressor setup (not profiled).

How the hot paths got there, each A/B on one core of this machine (1 MP
photo, quality 85; libjpeg-turbo in the same runs):

| change                                                                                 | before                                     | after        |
| -------------------------------------------------------------------------------------- | ------------------------------------------ | ------------ |
| color conversion: 48-lane shuffle → in-half `pshufb` + `pmaddwd`, `vpermd` kept as asm | sample stage 2,078 kcycles                 | 941-1,055    |
| baseline overall from that                                                             | 0.81× libjpeg-turbo (4:2:0), 0.87× (4:4:4) | 0.94×, 0.99× |
| Huffman zero runs: `ctz` + two shifts → `mask & (mask - 1)`                            | 3,382 kcycles                              | 3,012        |
| progressive AC scans over a zigzag mask                                                | 0.80× libjpeg-turbo                        | 1.46×        |
| optimal tables: only used tables, used symbols, counting sort (16×16)                  | 0.07× (progressive), 0.61× (optimized)     | 1.71×, 3.09× |

**Peak RSS** (GNU time, one pass over each size class's inputs; the inputs
and output buffers every arm holds alike, plus the library's own memory),
MiB:

| operation, class    | image | libjpeg-turbo | stb   | `image` | Go    |
| ------------------- | ----- | ------------- | ----- | ------- | ----- |
| baseline, icons     | 2.4   | 3.1           | 2.5   | 3.5     | 3.6   |
| baseline, to 1 MP   | 9.4   | 10.0          | 9.3   | 10.4    | 79.8  |
| baseline, over 1 MP | 338.9 | 339.0         | 338.2 | 338.6   | 852.9 |
| 4:4:4, icons        | 2.4   | 3.0           | 2.6   | 3.5     | -     |
| 4:4:4, to 1 MP      | 9.4   | 9.9           | 9.4   | 10.2    | -     |
| 4:4:4, over 1 MP    | 338.7 | 339.1         | 338.2 | 338.7   | -     |
| optimized, icons    | 2.4   | 3.0           | -     | -       | -     |
| optimized, to 1 MP  | 12.4  | 12.9          | -     | -       | -     |
| optimized, over     | 482.5 | 483.2         | -     | -       | -     |
| progressive, icons  | 2.4   | 3.0           | -     | -       | -     |
| progressive, 1 MP   | 12.4  | 12.9          | -     | -       | -     |
| progressive, over   | 482.5 | 483.1         | -     | -       | -     |
| gray, icons         | 2.4   | 3.0           | 2.5   | 3.4     | 3.6   |
| gray, to 1 MP       | 7.3   | 7.9           | 7.3   | 8.2     | 50.4  |
| gray, over 1 MP     | 242.3 | 242.7         | 242.1 | 242.7   | 443.2 |

The 50-megapixel mosaic's 151 MB of input and its output dominate the
large class. Optimized and progressive files keep every quantized
coefficient (2 bytes a sample, about 144 MiB for the mosaic at 4:2:0), as
libjpeg-turbo does; a baseline file with standard tables keeps one MCU
row.

## Size

At the same settings our files are libjpeg-turbo's, byte for byte. Total
bytes over each class, as a ratio to ours (`jpeg-encode-20261102/sizes.md`;
each arm at its own nominal quality 85, or 95 for 4:4:4, which are
different tables, so this is not a quality comparison):

| operation, class | image bytes | libjpeg-turbo | stb   | `image` | Go    |
| ---------------- | ----------- | ------------- | ----- | ------- | ----- |
| baseline, all    | 10,158,765  | 1.000         | 0.991 | 1.200   | 1.000 |
| 4:4:4, all       | 22,725,975  | 1.000         | 0.977 | 0.970   | -     |
| optimized, all   | 9,915,183   | 1.000         | -     | -       | -     |
| progressive, all | 9,602,795   | 1.000         | -     | -       | -     |
| gray, all        | 8,997,752   | 1.000         | 1.040 | 0.978   | 1.000 |

Go writes the same tables at 4:2:0, so its baseline files match ours in
size; `image`'s 4:2:0 row is 4:4:4, hence 20% larger.

## Decision 3: trellis quantization (mozjpeg)

mozjpeg 4.1.5 from nixpkgs, through `mozt.c` (libjpeg API, in memory):
`plain` is `JCP_FASTEST`, which wrote libjpeg-turbo's bytes in a check;
`trellis` is `JCP_FASTEST` with `JBOOLEAN_TRELLIS_QUANT` and
`JBOOLEAN_TRELLIS_QUANT_DC`, so the standard tables and the same Huffman
optimization as ours isolate trellis; `max` is mozjpeg's default profile
(progressive with scan optimization, trellis, its own quantization
tables, deringing). Fifteen images from the benchmark corpus (Kodak 1-3,
Tecnick 1-2, Wikipedia 1-3 and 8, the 50 MP mosaic, the Amazon, Apple, and
CNN screenshots, dice, and a plant texture), 4:2:0. Our size at mozjpeg's
quality comes from our curve over quality 30-100 (log size interpolated
at equal metric): trellis against our optimized baseline, `max` against
our progressive.

| quality | trellis, same q: size | PSNR     | trellis at equal PSNR | `max` at equal PSNR |
| ------- | --------------------- | -------- | --------------------- | ------------------- |
| 75      | -11.6%                | -1.00 dB | +1.9%                 | -6.1%               |
| 85      | -10.2%                | -0.84 dB | +0.6%                 | -3.1%               |
| 95      | -7.5%                 | -0.41 dB | +0.6%                 | -2.2%               |

At equal SSIM (ImageMagick's, RGB; 10 of the images at q85): trellis
-6.6% against our optimized baseline, `max` -12.2% against our
progressive. So trellis buys no PSNR at all (it trades it for rate), and
what it buys is structural: 6-7% by SSIM alone, 12% with mozjpeg's tables
and scan search. Speed on the 1 MP photo, best of 3: trellis 19.7 MP/s
against our optimized baseline's 279 (14× slower); `max` 12.3 MP/s against
our progressive's 103 (8.4×); mozjpeg `plain` progressive 60.6.

## Commands

```
just bench-compare 10 jpeg-encode jpeg-encode-444 jpeg-encode-optimized jpeg-encode-progressive jpeg-encode-gray
nix build nixpkgs#mozjpeg   # out of tree; cc mozt.c -ljpeg against it
python3 decision3-psnr.py; python3 decision3-ssim.py
```

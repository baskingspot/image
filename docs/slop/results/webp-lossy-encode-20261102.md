# WebP lossy encode against libwebp, 2026-11-02

`image.webp.lossy` (wave 5) against libwebp 1.6.0's encoder, the bar for
size at equal quality and for speed. Rust's `image` 0.25.9 encodes WebP
only lossless (`WebPEncoder::new_lossless`) and Go's `golang.org/x/image/webp`
only decodes, so libwebp is the only arm. docs/slop/webp-lossy-encode.md
has the design.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512, a shared cloud
host), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU, libwebp from the
flake built `-O3 -march=native` through `bench/c/arm.c`.

## Rate and distortion

Each image at quality 10, 20, 30, 40, 50, 60, 70, 75, 80, 85, 90, and 95:
`cwebp -q Q -m M` at methods 0, 2, 4 (cwebp's default), and 6, and our
three efforts. Each file is decoded by our decoder (bit-exact with
libwebp) and measured against its source: PSNR over RGB, and SSIM over
BT.601 luma (11×11 Gaussian window, σ 1.5). A BD-rate is the mean
difference in log size at equal quality over the range both curves
cover, per image, then averaged; negative means our files are smaller.
SSIM is taken as −10·log10(1 − SSIM). The constants (lambda, rounding,
segment strength, filter level, pruning) were tuned on the dev set and
then checked on the held-out set, which they had not seen.

- dev: Kodak 1-3 and 23, Wikipedia 001, the Apple screenshot (6.2 MP),
  20XX_Menu_picture, testcard, and the _pkf_water1 texture.
- held out: Kodak 10, Wikipedia 002, 003, and 008, Tecnick 001 and 002,
  3dbrick2, 3dcursedlabyrinth, and the CNN screenshot (6.9 MP).

BD-rate of our efforts against each cwebp method, both sets (18 images):

| ours \ cwebp | -m 0 PSNR | SSIM   | -m 2 PSNR | SSIM   | -m 4 PSNR | SSIM  | -m 6 PSNR | SSIM  |
| ------------ | --------- | ------ | --------- | ------ | --------- | ----- | --------- | ----- |
| fast         | −17.6%    | −16.8% | −4.5%     | −1.2%  | +3.3%     | +6.4% | +6.1%     | +7.3% |
| default      | −22.0%    | −25.8% | −8.7%     | −11.1% | −1.1%     | −4.6% | +1.5%     | −3.7% |
| best         | −22.5%    | −26.3% | −9.4%     | −11.2% | −1.8%     | −5.4% | +0.8%     | −4.3% |

By set, against the method each effort is benchmarked with:

| pair            | dev PSNR | dev SSIM | held-out PSNR | held-out SSIM |
| --------------- | -------- | -------- | ------------- | ------------- |
| fast vs -m 2    | −6.2%    | −2.3%    | −2.7%         | −0.2%         |
| default vs -m 4 | −3.8%    | −4.7%    | +1.5%         | −4.5%         |
| best vs -m 6    | −1.7%    | −4.8%    | +3.2%         | −3.8%         |

For scale, cwebp's own methods against -m 4 over both sets: -m 0
+26.0% / +29.1%, -m 2 +8.3% / +7.7%, -m 6 −2.6% / −1.0%.

The dev set flatters us on PSNR, mostly through testcard (−15.2% against
-m 4); on held-out photos our PSNR is 0.3-6.5% worse than -m 4 and our
SSIM 0.9-9.9% better, except 3dbrick2 (+3.9% / +3.7%). Our segments trade
PSNR for SSIM, as cwebp's SNS does; equal quantizers measured 5.2% better
on PSNR and 3.1% worse on SSIM than -m 4 on the dev set.

At quality 75, the quality maps to cwebp's quantizer, so sizes are close
(18 images, total bytes, mean PSNR and SSIM):

| encoder      | bytes     | PSNR   | SSIM    |
| ------------ | --------- | ------ | ------- |
| cwebp -m 0   | 1,781,230 | 36.513 | 0.96333 |
| cwebp -m 2   | 1,449,290 | 36.099 | 0.96326 |
| cwebp -m 4   | 1,399,518 | 36.316 | 0.96473 |
| cwebp -m 6   | 1,344,564 | 36.157 | 0.96251 |
| ours fast    | 1,511,680 | 36.469 | 0.96310 |
| ours default | 1,297,806 | 36.025 | 0.96304 |
| ours best    | 1,308,590 | 36.111 | 0.96364 |

Raw points: `webp-lossy-encode-20261102/rd-dev.txt` and `rd-hold.txt`
(label, image, quality, bytes, PSNR, SSIM). `run.sh` reruns them with
`rd.sh` and `bd.py`; `encdev.zig` is the encoder and metric driver
(`encdev-build.sh` builds it against this checkout).

## Alpha

Alpha goes in ALPH compressed by the lossless encoder
(`image.webp.encodeAlpha`, landed in c46fc33) at effort 0, 1, and 5 for
`fast`, `default`, and `best`, unfiltered, raw when that is no larger;
pixels whose alpha is 0 cost nothing in the color encoding
(webp-lossy-encode.md, "Decisions"). Ten images with transparency (the
three pngimg images, dice, qoi_logo, testcard_rgba, both plant textures,
and two icons at 512 and 64 pixels), PSNR over the pixels whose alpha is
not 0 (SSIM, over every pixel, says nothing here), `SET=alpha run.sh`,
`rd-alpha.txt`:

| pair            | BD-rate, visible PSNR |
| --------------- | --------------------- |
| fast vs -m 2    | −3.2%                 |
| default vs -m 4 | −3.6%                 |
| best vs -m 6    | +0.3%                 |

At quality 75, total bytes and mean visible PSNR: cwebp -m 2 265,264 at
35.32 dB, -m 4 248,808 at 35.30, -m 6 237,424 at 35.09; ours `fast`
264,380 at 35.39, `default` 232,200 at 34.91, `best` 228,664 at 34.93.
Of that, the ALPH chunks alone at our efforts 0, 1, and 5 are 147,524,
138,528, and 134,951 bytes, against libwebp's 138,509, 131,943, and
124,968 at -m 2, 4, and 6. Before hidden colors were free, `default`
wrote 277,414 bytes at 34.35 dB; with alpha raw, the bench's RGBA files
were 2.07× libwebp's.

Prefiltering the plane before the lossless encoder, total stream bytes on
the ten images (`encdev alpha`):

| effort | none    | horizontal | vertical | gradient | best per image |
| ------ | ------- | ---------- | -------- | -------- | -------------- |
| 0      | 147,524 | 162,145    | 164,475  | 165,451  | 139,471        |
| 1      | 138,528 | 157,548    | 162,959  | 166,810  | 137,846        |
| 5      | 134,951 | 155,122    | 160,370  | 164,152  | 134,506        |
| 9      | 135,972 | -          | -        | -        | 135,521        |

Effort 1 takes 5.4× effort 0's time on the planes (313 ms against 58
ms for 4.1 MP), effort 5 8.6×.

## Speed

`just bench-compare 10 webp-encode-lossy webp-encode-lossy-fast
webp-encode-lossy-best webp-encode-lossy-rgba`: every arm encodes raw
pixels from memory per call at quality 75 (bench/ops.tsv). The RGB rows
read `bench/corpus-gen/netpbm/raw-rgb8/` (44 images: the QOI benchmark
suite's icons, photos, screenshots, and textures, 16 and 32 pixel icons,
and the 50-megapixel mosaic); the RGBA row reads `tga/rgba/`, the same
images with their alpha where they have it. Each of our efforts is timed
against the libwebp method nearest it in rate and distortion: `fast`
against -m 2, `default` and the RGBA row against -m 4, `best` against
-m 6. A ratio is our throughput over libwebp's (above 1, ours is faster),
the geometric mean over rows of each row's median paired ratio over 10
rounds, all pinned to the last core.

| operation, class (rows)     | image MP/s | vs libwebp | slowest row           |
| --------------------------- | ---------- | ---------- | --------------------- |
| default vs -m 4, icons (13) | 6.0        | 1.15       | 1.08 (32×32 icon)     |
| default, to 1 MP (23)       | 17.4       | 1.42       | 1.19 (kodim01)        |
| default, over 1 MP (8)      | 18.8       | 1.46       | 1.28 (Wikipedia 001)  |
| fast vs -m 2, icons (13)    | 8.3        | 1.22       | 0.97 (16×16 icon)     |
| fast, to 1 MP (23)          | 32.3       | 1.10       | 0.94 (kodim01)        |
| fast, over 1 MP (8)         | 35.0       | 1.10       | 1.00 (Wikipedia 001)  |
| best vs -m 6, icons (13)    | 2.6        | 1.08       | 0.73 (16×16 icon)     |
| best, to 1 MP (23)          | 6.9        | 1.02       | 0.88 (kodim23)        |
| best, over 1 MP (8)         | 7.5        | 1.00       | 0.79 (Tecnick 002)    |
| RGBA vs -m 4, icons (13)    | 2.9        | 1.51       | 1.25 (64×64 texture)  |
| RGBA, to 1 MP (23)          | 11.1       | 1.25       | 0.75 (academy_awards) |
| RGBA, over 1 MP (8)         | 16.5       | 1.34       | 0.80 (plant_02)       |
| all (176)                   | 10.5       | 1.21       |                       |

Sizes at quality 75, total bytes over each row as a fraction of
libwebp's: default 0.955 of -m 4's, fast 0.964 of -m 2's, best 0.986 of
-m 6's, and RGBA 0.954 of -m 4's. The RGBA rows below 1 are images with
much transparency (academy_awards, plant_02, air_pump), where the
lossless encoder at effort 1 compresses the alpha more slowly than
libwebp does; the row's images without alpha run as the default row's.
A first run with alpha stored raw had the RGBA row at 1.44-2.90×
libwebp's speed for files 2.07× its size.

cwebp's method 0, timed by `cwebp -v` on Wikipedia 001 (1.08 MP), runs at
about 45 MP/s, 1.3× our `fast`, with files about 20% larger than
`fast`'s at equal quality.

**Peak RSS** (GNU time, one pass over each size class's inputs; the inputs
and output buffers both arms hold alike, plus the library's own memory),
MiB:

| operation | class  | image | libwebp |
| --------- | ------ | ----- | ------- |
| default   | icons  | 2.6   | 3.5     |
| default   | ≤ 1 MP | 10.0  | 13.9    |
| default   | > 1 MP | 347.3 | 446.1   |
| fast      | icons  | 2.6   | 3.5     |
| fast      | ≤ 1 MP | 10.0  | 12.0    |
| fast      | > 1 MP | 348.1 | 417.1   |
| best      | icons  | 2.6   | 3.5     |
| best      | ≤ 1 MP | 10.0  | 13.8    |
| best      | > 1 MP | 347.3 | 446.1   |
| RGBA      | icons  | 3.2   | 4.6     |
| RGBA      | ≤ 1 MP | 31.0  | 30.1    |
| RGBA      | > 1 MP | 395.3 | 494.1   |

The mosaic's 151 MB of input and its output dominate the large class.
The RGBA rows touch the lossless encoder's work memory for the alpha,
which puts the mid-size class 0.9 MiB above libwebp; the bench asks for
that memory only for RGBA input (`alpha_compression = format == .rgba8`),
as a caller that knows its pixels would.

Raw output in `webp-lossy-encode-20261102/`: `summary.txt`, `rows.txt`,
`benchstat.txt`, `raw-image.txt`, `raw-libwebp.txt`, `rss.txt`, and
`config.txt`.

## The first partition on large images

The first run of the bench failed the mosaic at `default`: its modes took
528,495 bytes, past the first partition's 19-bit length, and the encoder
returned `ImageTooLarge`. The modes are now held to a budget past about 6
megapixels (webp-lossy-encode.md, "Decisions"), and the mosaic encodes in
one pass at 17.5 MP/s (`encdev`, best of one) to 1,835,052 bytes at 39.33
dB PSNR, against cwebp -m 4's 1,864,128 bytes at 39.11 dB. Images under
the budget's threshold write the same bytes as before it; the apple
screenshot (6.2 MP) is past it and unchanged too.

## Recommendation

Quality 75 at `default`, as cwebp's own default (`-q 75 -m 4`): 1.42-1.46×
libwebp's speed from icons' size up (1.15× on icons), files 1.1% smaller
at equal PSNR and 4.6% smaller at equal SSIM (3.6% at equal visible PSNR
on images with transparency), and lower peak RSS. `best` buys under 1%
for 2.5× the time, and `fast` runs at 1.86× `default`'s speed over a
megapixel for files 4-11% larger. Keep `alpha_compression` on: the ALPH
chunk is more than half of those ten RGBA files at quality 75.

Left: trellis quantization (libwebp's -m 5 and 6) and SNS-like perceptual
tuning would close the held-out PSNR gap; `fast` trails cwebp -m 0 by
1.3× in speed; the lossless encoder's alpha streams are 5-8% larger than
libwebp's at the matching method, and slower on images with much
transparency.

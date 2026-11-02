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

| operation, class (rows)     | image MP/s | vs libwebp | slowest row          |
| --------------------------- | ---------- | ---------- | -------------------- |
| default vs -m 4, icons (13) | 5.7        | 1.11       | 1.02 (16×16 icon)    |
| default, to 1 MP (23)       | 16.9       | 1.39       | 1.16 (kodim01)       |
| default, over 1 MP (8)      | 18.3       | 1.42       | 1.26 (Wikipedia 001) |
| fast vs -m 2, icons (13)    | 7.7        | 1.16       | 0.94 (16×16 icon)    |
| fast, to 1 MP (23)          | 29.6       | 1.03       | 0.90 (kodim01)       |
| fast, over 1 MP (8)         | 32.0       | 1.01       | 0.93 (Tecnick 001)   |
| best vs -m 6, icons (13)    | 2.5        | 1.04       | 0.72 (16×16 icon)    |
| best, to 1 MP (23)          | 6.8        | 1.02       | 0.87 (dice)          |
| best, over 1 MP (8)         | 7.3        | 0.99       | 0.77 (Tecnick 002)   |
| RGBA vs -m 4, icons (13)    | 5.5        | 2.90       | 1.21 (64×64 texture) |
| RGBA, to 1 MP (23)          | 16.0       | 1.84       | 1.15 (kodim01)       |
| RGBA, over 1 MP (8)         | 17.5       | 1.44       | 1.27 (Wikipedia 001) |
| all (176)                   | 11.1       | 1.30       |                      |

The RGBA row is fast because our alpha is stored raw: libwebp compresses
it losslessly, and its files on that row are half the size of ours
(4,072,656 bytes to 8,410,156). The other rows' sizes at quality 75:
default 0.955 of -m 4's bytes, fast 0.964 of -m 2's, best 0.986 of
-m 6's.

cwebp's method 0, timed by `cwebp -v` on Wikipedia 001 (1.08 MP), runs at
about 45 MP/s, 1.4× our `fast`, with files about 20% larger than
`fast`'s at equal quality.

**Peak RSS** (GNU time, one pass over each size class's inputs; the inputs
and output buffers both arms hold alike, plus the library's own memory),
MiB:

| operation | class  | image | libwebp |
| --------- | ------ | ----- | ------- |
| default   | icons  | 2.6   | 3.5     |
| default   | ≤ 1 MP | 9.9   | 13.8    |
| default   | > 1 MP | 347.2 | 446.1   |
| fast      | icons  | 2.6   | 3.4     |
| fast      | ≤ 1 MP | 9.9   | 12.0    |
| fast      | > 1 MP | 348.0 | 417.1   |
| best      | icons  | 2.6   | 3.5     |
| best      | ≤ 1 MP | 9.9   | 13.7    |
| best      | > 1 MP | 347.2 | 446.1   |
| RGBA      | icons  | 2.6   | 4.5     |
| RGBA      | ≤ 1 MP | 10.9  | 30.0    |
| RGBA      | > 1 MP | 395.2 | 494.1   |

The mosaic's 151 MB of input and its output dominate the large class.

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

Quality 75 at `default`, as cwebp's own default (`-q 75 -m 4`): 1.4×
libwebp's speed over a megapixel, files 1.1% smaller at equal PSNR and
4.6% smaller at equal SSIM, and lower peak RSS. `best` buys under 1% for
2.5× the time, and `fast` runs at 1.75× `default`'s speed over a
megapixel for files 4-11% larger.

Left: trellis quantization (libwebp's -m 5 and 6) and SNS-like perceptual
tuning would close the held-out PSNR gap; `fast` trails cwebp -m 0 by
1.4× in speed; alpha waits on the lossless encoder.

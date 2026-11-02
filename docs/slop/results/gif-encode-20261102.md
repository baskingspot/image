# GIF encode: speed, size, memory, and decision 6, 2026-11-02

`image.gif.encode` and `image.gif.encodeAnimation` (docs/slop/gif.md,
"Encoder") against giflib, the reference library, and gifski, ImageMagick,
and Go's `image/gif`, the encoders people use; and decision 6, which
quantizer and dither, measured on quality and speed.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host where single runs swing by ±10–30%, so only paired, interleaved ratios
are steady), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU; C arms `cc -O3
-march=native`, Go `GOAMD64=v3`. Libraries from the dev shell: giflib
6.1.3, gifski 1.34.0, ImageMagick 7.1.2-34 Q16-HDRI.

Command: `just bench-compare 10 gif-encode gif-encode-few gif-encode-anim`
(exit 0). Three operations (bench/ops.tsv), all `own`, since the encoders
choose their own palettes and compression; their files are compared by
size below. Inputs, `bench/corpus-gen/gif_encode/` (bench/corpus/gif_encode.sh,
checksums in bench/corpus/gif_encode.sha256), raw RGBA8:

- `gif-encode` (`true/`, 11 files): the first source of each category with
  more than 256 colors, from a 32×32 icon to a 1313×6097 web screenshot and
  the 50-megapixel mosaic's top left 4096×4096 (the whole mosaic takes
  gifski and ImageMagick 2.5 GB each, and with every arm's server holding
  its peak the run was killed for memory on this 8 GB machine).
- `gif-encode-few` (`few/`, 11 files): sources after ImageMagick's
  256-color GIF writer, which an encoder can store exactly.
- `gif-encode-anim` (`anim/`, 4 files): whole-canvas frames one after
  another, 10 hundredths of a second each: the 64-pixel icons in turn (4
  frames, alpha), a panned Kodak photo (480×320, 12 frames, every pixel
  changing), a screen recording with a moving highlight (1280×720, 10
  frames), and an icon moving over a photo (1600×900, 8 frames).
  Megapixels are the canvas's, once per call.

What each arm does (bench/zig/gif.zig and bench/c/*-gif.c, bench/go/):
ours with the default options (Wu, bounded Floyd-Steinberg, cropping);
giflib stores at most 256 colors exactly and otherwise uses
`GifQuantizeBuffer` (median cut without dithering, alpha dropped), writing
whole frames; gifski at quality 90 (its default) and the input's size;
ImageMagick's defaults through MagickWand, its animation optimized with
`MagickOptimizeImageLayers`; Go's `gif.Encode` (the Plan 9 palette with
Floyd-Steinberg, whatever the image), the image's own palette for
`gif-encode-few`, and `gif.EncodeAll` of Plan 9 frames. So only
`gif-encode-few` is the same work in every arm but gifski; on the other
rows, giflib does less (no dithering) and gifski much more (libimagequant
and its own lossy compression).

## Speed

A ratio is our throughput over the arm's (above 1, ours is faster), the
geometric mean over rows of each row's median paired ratio over 10 rounds
(`summary.txt`, `rows.txt`, `benchstat.txt`).

| row, class (rows)       | image MP/s | vs giflib | vs gifski | vs ImageMagick | vs Go |
| ----------------------- | ---------- | --------- | --------- | -------------- | ----- |
| GifEncode/icon (2)      | 5.7        | 0.68      | 41.05     | 1.75           | 3.95  |
| GifEncode/1mp (5)       | 41.2       | 0.51      | 12.91     | 7.02           | 26.52 |
| GifEncode/large (4)     | 33.9       | 0.39      | 10.48     | 9.56           | 21.04 |
| GifEncodeFew/icon (4)   | 105.2      | 1.14      | 745.78    | 27.11          | 4.00  |
| GifEncodeFew/1mp (4)    | 92.9       | 0.81      | 20.84     | 13.29          | 1.38  |
| GifEncodeFew/large (3)  | 55.1       | 0.73      | 12.21     | 11.71          | 1.01  |
| GifEncodeAnim/icon (1)  | 2.0        | 0.64      | 20.64     | 2.38           | 5.96  |
| GifEncodeAnim/1mp (2)   | 6.1        | 1.43      | 21.04     | 21.77          | 40.68 |
| GifEncodeAnim/large (1) | 18.1       | 1.75      | 33.85     | 45.26          | 88.40 |
| all (26)                | 34.6       | 0.73      | 29.93     | 10.71          | 7.35  |

The arms' own throughput, from those ratios, in MP/s:

| row, class          | image | giflib | gifski | ImageMagick | Go   |
| ------------------- | ----- | ------ | ------ | ----------- | ---- |
| GifEncode/icon      | 5.7   | 8.38   | 0.14   | 3.26        | 1.44 |
| GifEncode/1mp       | 41.2  | 80.8   | 3.19   | 5.87        | 1.55 |
| GifEncode/large     | 33.9  | 86.9   | 3.23   | 3.55        | 1.61 |
| GifEncodeFew/icon   | 105.2 | 92.3   | 0.14   | 3.88        | 26.3 |
| GifEncodeFew/1mp    | 92.9  | 114.7  | 4.46   | 6.99        | 67.3 |
| GifEncodeFew/large  | 55.1  | 75.5   | 4.51   | 4.71        | 54.6 |
| GifEncodeAnim/icon  | 2.0   | 3.12   | 0.10   | 0.84        | 0.34 |
| GifEncodeAnim/1mp   | 6.1   | 4.27   | 0.29   | 0.28        | 0.15 |
| GifEncodeAnim/large | 18.1  | 10.3   | 0.53   | 0.40        | 0.20 |

- **Against gifski, ImageMagick, and Go** we are 1.75–89× faster on every
  quantized row, matching or beating their quality (decision 6 below). On
  the exact rows Go ties us past icons (1.01–1.38×).
- **giflib is faster on truecolor stills** (0.39–0.68×) because it does
  less: a median cut without dithering. Undithered, we run at about 59
  MP/s on photos (decision 6's table), still below giflib's 81–87.
- **giflib is faster on the exact path past icons** (0.81× up to a
  megapixel, 0.73× above), the one row where the work is the same: every
  arm but gifski writes the same table and nearly the same bytes. Our LZW
  alone encodes kodim01's indices at about 100 MP/s, and the exact path
  reads the pixels twice (counting the colors, then mapping them) through
  a hash of the colors, which costs as much again; giflib's arm reads them
  once and its LZW is faster. A one-pass exact path and a faster LZW inner
  loop are the follow-ups (a cached code width measured within noise).
- **Quantized icons are setup-bound**: a 32×32 icon costs about 300 µs,
  mostly Wu's pass over its 33³ table and the cuts; giflib's quantizer is
  1.5× faster there. The 64-pixel icon animation quantizes four such
  frames (0.64×).
- **Animations that change little are fast** because only what changes is
  quantized and stored: 1.43–1.75× giflib, which writes whole frames.

## Size

Bytes per file (`check.txt`), by class:

| row, class          | image      | giflib     | gifski    | ImageMagick | Go         |
| ------------------- | ---------- | ---------- | --------- | ----------- | ---------- |
| GifEncode/icon      | 4,221      | 4,230      | 4,090     | 4,102       | 4,194      |
| GifEncode/1mp       | 498,778    | 362,555    | 322,224   | 451,663     | 372,175    |
| GifEncode/large     | 13,818,293 | 7,232,947  | 8,932,707 | 10,231,809  | 9,357,912  |
| GifEncodeFew/icon   | 9,277      | 9,277      | 7,681     | 9,285       | 9,277      |
| GifEncodeFew/1mp    | 434,286    | 434,219    | 288,358   | 434,302     | 434,219    |
| GifEncodeFew/large  | 10,423,809 | 10,422,704 | 7,601,365 | 10,423,833  | 10,422,704 |
| GifEncodeAnim/icon  | 10,947     | 10,392     | 10,544    | 10,350      | 9,767      |
| GifEncodeAnim/1mp   | 1,835,615  | 2,453,098  | 1,665,810 | 1,618,395   | 3,852,330  |
| GifEncodeAnim/large | 738,281    | 2,677,289  | 1,343,665 | 534,999     | 4,627,618  |

- Dithered truecolor costs bytes: our stills are the largest, 8–40% over
  ImageMagick's default output (kodim01 352,791 against 326,081; the 16 MP
  mosaic 10,498,098 against 7,513,081) and up to twice giflib's undithered
  files. That is decision 6's trade (dithering adds 20%); gifski is smaller
  at quality 90 because it quantizes and compresses lossily.
- Exact files match giflib's, ImageMagick's, and Go's to within a few bytes
  (the same table, LZW's freedom in when to clear); gifski's are smaller
  because they are not exact.
- Animations: the screen recording is 309,406 bytes (ImageMagick's
  optimized layers 259,938, gifski 765,346, giflib's whole frames
  1,513,417) and the sprite 738,281 (ImageMagick 534,999). The panned photo
  changes every pixel,
  so it is twelve dithered photos (1,526,209; gifski 900,464).

## Peak RSS

Peak RSS (GNU time, MiB) of one pass over each class's inputs
(`rss.txt`), the input and the output buffer (4 bytes a pixel for stills,
16 for animations) held alike by every arm:

| row, class          | image | giflib | gifski | ImageMagick | Go    |
| ------------------- | ----- | ------ | ------ | ----------- | ----- |
| GifEncode/icon      | 4.0   | 3.3    | 4.9    | 26.4        | 3.7   |
| GifEncode/1mp       | 6.9   | 7.5    | 67.7   | 44.1        | 19.6  |
| GifEncode/large     | 131.9 | 195.2  | 904.2  | 730.2       | 320.5 |
| GifEncodeFew/icon   | 2.4   | 2.6    | 5.3    | 26.4        | 4.0   |
| GifEncodeFew/1mp    | 5.3   | 5.7    | 86.5   | 44.3        | 17.8  |
| GifEncodeFew/large  | 129.9 | 146.1  | 894.2  | 727.8       | 308.2 |
| GifEncodeAnim/icon  | 4.2   | 4.2    | 6.0    | 26.9        | 4.2   |
| GifEncodeAnim/1mp   | 53.3  | 56.8   | 287.2  | 276.6       | 133.9 |
| GifEncodeAnim/large | 70.0  | 75.5   | 391.4  | 322.8       | 157.8 |

We are the smallest or tied in every class but quantized icons, where the
quantizer's 1.4 MB table, touched in full by Wu's cumulative pass, costs
0.7 MiB over giflib's. Our work memory is fixed (about 2.4 MiB) whatever
the image; giflib's arm, gifski, ImageMagick, and Go allocate index
images, copies of the pixels, or both.

## Decision 6: quantizer and dither

Sources: the 16 truecolor images of the shared corpus with more than 256
colors (Kodak, Tecnick, and Wikipedia photos, the QOI test photos, a game
screenshot, the dice render, and three web screenshots cropped to
1313×1200), flattened onto white, opaque. Each is encoded by every
quantizer (`wu`, `median_cut`, `octree`) with `refine` 0, 2, and 8 (8 for
Wu only) and dither `none` or `floyd_steinberg`; by gifski at quality 90
(its default) and 100, at full size; and by ImageMagick with its default
dither, `-dither None`, and `-dither FloydSteinberg`. Scores from
ImageMagick's `compare` against the source: PSNR, PSNR after a σ=1 Gaussian
blur of both images (a stand-in for viewing distance, the eye's low-pass,
which credits dithering for the averages it keeps), and SSIM. No
perceptual metric (ssimulacra2, butteraugli, dssim) is in the dev shell or
nixpkgs here. MP/s is ours, best of three in-process calls on one core;
gifski and ImageMagick are timed in the bench rows above, not here.

| config      | PSNR dB | blurred PSNR dB | SSIM   | bytes     | MP/s |
| ----------- | ------- | --------------- | ------ | --------- | ---- |
| wu-r8-fs    | 39.10   | 51.23           | 0.9719 | 7,034,143 | 23.8 |
| wu-r2-fs    | 39.09   | 51.20           | 0.9719 | 7,033,557 | 28.6 |
| wu-r0-fs    | 39.01   | 51.17           | 0.9715 | 7,045,775 | 32.2 |
| im-fs       | 37.36   | 50.93           | 0.9627 | 7,335,143 | –    |
| mc-r2-fs    | 38.80   | 50.77           | 0.9715 | 7,087,208 | 27.2 |
| mc-r0-fs    | 38.42   | 49.82           | 0.9701 | 7,139,250 | 30.4 |
| oct-r2-fs   | 36.49   | 49.42           | 0.9494 | 6,165,956 | 30.0 |
| oct-r0-fs   | 35.69   | 48.25           | 0.9386 | 6,144,731 | 31.7 |
| wu-r8-none  | 41.29   | 47.00           | 0.9864 | 5,884,955 | 37.2 |
| wu-r2-none  | 41.26   | 46.98           | 0.9864 | 5,885,789 | 51.7 |
| gifski-q100 | 41.24   | 46.92           | 0.9878 | 7,022,166 | –    |
| wu-r0-none  | 41.12   | 46.87           | 0.9860 | 5,876,112 | 58.7 |
| im-none     | 40.75   | 46.65           | 0.9875 | 6,281,490 | –    |
| mc-r2-none  | 40.97   | 46.53           | 0.9863 | 5,891,631 | 48.6 |
| im-default  | 39.86   | 46.00           | 0.9823 | 6,127,311 | –    |
| mc-r0-none  | 40.50   | 45.82           | 0.9858 | 5,955,918 | 56.9 |
| gifski-q90  | 38.19   | 45.12           | 0.9715 | 4,038,665 | –    |
| oct-r2-none | 38.93   | 43.86           | 0.9802 | 4,710,202 | 56.3 |
| oct-r0-none | 37.86   | 42.72           | 0.9747 | 4,559,701 | 65.8 |

Means over the 16 images, bytes summed. What it says:

- **Wu wins** among the quantizers on every metric, dithered or not, at the
  speed of the others: median cut is 0.6 dB lower and octree 3.3 dB
  lower. Without dither, Wu matches gifski at quality 100 (41.12 against
  41.24 dB PSNR, 0.9860 against 0.9878 SSIM) in 16% fewer bytes, and beats
  every ImageMagick setting.
- **`refine` buys little**: two k-means passes add 0.08–0.14 dB to Wu for
  11–12% of its speed, eight add 0.09–0.17 dB for 26–37%. Median cut gains
  more (0.4–0.5 dB, 1 dB blurred), and still trails Wu.
- **Dither** costs 2.1 dB of PSNR and 0.015 of SSIM, and 20% more bytes,
  and gains 4.3 dB of blurred PSNR: smooth gradients (skies, skin, shading)
  without bands. Every encoder people use dithers by default (ImageMagick's
  Riemersma, Go's Floyd-Steinberg, gifski's selective dithering).
- **The error bound.** Unbounded Floyd-Steinberg left stray far-colored
  dots where the palette is sparse (blue specks across kodim03's gray sky,
  yellow ones on kodim23's red parrot; the bounded version and gifski show
  none). Bounding the error a pixel passes on at 16 a channel removes them
  and improves every metric (`clamp-sweep.tsv`, Wu, refine 0, dithered):

  | max error | PSNR dB | blurred PSNR dB | SSIM   | bytes     |
  | --------- | ------- | --------------- | ------ | --------- |
  | 256 (off) | 38.15   | 50.96           | 0.9666 | 7,051,152 |
  | 64        | 38.25   | 51.05           | 0.9672 | 7,051,303 |
  | 32        | 38.54   | 51.17           | 0.9688 | 7,055,090 |
  | 16        | 39.01   | 51.17           | 0.9715 | 7,045,775 |
  | 12        | 39.24   | 51.08           | 0.9728 | 7,032,760 |
  | 8         | 39.57   | 50.84           | 0.9748 | 6,992,464 |

  16 keeps the best blurred PSNR while gaining 0.86 dB of PSNR; tighter
  bounds drift toward no dithering.

**Recommendation:** keep the defaults, `quantizer = .wu`, `refine = 0`,
`dither = .floyd_steinberg` (bounded at 16): the best blurred PSNR of every
encoder measured, PSNR 1.65 dB over ImageMagick's Floyd-Steinberg, at 32
MP/s. Its cost is file size: dithered photos are 8–40% larger than
ImageMagick's default output in the bench rows (the 16-megapixel mosaic
most). `dither = .none` is the choice for screen content and for size; it
matches gifski at quality 100 and runs at 59 MP/s. A middle way, dithering
only where the image is smooth as gifski does, would cut the size and is
left as a follow-up.

## The changes measured

During the work, with interleaved A/B rounds of two builds of bench-image
(ab.py, the bench's serve protocol, 7 rounds a row, ratio B/A):

- **Cropping after a quantized frame** (`gif: crop an animation's frames
after a quantized frame too`). Unchanged pixels were left out only after
  an exactly stored frame, so a truecolor animation was stored as whole
  frames: screen-1280x720 was 2,879,053 bytes (gifski 765,346, ImageMagick
  259,938) and sprite-1600x900 5,664,685; after, 309,406 and 738,281.
  gif-encode-anim runs 3.65× faster on the 1mp class and 6.19× on large
  (`ab-perf.txt`, which measured the three source commits together; the
  stills rows are the next item).
- **Vectors and less clearing** (`gif: search the palette and dither with
vectors, and clear less`): the nearest-entry search 16 entries at a time
  (identical output; 1.30× on undithered stills, 1.18× dithered), dithering
  with the three channels in one vector and the forward error in a register
  (identical output; 1.10× dithered), Wu's cut reading 4 corners of a plane
  as one vector instead of 8 moments of 5 sums, no cell gathering for Wu
  without `refine`, and a touched-cell bitset in place of clearing the
  1.4 MB histogram per frame (icons: about 465 to 300 µs a call). Files are
  byte-identical to before on the decision-6 corpus for all 14 settings.
  gif-encode: 1.12× on icons, 1.24× up to a megapixel, 1.31× larger.
- A branchless `add` (masking instead of a branch on new cells) measured
  0.99× and was dropped; a 4-bit histogram for small images cost 5 dB on
  icons (43.5 to 38.6 dB PSNR undithered) and was dropped.

Raw data in `gif-encode-20261102/`: `quality.tsv` (every score; PSNR dB is
the value × 120, SSIM is 1 − the dssim column), `quality-times.tsv`,
`clamp-sweep.tsv`, `ab-perf.txt`, the bench-compare output, and the tools
(`quality.zig`, `score.sh`, `ab.py`).

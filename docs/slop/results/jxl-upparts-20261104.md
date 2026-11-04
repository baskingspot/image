# JPEG XL decode: upsampled bands written in parts, 2026-11-04

After `jxl-splines-20261103.md`, which found that the streamed band's
upsampled planes were most of what a `--resampling` decode touches beyond
its output, `image.jxl.Decoder` on `wave4-jxl-upparts` upsamples, noises,
color-transforms, and writes an upsampled band 64 output rows at a time
(`frame.upChunk`: 32, 16, or 8 source rows at 2×, 4×, and 8×) instead of
all of its rows at once: the band of a 4000-wide 2× frame was 512 rows of
three planes and the alpha, 32.8 MB, and is now 4.1 MB. The noise's ring
of random rows shrinks with it (a part and a tile row). Each part starts a
multiple of eight samples into the frame, so the color transform's vector
and scalar parts take the same samples as on whole planes, and the pixels
are unchanged: the 303 corpus files, the 88 noise and 2× bench re-encodes,
the 4000×2667 and 1001×1400 test files of `jxl-noiseup`, 800×2200 files at
4× and 8× with noise and with alpha, and the spliced spline files hash as
before. `work_len` for a streamed upsampled frame counts a part instead of
a band; a frame decoded whole keeps its bound.

## Results

Peak RSS of one decode each, the bench's Zig arm (`bench-image serve`,
ReleaseFast), MiB (`rss-single.txt`; libjxl's from
`jxl-splines-20261103/rss.txt`, RGBA16 on one thread):

| file (`--resampling=2`)                 | before | after | output | libjxl |
| --------------------------------------- | ------ | ----- | ------ | ------ |
| 4000×2667 photo (patches)               | 127.9  | 107.4 | 81.4   | 102.4  |
| the same with alpha                     | 143.5  | 116.2 | 81.4   | 105.5  |
| 4000×2667 photo, `--patches=0`          | 127.8  | 107.3 | 81.4   |        |
| the same with alpha                     | 143.5  | 116.2 | 81.4   |        |
| 1313×6097 screenshot                    | 84.5   | 75.5  | 61.1   | 82.7   |
| 1200×1200 photo (two group rows, whole) | 35.0   | 35.0  | 11.0   | 22.4   |

Arena peak and `work_len`, MB (`arena-peaks.txt`):

| file                                    | peak before | after | `work_len` before | after  |
| --------------------------------------- | ----------- | ----- | ----------------- | ------ |
| 4000×2667, `--resampling=2 --patches=0` | 45.4        | 23.9  | 160.5             | 138.6  |
| the same with alpha                     | 61.8        | 33.1  | 229.6             | 202.5  |
| 4000×2667, `--resampling=2` (patches)   | 693.1       | 671.5 | 3046.7            | 3046.7 |
| the same with noise                     | 730.4       | 687.4 | 3046.7            | 3046.7 |
| 800×2200 with alpha and splines, 2×     | 15.3        | 10.4  | 78.1              | 72.7   |

Speed, 8 rounds interleaved, `jxl-decode` pinned to one core of an
Intel(R) Xeon(R) Processor @ 2.60GHz (`taskset`), benchstat:

| rows                    | geomean MP/s before | after | change | best-of B/A |
| ----------------------- | ------------------- | ----- | ------ | ----------- |
| `up2` (bench lossy, 2×) | 16.21               | 16.21 | −0.06% | 1.0056      |
| lossy                   | 19.99               | 20.02 | +0.14% | 1.0020      |

The bench's own peak RSS per size class (`up2-rss.txt`): the `up2`
large class 115.9 → 101.0 MiB; lossy unchanged.

## The extra channels' rings: left as they are

Holding an upsampled frame's extra channels in two group rows plus a tail
of two rows, instead of three group rows, measured by setting the ring to
two group rows (wrong pixels, right allocation): the 4000×2667 2× photo
with alpha's arena peak 33.1 → 31.1 MB, the 800×2200 spline file's 10.4 →
10.0 MB, about 1.7% of the photo's RSS. Not done: it needs a tail in the
Modular channels' rings and in undoing their transforms per band, for 2 MB.
Without upsampling, two group rows is already the least: a band is written
after the next group row's groups have decoded into the ring.

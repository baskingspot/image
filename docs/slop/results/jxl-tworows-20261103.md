# JPEG XL decode: a streamed frame's ring of two group rows, 2026-11-03

After `jxl-noiseup-20261103.md`, `image.jxl.Decoder` on `wave4-jxl-noiseup`
(second commit) keeps a streamed VarDCT frame's pixels in a ring of two
group rows instead of three: the group row being decoded and the finished
one before it, whose band is written next. The band's window also reads
the `bandMargin` rows above it (eight, or sixteen when upsampled), which
belong to the group row the next one overwrites; those rows of the
channels not subsampled vertically are copied to a tail before that
(`vardct.Shared.keepTail`), and the window and Gaborish read them from
there (`Shared.pixelRow`, `filters.Source.tail`). Vertically subsampled
chroma needs no tail: its rows are half as many, so two group rows of the
ring hold four group rows of them. A frame needs four group rows instead
of five to stream, since the ring, the window, and the tail then fit in
less than the whole frame.

Pixels are unchanged: the 303 corpus files, the 88 bench sources
re-encoded with noise and with 2× resampling (`noise/`, `up2/`), the
4000×2667 and 1001×1400 test files of `jxl-noiseup`, and new files of four
group rows (19×900, Gaborish and EPF; a recompressed 4:2:0 JPEG), which
now stream, hash as before.

## Results

Arena peak, MB (`jxltool`; `arena-peaks.txt`):

| file                                        | before | after |
| ------------------------------------------- | ------ | ----- |
| 4000×2667 photo, `-d 1 --photon_noise_iso`  | 81.4   | 69.4  |
| `noise/screenshot_web-amazon_com-1313x6097` | 32.8   | 28.9  |
| `noise/photo_tecnick-RGB_OR_1200x1200_001`  | 25.4   | 21.9  |
| 4000×2667 photo, `-d 4 --resampling=2`      | 698.8  | 693.1 |
| `vardct-tall.jxl` (8×1100)                  | 2.29   | 2.26  |
| `jpeg-tall-420.jxl` (17×1100, 4:2:0)        | 2.67   | 2.57  |

Speed and peak RSS, 8 rounds interleaved, `jxl-decode` over the bench's
lossy rows and over `noise/`, each pinned to one core of an Intel(R)
Xeon(R) Processor @ 2.60GHz (`taskset`), benchstat:

| rows    | geomean MP/s before | after | change | best-of B/A |
| ------- | ------------------- | ----- | ------ | ----------- |
| lossy   | 20.66               | 20.66 | +0.00% | 0.9957      |
| `noise` | 13.87               | 13.87 | −0.04% | 1.0039      |

No row moves beyond the noise (`lossy-benchstat.txt`,
`noise-benchstat.txt`).

Peak RSS, MiB (`lossy-rss.txt`, `noise-rss.txt`):

| rows    | class | before | after |
| ------- | ----- | ------ | ----- |
| lossy   | 1mp   | 28.1   | 27.2  |
| lossy   | large | 506.9  | 483.7 |
| `noise` | 1mp   | 40.1   | 37.1  |
| `noise` | large | 555.9  | 532.4 |

The large class is the 50-megapixel mosaic (8192×6144): a group row of its
three planes is 25 MB.

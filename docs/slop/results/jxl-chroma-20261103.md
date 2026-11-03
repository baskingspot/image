# JPEG XL decode: subsampled chroma streamed, 2026-11-03

After `jxl-mstream2-20261103.md`, `image.jxl.Decoder` on `wave4-jxl-chroma`
streams VarDCT frames with subsampled chroma: what cjxl writes for a
4:2:0, 4:2:2, or 4:4:0 JPEG recompressed (`--lossless_jpeg=1`) and
decoded to pixels. Such a frame used to be decoded whole, since its chroma
was upsampled in place over whole planes (`vardct.upsampleChroma`) before
the restoration filters. Now each band's window takes its upsampled rows
from the ring (`vardct.chromaWindow`): each ring row of a subsampled
channel is upsampled across in place once, when the first window needs
it, and the window's rows are blended down from those with
`upsampleChroma`'s arithmetic, in its order (across, then down), so the
pixels are the same bit for bit. Gaborish then filters the window in place
instead of reading the planes. A band's window reaches at most four chroma
rows plus one into the next group row, which is in when the band is
written, and the ring's three group rows hold every row a window reads.

Pixels are unchanged: all 552 frames of the 303 JPEG XL files in `corpus/`
and `bench/corpus-gen/` (with `jxl_jbrd/`, decoded to pixels) hash as
main's, and so do 4:2:0, 4:2:2, and 4:4:0 transcodes of 1501×1333 (odd
both ways), 1300×1500, and 4000×2667.

## Results

The arena's peak and `Config.work_len`, MB (`jxltool`; 19 of 303 files
change, none rises; every file in `jxl-chroma-20261103/arena-peaks.txt`):

| file (`bench/corpus-gen/jxl_jbrd/baseline/`) | peak before | peak after | `work_len` before | after |
| -------------------------------------------- | ----------- | ---------- | ----------------- | ----- |
| `photo_mosaic-50mp-8192x6144.jxl`            | 686.1       | 119.7      | 743.6             | 243.6 |
| `screenshot_web-amazon_com-1313x6097.jxl`    | 123.9       | 26.5       | 186.1             | 105.5 |
| `screenshot_web-cnn_com-1313x5241.jxl`       | 106.4       | 22.8       | 164.8             | 98.0  |
| `screenshot_web-apple_com-1313x4755.jxl`     | 96.7        | 20.9       | 152.9             | 93.8  |
| `photo_tecnick-RGB_OR_1200x1200_001`         | 22.1        | 17.8       | 62.0              | 59.9  |
| `textures_plants-plant_02-1024x1316.jxl`     | 20.8        | 15.5       | 60.2              | 56.9  |
| `pngimg-academy_awards_PNG9-447x1192.jxl`    | 8.9         | 8.1        | 44.3              | 43.5  |

The `progressive/` copies change the same way; the conformance suite's
cafe and cafe_5 peak 155.1 → 142.6 MB (`work_len` unchanged: not the only
frame peeked). A 4000×2667 4:2:0 transcode peaks 163.5 → 55.6 MB, as its
4:4:4 twin did already (55.6).

Speed and peak RSS, 8 rounds interleaved: `jxl-decode` over the
recompressed JPEGs (`jxl_jbrd/baseline`, decoded to pixels: the operation
run from a scratch root whose `bench/corpus-gen/jxl/lossy` links there,
since no bench operation decodes them to pixels), and over its own lossy
files as a control (none subsampled):

| rows (44 each)       | geomean MP/s  | change | faster / slower | peak RSS, MiB (large) |
| -------------------- | ------------- | ------ | --------------- | --------------------- |
| recompressed JPEGs   | 54.07 → 55.13 | +1.95% | 10 / 0          | 979.1 → 500.1         |
| `jxl-decode` (lossy) | 19.61 → 19.64 | +0.15% | 1 / 0           | 506.8 → 506.9         |

The three tall screenshots gain 22–26% (amazon 53.4 → 65.2 MP/s) and the
50-megapixel photo 5% (60.0 → 63.1): the planes no longer spill out of the
cache between decoding and output. Best-of geomeans 1.016 and 1.004.

## libjxl and Gaborish on subsampled chroma

cjxl turns the restoration filters off for a recompressed JPEG, so no
corpus file has both. `Decoder.zig`'s unit test sets Gaborish and three EPF
passes in an 8×1100 4:2:0 transcode's frame header by hand, which streams
and decodes whole alike. libjxl decodes that file up to 1,134 16-bit steps
from ours, on even rows only (odd rows agree; without the filters it is
within 1 step). Gaborish, the upsampling, and YCbCr are linear, and
Gaborish's default weights are the same for every channel, so Gaborish
applied to the unfiltered RGB output predicts the filtered output: ours is
within 104 steps of the prediction on even rows and 99 on odd (clamping),
libjxl's within 1,134 on even rows and 99 on odd. libjxl's pipeline
upsamples before Gaborish too (`dec_cache.cc` adds the stages in that
order), so the difference is not the order; its cause in libjxl is not
found. EPF leaves that file's pixels as they are in both.

Method: as in `jxl-mstream-20261103.md`, base main f2ec9e7. Raw output in
`jxl-chroma-20261103/`.

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0.

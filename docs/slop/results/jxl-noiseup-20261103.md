# JPEG XL decode: noise, upsampling, and patches streamed, 2026-11-03

After `jxl-chroma-20261103.md`, `image.jxl.Decoder` on `wave4-jxl-noiseup`
streams VarDCT frames with noise (`cjxl --photon_noise_iso`), upsampling
(`--resampling`, with the extra channels upsampled by the same factor),
or patches; only splines, and extra channels upsampled by another factor
than the colors, still decode a frame whole.

- **Patches** are applied to each band's rows after the filters, every
  patch that crosses them in the dictionary's order (`patches.apply` takes
  a row range), which is each pixel's order whatever the rows.
- **Upsampling.** The window's margin is sixteen rows instead of eight, so
  two filtered rows remain on each side of the band; the band is patched
  over them and upsampled from them (`upsample.upsampleRows`, which the
  whole-frame `upsample` now calls), and so are its extra channels, whose
  rings keep three group rows instead of two. Global Modular transforms
  are undone on copies of those rows (`Image.band`'s `copy`), since two
  bands read them and RCTs and palettes are undone in place. The band is
  color-transformed into contiguous rows of the frame's width, which
  start a multiple of eight samples into the frame: the transform's vector
  part and scalar tail take the same samples as on whole planes, where a
  width that is not a multiple of eight leaves the last few samples of the
  frame to the scalar tail.
- **Noise** is drawn per tile of a group's size after upsampling, each
  tile's generator filling the three planes one after another, so a tile's
  first rows of one plane cannot be drawn without the others: its random
  rows are drawn a tile row at a time into a ring that reaches two rows
  past the band (`noise.Stream`). The whole frame's noise runs through the
  same row code.

Pixels are unchanged: all 552 frames of the 303 corpus files, 86 bench
sources re-encoded with noise and with 2× resampling, and 4000×2667 and
1001×1400 files with each feature (with and without alpha, 2×, 4×, and 8×,
and Gaborish with EPF), hash as main's (with `wave4-jxl-patchstride`).

## Results

Arena peak and `Config.work_len`, MB (`jxltool`; no file rises; every file
in `jxl-noiseup-20261103/arena-peaks.txt`). `noise/` and `up2/` are the
bench's lossy sources re-encoded by `cjxl -d 1 --photon_noise_iso=3200`
and `cjxl -d 4 --resampling=2`:

| file                                        | peak before | after | `work_len` before | after  |
| ------------------------------------------- | ----------- | ----- | ----------------- | ------ |
| `noise/screenshot_web-amazon_com-1313x6097` | 227.7       | 32.8  | 431.7             | 342.1  |
| `noise/screenshot_web-cnn_com-1313x5241`    | 195.8       | 32.4  | 376.4             | 300.5  |
| `noise/photo_tecnick-RGB_OR_1200x1200_001`  | 35.4        | 25.4  | 79.9              | 67.6   |
| 4000×2667 photo, `-d 1 --photon_noise_iso`  | 260.2       | 81.4  | 368.6             | 185.5  |
| `up2/screenshot_web-amazon_com-1313x6097`   | 816.4       | 669.9 | 2688.5            | 2688.5 |
| 4000×2667 photo, `-d 4 --resampling=2`      | 808.8       | 698.8 | 2956.4            | 2956.4 |
| conformance `bike` (noise)                  | 402.8       | 352.3 | 1505.5            | 1505.5 |

cjxl writes most `--resampling` files with patches, taken from a
dictionary frame before the image, so the image is not the only frame,
`work_len` stays the bound for any frame, and four reference slots of the
canvas's size (12 bytes a pixel each) take most of the peak: the next
cut. The 50-megapixel source's `up2` file asks for 13.3 GB and fails with
`OutOfMemory` on this machine, before and after.

Speed and peak RSS, 8 rounds interleaved, `jxl-decode` run over each
scratch corpus from a scratch root whose `bench/corpus-gen/jxl/lossy`
links to it, and over its own lossy files as a control:

| rows                     | geomean MP/s  | change | faster / slower | peak RSS, MiB (large) |
| ------------------------ | ------------- | ------ | --------------- | --------------------- |
| `noise/` (44)            | 14.02 → 14.05 | +0.20% | 1 / 0           | 1558.2 → 555.9        |
| `up2/` (43; 50 MP fails) | 17.22 → 17.10 | −0.69% | 0 / 1           | 352.9 → 121.3         |
| `jxl-decode` lossy (44)  | 21.05 → 21.09 | +0.18% | 0 / 0           | 506.9 → 506.9         |

Best-of geomeans 1.002, 0.997, and 1.002: within this host's noise. The
one slower `up2` row (photo_wikipedia-003, −2.5%) is three group rows
tall and does not stream.

Method: as in `jxl-mstream-20261103.md`, base main 7e338b8 with
`wave4-jxl-patchstride` (8efdfca). Raw output in
`jxl-noiseup-20261103/`.

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0.

# JPEG XL decode: Modular frames streamed, 2026-11-03

`image.jxl.Decoder` on `wave4-jxl-mstream` decodes a Modular frame a group
row at a time when it can: a shown frame that replaces the canvas and is
never referenced, drawn in integers (no XYB, filters, YCbCr, upsampling,
patches, splines, or noise), in one pass with its groups in order, at
least two group rows tall, and with no global transforms. Its channels
keep one group row each (`modular.Channel.ring`), and each group row goes
to the caller's buffer once its groups are in, since no filter reads past
it. A streamed VarDCT frame's extra channels (alpha) keep two group rows
the same way, where they kept the whole frame. A frame with global
transforms is decoded whole, as before: they are undone on the whole
frame, and they are known only once the global stream is read.

Pixels are unchanged: all 547 frames of the 298 JPEG XL files in `corpus/`
and `bench/corpus-gen/`, and the mosaic, hash the same as main's, and every
bench row checksums the same.

`Config.work_len` is unchanged. The transforms come after the tree in
LfGlobal, and `decodeConfig` has no work memory to read the tree, so the
bound keeps the whole frame for any frame that might have them. What
drops is the memory a decode touches, which is the peak RSS for a caller
whose memory is mapped on first use.

## Results

Peak RSS of the whole operation, MiB, per size class (GNU time, as
`bench-compare` measures it), and geometric means of the rows' medians,
MP/s, 8 rounds:

| operation (44 rows)   | class  | before | after | speed before | speed after | change |
| --------------------- | ------ | ------ | ----- | ------------ | ----------- | ------ |
| `jxl-decode-lossless` | 16×16  | 3.2    | 3.2   |              |             |        |
| `jxl-decode-lossless` | ≤ 1 MP | 25.0   | 18.6  |              |             |        |
| `jxl-decode-lossless` | 50 MP  | 989.1  | 437.2 |              |             |        |
| `jxl-decode-lossless` | all    | 989.5  | 437.3 | 5.950        | 5.928       | −0.37% |
| `jxl-decode`          | all    | 507.0  | 507.0 | 19.42        | 19.49       | +0.37% |

Both speed changes are inside this host's noise (about ±1.5%,
`jxl-speed4-20261103.md`): no row is slower at p < 0.05, and two lossless
rows are faster (a 32×32 icon +5.8%, a 600×600 image +4.6%). The 50-megapixel mosaic's RGBA16 output
is 384 MiB, so beyond the output its lossless peak goes from about 605 MiB
to 53 MiB (libjxl 0.12.0 used about 25 MiB beyond the output,
`jxl-20261102.md`). Lossy classes do not move: the mosaic sets the large
class, and it has no alpha.

The arena's peak per file, MB (`jxltool`, every file whose peak changed;
no file's peak rose, and `work_len` is the same before and after):

| file                                                        | before | after | `work_len` |
| ----------------------------------------------------------- | ------ | ----- | ---------- |
| `lossless/photo_mosaic-50mp-8192x6144.jxl`                  | 608.1  | 29.3  | 2146.5     |
| `lossless/screenshot_web-amazon_com-1313x6097.jxl`          | 133.5  | 10.8  | 516.5      |
| `lossless/screenshot_web-cnn_com-1313x5241.jxl`             | 115.5  | 10.8  | 448.0      |
| `lossless/screenshot_web-apple_com-1313x4755.jxl`           | 105.3  | 10.8  | 409.1      |
| `lossy/screenshot_web-amazon_com-1313x6097.jxl`             | 53.9   | 24.6  | 333.8      |
| `lossy/screenshot_web-cnn_com-1313x5241.jxl`                | 49.0   | 24.2  | 292.2      |
| `lossy/screenshot_web-apple_com-1313x4755.jxl`              | 46.3   | 24.0  | 268.5      |
| `lossless/textures_plants-plant_02-1024x1316.jxl`           | 27.0   | 9.6   | 110.5      |
| `lossless/photo_tecnick-RGB_OR_1200x1200_001-1200x1200.jxl` | 21.4   | 7.8   | 93.1       |
| `lossless/photo_wikipedia-001-1276x850.jxl`                 | 17.1   | 8.0   | 76.6       |
| `lossless/pngimg-air_pump_PNG5-999x772.jxl`                 | 17.8   | 9.5   | 75.3       |
| `lossless/test-dice-800x600.jxl`                            | 13.1   | 8.7   | 57.4       |
| `lossy/textures_plants-plant_02-1024x1316.jxl`              | 21.1   | 17.8  | 86.9       |
| `lossless/test-kodim10-512x768.jxl`                         | 5.8    | 2.6   | 43.5       |
| `lossless/icon_512-actions_address_book_new-512x512.jxl`    | 5.5    | 3.4   | 43.8       |
| `conformance/lossless_pfm/input.jxl`                        | 5.4    | 4.0   | 33.1       |

The other changed files are in `jxl-mstream-20261103/arena-peaks.txt`
with every file's peak; 23 changed in all. Files with global palettes
(the Kodak photos, many icons and textures) are unchanged: cjxl gives
them a palette per channel or for the whole image, and they are at most
two group rows anyway. `modular.Channel` keeps its 32 bytes (its shifts
are `i16` now), so an image's spare channel slots cost no more.

Method: `bench-image serve` builds of main 0f137c7 and the branch side by
side on the last core (`taskset -c 3`), loops sized once, 8 rounds
alternating which build goes first per row, benchstat (median MP/s,
Mann-Whitney U, n = 8), and GNU time's peak RSS per size class. Arena
peaks are `jxltool`'s report of `Decoder.store.arena.peak` after each
file. Raw output in `jxl-mstream-20261103/`.

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0.

## The oracle's one mismatch

`just oracle 100000` found one jxl input out of 100,201 outside its
tolerance (SHA-256 `9377fe64e2df3e587a58c1930977f64abae22a5fa8a3ba0be94386c56f4f28cb`,
396 bytes, a fuzzed 32×32 XYB animation cut off after its first frame).
Main decodes it the same, hash for hash: the three new generated files
changed the mutations the run draws, not the decoder. One sample of
frame 0 is 4 steps of 16 bits from libjxl's (1418 against 1414, red at
(29, 19)); the floats are 0.0216350 and 0.0215836 there, 5.1e-5 apart, in
the sRGB curve's linear segment, whose slope 12.92 amplifies a 4e-6
difference in linear light. That is the class `test/oracle/jxl.zig`
describes for the lossy tolerance of 3 (it saw at most 4.3e-5, 2.8 steps);
this frame, far out of gamut (libjxl's floats run from −0.60 to 1.11),
reaches 3.4 steps, which round to 4. Raising the tolerance to 4, or
leaving this input out, is plan.md decision 45's to change.

## Next

Global RCTs and palettes without delta entries are pointwise and could be
undone a band at a time, so frames with them would stream too; squeezes
and delta palettes need neighbouring rows across bands. `work_len` could
shrink for Modular only if `decodeConfig` learned the transforms, which
means reading the tree without work memory.

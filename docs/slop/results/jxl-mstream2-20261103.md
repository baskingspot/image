# JPEG XL decode: Modular frames with global RCTs and palettes streamed, 2026-11-03

After `jxl-mstream-20261103.md`, `image.jxl.Decoder` on `wave4-jxl-mstream2`
streams Modular frames whose global transforms take each pixel on its
own (`modular.Transform.pointwise`): RCTs, and palettes without deltas or
a predictor, the kind cjxl writes for a two-level alpha and for channels
with few distinct values. Each band's rows are taken from the rings as
channels of their own, the meta channels (the palettes) are shared, the
transforms are undone on them (`modular.Image.band`), and the result must
have the frame's channels at its width before it is written. Squeezes and
delta palettes read across bands, so frames with them are still decoded
whole. A streamed VarDCT frame's alpha with a global palette, which
decoded whole before, streams the same way.

Pixels are unchanged: all 547 frames of the 298 JPEG XL files in `corpus/`
and `bench/corpus-gen/`, and the five generated `modular-*.jxl` files, hash
the same as main's, and every bench row
checksums the same. `Config.work_len` is unchanged, as before.

## Results

The arena's peak per file, MB (`jxltool`; `lossless/` is `bench/corpus-gen/jxl/lossless/`, `generated/` is `corpus/vendor/generated/`; no file's peak rose):

| file                                                                  | before | after |
| --------------------------------------------------------------------- | ------ | ----- |
| `lossless/photo_kodak-kodim01-768x512.jxl`                            | 5.78   | 3.42  |
| `lossless/photo_kodak-kodim02-768x512.jxl`                            | 5.81   | 3.45  |
| `lossless/photo_kodak-kodim03-768x512.jxl`                            | 5.79   | 3.43  |
| `lossless/test-kodim23-768x512.jxl`                                   | 5.78   | 3.42  |
| `lossless/icon_512-actions_bookmark_new-512x512.jxl`                  | 5.47   | 3.38  |
| `lossless/screenshot_game-20XX_Menu_picture-634x406.jxl`              | 5.39   | 3.87  |
| `lossless/textures_plants-plant_01-166x1022.jxl`                      | 3.60   | 1.57  |
| `lossless/screenshot_game-3dcursedlabyrinth_mazegame-343x480.jxl`     | 2.06   | 1.21  |
| `generated/jxl/modular-tall-alpha.jxl` (8×1100, palette alpha)        | 0.31   | 0.20  |
| `generated/jxl/vardct-tall-alpha.jxl` (VarDCT, alpha)                 | 2.32   | 2.30  |
| `generated/jxl/vardct-tall-alpha-palette.jxl` (VarDCT, palette alpha) | 2.33   | 2.30  |

Every other file's peak is in `jxl-mstream2-20261103/arena-peaks.txt`;
the other generated Modular files' peaks are unchanged. The
benchmark corpus's files with global palettes are at most two group rows
tall, so the savings are a group row of each channel; a large image with
a palette (a screenshot with few colors) saves what the previous change
saved on the large files without one.

Speed and peak RSS, geometric means of the rows' medians (MP/s), 8
rounds, and GNU time's peak RSS of the whole operation (MiB):

| operation (44 rows)   | before | after | change | rows faster / slower | peak RSS      |
| --------------------- | ------ | ----- | ------ | -------------------- | ------------- |
| `jxl-decode-lossless` | 5.970  | 5.995 | +0.43% | 1 / 0                | 437.2 → 437.3 |
| `jxl-decode`          | 19.81  | 19.70 | −0.52% | 0 / 0                | 507.0 → 507.0 |

Both inside this host's noise (`jxl-speed4-20261103.md`). The size
classes' peak RSS does not move: the files that changed are not the
largest in their classes.

The generated corpus gains `modular-tall-squeeze.jxl` (`cjxl -d 0 -R 1`),
whose squeezes keep it whole, and the comments on `modular-tall-alpha.jxl`
and `vardct-tall-alpha-palette.jxl` now say they stream. A unit test
decodes an 8×300 file whose alpha cjxl palettes, streamed and whole, and
fails when palettes are not banded.

Method: as in `jxl-mstream-20261103.md`, base main f8d8a22. Raw output in
`jxl-mstream2-20261103/`.

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0.

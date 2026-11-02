# CMYK pixel formats and their conversion kernel, 2026-11-02

Owner decision 15 adds `PixelFormat.cmyk8` and `cmyk16`, the native format
of the raw inks of CMYK and YCCK JPEGs and of CMYK TIFFs, with libjpeg-turbo's
naive conversion to color in `image.convert`.

- The samples are inks stored inverted (the maximum is no ink), as Adobe's
  CMYK JPEGs store them and libjpeg-turbo returns them, so all-zero bytes
  are black here as in every other format. A first version stored ink
  amounts (0 for none, as TIFF and PDF do); the fuzz harness then found 20
  `FormatDiffers` in BMP and ICO in its first second: BMP's RLE path clears
  rows to zero bytes, and the harness zero-fills the buffers, both counting
  on all-zero being black (transparent black) in every format, which made
  it white. Inverted, a JPEG decoder writes its stored samples as they are
  and a TIFF one writes the maximum minus each ink.
- To color, libjpeg-turbo's naive conversion at the source's depth: each of
  R, G, and B is `(2 ink black + max) / (2 max)` (`max` 255 or 65535), and
  `ink * black` in float.
- From color, the naive inverse on 16-bit samples: black is `m`, the
  largest of R, G, and B, and each ink `c * 65535 / m`, rounded, all 0
  where `m` is 0, so black is all-zero bytes both ways. Alpha is dropped,
  as for any format without it. Inks to inks pass through (8-bit samples
  widen by 257, 16-bit narrow to the high byte), not by way of color.
- `CmykTo` converts 8-bit CMYK to RGB, BGR, RGBA, or BGRA with SIMD. A pixel
  sits in a 32-bit lane, C in the low byte, so the arithmetic is lane-wise
  with no shuffle except the one dropping alpha for 3-byte outputs, and the
  division is `(t + (t >> 8)) >> 8` for `t = x + 128`, which equals
  `(2x + 255) / 510` for every product `x` of two bytes. An earlier version
  that split the 16 pixels into planes and interleaved them back with
  64-lane byte shuffles was no faster than the scalar loop (about 510 MP/s
  to RGBA).

Tests: "CMYK" checks every (ink, black) byte pair, to all four 8-bit color
layouts through the kernel and the general path, against libjpeg-turbo's
formula, plus the 16-bit, float, inverse, and ink-to-ink cases; "every SIMD
path gives the general path's bytes" covers the new kernels and the ink
pass-through at every alignment. They pass on x86-64 and on s390x (qemu),
whose byte order the kernel swaps for.

## Method

`main.zig` converts 8 megapixels of random CMYK as rows 16, 166, 1200, and
8192 pixels wide, output 2048 bytes past a page, best of 9, built
ReleaseFast for this CPU against this change (`kernel`) and against the
same file with the kernel switched off (`general`, the general path the
pair would take without it). The `kernel` build also times the JPEG
decoder's current per-pixel loop (`src/jpeg/sample.zig`'s `cmyk`, to RGBA,
`JpegLoop`). `run.sh` runs the two builds in turn, 10 rounds, pinned to
core 3; benchstat compares them (`bs.txt`, `bs-jpegloop.txt`).

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0. This repository's
`just ci` ran on cores 0 to 2 meanwhile.

## Results

Megapixels per second, median of the 10 rounds (`raw-*.txt`):

| row width | kernel to RGBA | to RGB | general to RGBA | to RGB | JPEG loop to RGBA |
| --------- | -------------- | ------ | --------------- | ------ | ----------------- |
| 16        | 1338           | 1381   | 294             | 269    | 515               |
| 166       | 1497           | 1627   | 325             | 307    | 516               |
| 1200      | 1494           | 1718   | 328             | 310    | 521               |
| 8192      | 1503           | 1751   | 329             | 311    | 520               |

benchstat: −79.9% time geomean against the general path and −64.5%
against the JPEG decoder's loop, every row at p = 0.000 (`bs.txt`,
`bs-jpegloop.txt`): the kernel is 4.5–5.6× the general path and 2.6–3.4×
the loop. No buffer or state grows: the kernel works in registers.

## Raw output

`convert-cmyk-20261102/`: `main.zig`, `run.sh`, `raw-kernel.txt` and
`raw-general.txt` (Go benchmark lines, ns per megapixel, and MP/s),
benchstat's inputs, `bs.txt`, and `bs-jpegloop.txt`.

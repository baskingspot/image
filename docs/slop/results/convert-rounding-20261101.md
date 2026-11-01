# Conversion rounding: matching Wuffs, 2026-11-01

The owner decided that conversions match the reference libraries' rounding
unless there is a strong reason not to. Wave 0's `src/convert.zig` rounded
where Wuffs (the bar) truncates. Wuffs itself was the test: every 8-bit
(c, a) pair, every RGB triple, and a sample of 16-bit pixels. After this
change `image.convert` gives Wuffs's pixel swizzler's bytes on 78 of the 99
pixel-format pairs both have. The other 21 pairs convert a source with alpha
to a format without alpha (Y, RGB, BGR). On those, Wuffs composites onto
black, and wave 0 drops the alpha by design. That is a change of meaning,
not of rounding, and it breaks the QOI decoder's fuzz property. It is left
for the owner as `convert-rounding-20261101/composite.patch`, measured
below. With the patch, all 99 pairs agree.

RGBA16 → RGBA8 is now 1.5–2.5× Wuffs. It was 0.67–0.79×.

## What Wuffs does

These rules were found by running Wuffs, not by reading its source. Each one
was a hypothesis that the probe below tested on every pair:

- **Narrowing** 16 bits to 8 takes the high byte, `c >> 8`. Wave 0 rounded
  `c / 257`.
- **Premultiplying** a 16-bit sample is `c·a / 65535`, truncated.
  **Unpremultiplying** is `c·65535 / a`, truncated, clamped to 65535, and 0
  where `a` is 0. Wave 0 rounded both.
- **From an 8-bit source** the premultiply or unpremultiply result keeps 8
  bits: the 16-bit result's high byte, widened again by 257 for a 16-bit
  destination. So 8-bit premultiplication is `(c·257 · a·257 / 65535) >> 8`,
  which is `c·a·257 / 65280` truncated. 8-bit unpremultiplication is
  `c·65535 / a / 256`, and RGBA8 premultiplied → RGBA16 straight is that
  value times 257.
- **Luma** is `(19595 R + 38470 G + 7471 B + 32768) >> 16` on 16-bit
  samples, narrowed by the high byte: wave 0's formula with the new
  narrowing.
- **A destination without alpha** gets the color composited onto black. A
  straight source is premultiplied, by the rules above (at 8 bits for an
  8-bit source, before luma), and a premultiplied source's alpha is
  dropped. Wave 0 drops straight alpha and unpremultiplies a premultiplied
  source, and this branch keeps that (under "For the owner").

Widening (×257), the swizzles, adding alpha, and gray to color already
matched.

## How it was checked

`convert-rounding-20261101/wuffs-probe.zig` links `src/convert.zig` with
Wuffs 0.4.0-alpha.12 from nixpkgs (`wuffs-probe.c`, the swizzler with
`WUFFS_BASE__PIXEL_BLEND__SRC`). It converts the same inputs both ways for
every pair where Wuffs's `pixel_swizzler__prepare` succeeds: 99 pairs among
Y, YA (straight), RGB, BGR, RGBA and BGRA (straight and premultiplied),
Y_16LE, and RGBA and BGRA 4X16LE. It compares every output byte. The inputs
are:

- 8-bit formats with alpha: every (c, a) pair, 65536 pixels with the color
  channels c, 255 − c, and (91c + 17) mod 256, plus 1M random pixels.
- RGB and BGR: all 2²⁴ triples (exhaustive luma). Gray8: all 256 values.
- Gray16: all 65536 values.
- 16-bit RGBA: every alpha with 16 random colors (1M pixels), every value of
  c with 16 boundary alphas and every alpha with 16 boundary colors (2M), and
  1M random pixels.

The results are in these files:

- `wuffs-before.txt` is `src/convert.zig` at 98d1033: 51 of the 99 pairs
  differ.
- `wuffs-after.txt` is this branch. The 78 pairs that keep alpha or have
  none to drop agree on every valid pixel. The 21 pairs from a source with
  alpha to Y, RGB, or BGR differ only through compositing.
- `wuffs-composite.txt` is with `composite.patch`: all 99 agree on every
  valid pixel.

A premultiplied pixel with a color above its alpha is not valid, and the
probe counts it separately. On those pixels Wuffs's unpremultiply overflows
into the neighboring channels and changes the output alpha: RGBA
premultiplied (0, 255, 17, 1) becomes straight (0, 255, 255, 17). We clamp
instead, to (0, 255, 255, 1). Matching an overflow that corrupts alpha is
the strong reason not to match there. Premultiplied → premultiplied passes
such pixels through as Wuffs does.

The probe also pinned down the 16-bit formulas, since Wuffs has no 16 → 16
premultiply. With rounding in place of truncation, the premultiply changes
14065 of the 4M sampled BGRA16 → BGRA8 premultiplied pixels, and the
unpremultiply changes 906278 of the BGRA16 premultiplied → BGRA16 pixels.
Go's `color.RGBA64Model`, below, agrees with the 16-bit premultiply on every
sampled pixel.

The unit test "8-bit premultiply, unpremultiply, and narrowing match Wuffs"
in `src/convert.zig` checks every 8-bit (c, a) pair and every 16-bit sample,
through the SIMD kernels and the general path. Its expected values use a
different form than the code (`c·a·257 / 65280`, `c·65535 / a / 256`,
`c / 256`), and the probe checked those values against Wuffs. The SIMD
premultiply computes `(t + ((t + (t >> 8)) >> 7)) >> 8` on `t = c·a` in
16-bit lanes. A brute force over every product of two bytes found this form,
and the test confirms it. A 32-bit multiply-high form was exact too, but
LLVM lowered it to `vpmulld`, which made premultiply 0.75× Wuffs.

## Where Go differs

`convert-rounding-20261101/go-probe` runs Go 1.26's `image/color` models
(and `draw.Draw` for NRGBA → RGBA) on the same kinds of input
(`go-after.txt`, `go-composite.txt`). On valid pixels Go agrees with Wuffs,
and with this branch, on these pairs:

- RGBA8 → premultiplied, through the model and `draw.Draw`.
- Premultiplied RGBA8 → RGBA8.
- RGB8 → Gray8, and Gray16 → Gray8.
- RGBA16 → premultiplied RGBA8, and → premultiplied RGBA16.
- Premultiplied RGBA16 → RGBA8, premultiplied RGBA8, and RGBA16.

Go composites onto black for Gray, as Wuffs does. Where Go and Wuffs
disagree, Wuffs wins:

| Pair                                 | Pixels that differ | Why                                                                                                                                      |
| ------------------------------------ | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| RGBA16 → RGBA8 (NRGBA64 → NRGBA)     | 83608 of 2.1M      | Go goes through premultiplied 16-bit and back, losing low-alpha colors and zeroing color at alpha 0; Wuffs takes each sample's high byte |
| RGBA8 → RGBA16 (NRGBA → NRGBA64)     | 1109266 of 1.1M    | the same round trip; Wuffs widens each sample exactly                                                                                    |
| RGBA8 premultiplied → RGBA16         | 272990 of 277661   | Go unpremultiplies at 16 bits; Wuffs at 8 bits, then widens                                                                              |
| RGBA8 → Gray8                        | 334228 of 1.1M     | with the patch: Go composites at 16 bits, then takes luma; Wuffs composites at 8 bits first                                              |
| RGBA8 → Gray16, RGBA8 → RGBA16 prem. | 1.10M of 1.11M     | Wuffs lacks these pairs; we keep 8 bits after the alpha step, as Wuffs does for RGBA8 premultiplied → RGBA16; Go keeps 16                |
| premultiplied, color above alpha     | most               | Go does not clamp (`uint8(r >> 8)` of an overflowing value), Wuffs overflows into alpha, we clamp                                        |

## Which pairs changed

`changed-pairs.zig` converts the same inputs with `src/convert.zig` at
98d1033 and after the change, over all 400 pairs. On this branch 174 of the
400 changed (`changed-pairs.txt`). Grouped by cause:

- **Every 16-bit source to every 8-bit destination** (81 pairs), from the
  high-byte narrowing. This includes the pairs wave 1's decoders use to
  write 8 bits from a 16-bit native format: PNG, Netpbm, and later TIFF at
  16 bits.
- **A straight source with alpha** (RGBA, BGRA, or gray-alpha, at 8 or 16
  bits) **to a premultiplied destination** at either depth, from truncation.
  From 8 bits to 16, the result is now the 8-bit one widened.
- **A premultiplied source** at 8 or 16 bits **to a straight destination or
  one without alpha**: truncation, and from 8 bits to 16 the 8-bit result
  widened.
- **Color to gray at 8 bits**: RGB8 and BGR8 → Gray8, gray-alpha8, and
  gray-alpha8 premultiplied, and RGBA8 and BGRA8 → Gray8 and gray-alpha8.
  The cause is luma narrowing.

Unchanged: copies, channel swizzles, adding opaque alpha, gray to color,
widening straight samples, dropping straight alpha (RGBA → RGB at one
depth), straight → straight and premultiplied → premultiplied at one depth
(apart from gray at 8 bits), 16-bit color → 16-bit straight gray, and every
pair with a float side.

With `composite.patch`, 211 pairs change (`changed-pairs-composite.txt`).
The 37 more are a straight source with alpha → Gray, RGB, and BGR (at the
same depth or wider; 16 bits to 8 had already changed), and RGBA f32 → the
integer formats without alpha.

## Speed

An interleaved A/B with the harness's method: `convert-rounding-20261101/ab.sh`
is `just bench-compare`'s checksums, peak RSS, and rounds, with the arms
given as binaries. The arms were this change (`image`), the same bench arm
built at 98d1033 (`before`), Wuffs, and Go. They ran as servers pinned to
core 3 (`taskset`) over 20 rounds after a sizing round. Each row's arms ran
back to back in a rotating order, with 50 ms samples. The CPU was an Intel
Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512, a shared cloud host). Builds:
Zig 0.16.0 ReleaseFast for this CPU, Wuffs `cc -O3 -march=native` (GCC
16.2), Go 1.26 `GOAMD64=v3`. Each ratio is the geomean over a size class's
rows of each row's median paired ratio (bench/summary.awk). Above 1, `image`
is faster. Raw output is in `ab/`.

| op / size          | image MP/s | before MP/s | image / before | image / Wuffs | before / Wuffs | Wuffs MP/s |
| ------------------ | ---------: | ----------: | -------------: | ------------: | -------------: | ---------: |
| RGBA16→RGBA8 ≤64²  |       8943 |        2497 |           3.63 |      **2.49** |           0.69 |       3542 |
| RGBA16→RGBA8 ≤1 MP |       4307 |        2318 |           1.87 |      **1.47** |           0.79 |       2949 |
| RGBA16→RGBA8 >1 MP |       1598 |         826 |           1.90 |      **1.70** |           0.89 |        928 |
| premultiply ≤64²   |       2407 |        2129 |           1.14 |          1.38 |           1.21 |       1737 |
| premultiply ≤1 MP  |       2426 |        2105 |           1.17 |          1.39 |           1.19 |       1749 |
| premultiply >1 MP  |       1896 |        1738 |           1.09 |          1.30 |           1.17 |       1496 |
| RGBA8→RGB8 ≤64²    |      13603 |       13608 |           1.01 |    9.98 (own) |     9.93 (own) |       1370 |
| RGBA8→BGRA8 ≤64²   |      22955 |       22965 |           1.01 |          2.52 |           2.52 |       8990 |
| RGB8→RGBA8 ≤64²    |       8845 |        8894 |           1.01 |          1.13 |           1.13 |       7846 |
| Gray8→RGBA8 ≤64²   |      10163 |       10098 |           1.02 |          1.12 |           1.11 |       9061 |
| all 30 rows        |       5735 |        4833 |           1.19 |          1.70 |           1.43 |            |

- **RGBA16 → RGBA8.** The high byte closes the gap. It was 0.69× and 0.79×
  Wuffs on icons and on images up to a megapixel. It is now 2.49× and 1.47×,
  and 1.70× above a megapixel. Every icon row is at least 3.07× faster than
  before. The kernel is now a shift and a narrowing store where it was a
  rounded divide by 257 in 32-bit lanes.
- **Premultiply** is 9–17% faster than before and 1.30–1.39× Wuffs. The
  truncating form has one more 16-bit operation than the rounding one did;
  why it runs faster was not traced.
- **The other kernels** are within 0.99–1.02× of before, every row's
  interval holding 1. An earlier build computed the general path's stages
  in `Converter.init` even for a pair with a SIMD kernel, and the new choice
  of pivot made that about 5% slower on 16×16 icons. `init` now builds the
  stages only for a pair without a kernel. A 10-round A/B of the two builds
  measured 1.04–1.05× on the icon rows (not kept).
- **Peak RSS** is unchanged: 81.9–193.9 MiB for both builds and 0.9 MiB more
  for Wuffs, all of it the inputs and output buffers. Go uses 105.5–208.4
  MiB.

Every arm's checksums agree on premultiply and RGBA16 → RGBA8 now, so
`bench/ops.tsv` marks them `same`. RGBA8 → RGB8 stays `own`, since Wuffs
composites. All 30 Wuffs rows and Go's 10 agree except RGBA8 → RGB8's 5
(`ab/checksums.txt`).

**With `composite.patch`** (`ab-composite/`, the same method and machine,
20 rounds), RGBA8 → RGB8 matches Wuffs and becomes `same` too. It costs a
premultiply per pixel: 2143, 2159, and 1666 MP/s by size class, which is
0.17×, 0.34×, and 0.52× the drop-alpha shuffle, and 1.66×, 1.66×, and 1.49×
Wuffs. The other rows match this branch within noise.

## For the owner

Compositing onto black for formats without alpha is the one conversion
where this branch still differs from Wuffs. Wave 0 chose to drop alpha
(plan.md, "dropping alpha drops it"). qoi.h, stb_image, and libpng's
strip-alpha drop it too, and Wuffs and Go composite. `composite.patch`
switches to Wuffs's rule. It touches `src/convert.zig` (the pivot and a
compositing RGBA → RGB kernel) and two QOI files this branch does not own:

- `src/qoi/Decoder.zig`: RGB8 from a four-channel file goes through the
  converter instead of the direct path, which drops alpha. Otherwise the
  fuzz property `FormatDiffers` fires within seconds.
- `test/oracle/qoi.zig`: qoi.h's RGB answer for a four-channel file is left
  out, as its alpha answer for a three-channel file already is. Without
  that, an input where Wuffs's index split meets alpha agrees with neither
  oracle: 127 mismatches in `just oracle 20000 1`.

With the patch applied on wave 0's tree plus this change: `zig build test`
passes, `just fuzz 60` finds nothing, and `just oracle 20000 1` reports 0
mismatches.

## Files

- `convert-rounding-20261101/probe.sh OUT [REPO]` builds and runs
  `wuffs-probe` against REPO's `src/convert.zig`, and the Go comparison, in
  the dev shell. `wuffs-*.txt` and `go-*.txt` are its output for 98d1033
  (`before`), this branch (`after`), and the patch (`composite`).
- `changed-pairs.zig`, `changed-pairs.txt`, and `changed-pairs-composite.txt`:
  the before/after comparison over all 400 pairs.
- `ab.sh`, with `ab/` and `ab-composite/`: the A/B. Run it as `ab.sh OUT 20
image=zig-out/bin/bench-image before=OLD/zig-out/bin/bench-image
wuffs=zig-out/bin/bench-wuffs go=zig-out/bin/bench-go` after `just
bench-build`. Each directory has `config.txt`, `checksums.txt`, `rss.txt`,
  `benchstat.txt`, `summary.txt` (image against each arm),
  `summary-before.txt` (before against Wuffs and Go), `rows.txt`, and every
  sample in `raw-<arm>.txt`.
- `composite.patch`: compositing onto black, for the owner.

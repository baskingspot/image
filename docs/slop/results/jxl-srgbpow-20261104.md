# JPEG XL decode: sRGB's power without division, 2026-11-04

A change to `image.jxl.Decoder`'s XYB to sRGB transform on
`wave4-jxl-srgbpow`, measured against the oracle tolerance of plan.md
decision 78 (peak 8 for frames drawn in floats). It is not bit for bit: it
moves 0.038% of 16-bit samples by a step, and no file's largest difference
from libjxl.

`srgbV` took a^(1/2.4) as a^(1/4) · a^(1/6): a cube root (a guess from the
exponent's bits, two Newton steps for a^(-1/3) and a last one for the
root itself, with a division), then three square roots. Square roots and
divisions share one slow unit, so four of them per eight samples were most
of the curve's cost.

**The change.** a^(1/2.4) = a^(5/12) = √(a · a^(-1/6)). a^(-1/6) comes
from a guess from the exponent's bits, `0x4a0e2000 − bits / 6` (within
3.1% over the six octaves the guess repeats on; the constant minimizes the
largest error), and three Newton steps for x^(-6) = a, which need no
division: r ← r · (7/6 − a/6 · r^6). Three steps take 3.1% to 3.2e-3,
3.6e-5, and below a float's ulp. Then one square root. `cbrtV` goes, and a
unit test now checks the vector sRGB curve against the scalar one (1e-6
relative).

## Results

Accuracy over a ∈ [0.0031308, 64), 5.8 million samples, in 16-bit steps of
the encoded value against f64 (`jxl-srgbpow-20261104/microbench.txt`):
the old curve 0.070 steps at most, the new 0.076; the two quantize away
from the f64 answer on 5,992 and 7,828 samples (0.10% and 0.14%). Speed of
the curve alone, eight samples at a time on one core: 0.87 → 0.61 ns a
sample (the host was busy with other work; an earlier run gave 0.78 →
0.55).

Against libjxl, RGBA16, the first frame of 109 JPEG XL files (the
conformance suite, `corpus/vendor/generated/jxl`, the bench's lossy files
under 1 MiB, and the two fuzzed out-of-gamut XYB files of decisions 77 and
78; `vs-libjxl.txt`, columns: largest difference from libjxl before and after, samples
that changed, samples, file, largest change): 128,930 of 342.6 million samples change, none
by more than a step, and no file's largest difference from libjxl moves
(52 on the spline animations, 5 on 27366ec7…, 4 on 9377fe64…, 3 or less
elsewhere). The 100,000-input oracle agrees on every input
(`just oracle 100000`, in the branch's gates).

Speed, geometric means of the rows' medians, MP/s; peak RSS of the whole
operation, MiB:

| run | operation (rows)          | before | after | change | peak RSS      |
| --- | ------------------------- | ------ | ----- | ------ | ------------- |
| 1   | `jxl-decode` (44), 8 rds  | 22.07  | 22.28 | +0.96% | 483.8 → 483.8 |
| 2   | `jxl-decode` (44), 12 rds | 20.87  | 21.25 | +1.86% | 483.8 → 483.8 |

Both runs are near the ±1.5% an A/A run measured
(`jxl-speed4-20261103.md`), with no row slower: run 2 has two rows faster
at p < 0.05 (a 64×64 icon +4.5%, the 1152×858 wikipedia photo +4.2%).
The size fits the curve's cost: 0.25 ns saved a sample a channel is about
0.75 ns a pixel, 1.5% of the 47 ns a pixel a lossy decode takes at
21 MP/s. Lossless and JPEG rebuilds do not use the curve.

Method: `bench-image serve` builds side by side on the last core
(`taskset -c 3`), loops sized once (`BENCHTIME_MS=50`), 8 and 12 rounds
alternating which build goes first per row, benchstat (median MP/s,
Mann-Whitney U), and GNU time's peak RSS per size class. Checksums differ
by design, so the A/B ran with its checksum comparison off (`NOCHECK=1`).

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0. Base: `wave4-jxl-tol8`
(1fb635d, main 3892641 and the oracle change).

Raw output in `jxl-srgbpow-20261104/`: `lossy-*` is run 1, `lossy2-*`
run 2, `microbench.zig.txt` the curve's accuracy and timing program.

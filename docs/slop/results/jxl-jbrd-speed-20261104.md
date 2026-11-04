# JPEG XL JPEG reconstruction: the writer's speed pass, 2026-11-04

Changes to `src/jxl/jbrd.zig`'s JPEG writer and
`src/jxl/JpegReconstructor.zig` on `wave4-jxl-jbrd-speed`, each measured
against the build before it, after the JPEG XL orb's speed passes on
`Decoder.decodeJpeg`. Found by profiling a rebuild of the 1313×4755
screenshot and the 1260×806 photo, baseline and progressive, with `perf
record` (a scratch driver calling `run` in a loop, pinned to one core). On
origin/main the jbrd side (everything but `decodeJpeg`) took about 40% of
a baseline rebuild and 60% of a progressive one: the writer's
`jbrd.write`, `State.symbol`, and `State.dcDiff` about 30% of the baseline
screenshot's samples, and `conform`'s range check, inlined into `run`,
another 9%.

1. **`conform`'s range check.** The bound (any coefficient past ±4095 is
   refused) returned from inside a scalar loop over every coefficient,
   which kept the compiler from vectorizing it. It is now a 64-lane
   minimum and maximum, checked once a component. Its DC clamp to ±2047
   is gone: `decodeJpeg` now clamps DC itself, as libjxl does, and padding
   blocks stay zero.
2. **Bits and symbols.** The entropy-coded bits went out a byte at a time
   through `Io.Writer.writeByte`, with a 0xFF check per byte, and every
   symbol was a call followed by a second write for its magnitude bits.
   `BitOut` now holds up to 31 bits between calls in a 64-bit accumulator
   and writes 32 at a time, straight into the writer's buffer when it has
   room and none of the four bytes is 0xFF (byte by byte with stuffing
   otherwise, so a writer with no buffer, such as the oracle's discarding
   one, still works); a symbol and its magnitude bits are one write (at
   most 16 + 15 bits). A sequential block is put in zigzag order with one
   64-lane shuffle, and its nonzero AC coefficients become a 64-bit mask
   walked with count-trailing-zeros, so a zero run costs nothing per
   coefficient.
3. **Progressive scans.** The same mask walk for AC first scans (positions
   nonzero after the approximation shift) and AC refinement scans (where
   the zero run counts only zero positions, positions already nonzero
   leaving it be); each scan works out its components' block layout (the
   blocks a row, and in an MCU) once instead of per block, and walks MCUs
   in rows and columns instead of dividing an MCU index per MCU.
4. **Rejected: `zigzagged` inline.** Inlining the shuffle into the scan
   loop measured 6.4% slower on progressive sources (more spills in an
   already crowded loop), so it stays a call.

Each output is the same JPEG, byte for byte: every build's `bench-image
check` matches origin/main's on all 88 rows, and the jxl_jbrd oracle is at
0 mismatches.

Method: the `bench-image` binaries from `zig build bench` (ReleaseFast for
this CPU) of each build, each running `bench-image bench jxl-jbrd
jxl-jbrd-progressive` on the last core (`taskset -c 3`, 50 ms a row), the
two builds alternating 8 rounds with the order flipped each round,
compared with benchstat (median MP/s, p from a Mann-Whitney U test, n =
8). Against libjxl: `just bench-compare 10 jxl-jbrd jxl-jbrd-progressive`
on the final build (libjxl 0.12.0, `JxlDecoder` with no runner, as djxl
writes a .jpg; bench/c/libjxl-jbrd.c). Operations: 44 files each,
`cjxl --lossless_jpeg=1` from cjpeg's baseline and progressive JPEGs at
quality 85, from `bench/corpus-gen/jxl_jbrd/`.

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0. Base: origin/main df313fa;
the branch was then rebased onto 6cf7a57, whose change (streamed
upsampled bands) is off the jbrd path, where frames are not upsampled.

Raw output in `jxl-jbrd-speed-20261104/`: for each comparison (`c1` to
`c4`, and `all`, origin/main against the final build) the benchstat table
and each build's rows (`*-before.txt`, `*-after.txt`); `vs-libjxl-*.txt`
are `just bench-compare`'s summary, rows, benchstat, raw samples, peak
RSS, and configuration.

## Results

Geometric means of the rows' medians, MP/s, each change against the build
before it, and the 50-megapixel mosaic's row:

| change               | operation   | before | after | change | mosaic            |
| -------------------- | ----------- | ------ | ----- | ------ | ----------------- |
| 1. range check       | baseline    | 60.45  | 63.68 | +5.3%  | 84.2 → 96.6       |
|                      | progressive | 42.77  | 44.04 | +3.0%  | 53.9 → 59.6       |
| 2. bits and symbols  | baseline    | 63.08  | 75.23 | +19.3% | 94.3 → 114.2      |
|                      | progressive | 43.84  | 45.07 | +2.8%  | 58.2 → 58.8 (~)   |
| 3. progressive scans | baseline    | 74.91  | 76.90 | +2.7%  | 115.1 → 116.7 (~) |
|                      | progressive | 44.52  | 62.35 | +40.0% | 58.3 → 85.1       |
| 4. inline (rejected) | baseline    | 78.05  | 76.92 | −1.5%  | 119.4 → 118.6 (~) |
|                      | progressive | 62.70  | 58.72 | −6.4%  | 88.7 → 82.0       |
| all (1 to 3)         | baseline    | 60.51  | 77.04 | +27.3% | 82.7 → 118.2      |
|                      | progressive | 42.37  | 62.12 | +46.6% | 54.3 → 87.9       |

(~: within the noise, p > 0.05.) No row is significantly slower in `all`;
16- and 32-pixel icons gain up to 10%.

Against libjxl, after the changes (a ratio above 1 is faster than libjxl;
the median paired ratio over 10 rounds, geometric mean over rows):

| operation, rows (count)    | image MP/s | vs libjxl |
| -------------------------- | ---------- | --------- |
| baseline, icons (13)       | 26.2       | 2.27      |
| baseline, to 1 MP (23)     | 119.0      | 1.03      |
| baseline, over 1 MP (8)    | 122.5      | 0.95      |
| progressive, icons (13)    | 24.9       | 2.66      |
| progressive, to 1 MP (23)  | 89.7       | 1.64      |
| progressive, over 1 MP (8) | 94.4       | 1.60      |
| all (88)                   | 68.8       | 1.55      |

The mosaic rebuilds at 117.4 MP/s against libjxl's 115.6 baseline
(1.02×, within the noise) and 86.9 against 54.2 progressive (1.60×). The
slowest rows are 0.90× (the 999×772 pngimg air pump, baseline) and
0.91× (the 1200×1200 Tecnick photo, baseline).

Peak RSS, MiB, of one pass over each class's inputs (unchanged by these
changes: the writer allocates nothing and the range check reads in
place):

| operation, class       | image | libjxl |
| ---------------------- | ----- | ------ |
| baseline, icons        | 3.4   | 8.3    |
| baseline, to 1 MP      | 15.5  | 19.7   |
| baseline, over 1 MP    | 547.3 | 558.0  |
| progressive, icons     | 3.4   | 8.3    |
| progressive, to 1 MP   | 15.5  | 19.6   |
| progressive, over 1 MP | 547.3 | 554.5  |

Where the time goes now (the scratch driver, best of 60 rebuilds of the
1260×806 photo, baseline, 16.1 ms on origin/main and 13.8 ms after):
the codestream decoder's coefficient pass (`frame.passGroup`,
`vardct.Jpeg.onBlock`, `modular.decodeStream`, and their helpers) takes
about 77% of the samples and the writer about 16% (`State.scan` 13.2%,
`BitOut.word` 1.3%, `State.dcDiff` 1.3%). On the progressive screenshot
(85.5 ms on origin/main, 61.6 ms after) the writer is about 37%: every
block passes through each of its component's scans, about ten in cjpeg's
default script, each a zigzag shuffle, a shift, and two compares before
the mask walk. The next gains for baseline are in `decodeJpeg` (the JPEG
XL orb's); for progressive, sharing one zigzag pass across a block's
scans is measured below.

## Sharing the zigzag pass across a block's scans

The progressive writer puts each block in zigzag order once per scan it
is in, about ten times in cjpeg's default script. Two ways to do it once,
measured as before (8 interleaved rounds, `taskset -c 3`, benchstat) on
origin/main 9bf9d88, the build after the changes above; the raw output is
`c5-*` and `c6-*` in the same directory:

5. **In `conform`, rejected.** `conform` already loads every block for
   the range check; storing the block back in zigzag order there, with
   the writer loading it as it is, adds a store pass over all the
   coefficients (150 MB on the mosaic) and saves less than it costs.
6. **In `decodeJpeg`, kept as a patch for the JPEG XL orb.**
   `Jpeg.onBlock` already gathers each block from the transform's
   transposed layout; gathering it in zigzag order instead costs nothing
   (the same 64 loads through a different constant table, with the
   chroma from luma ratios held in the same order), and the writer then
   loads each block as it is. The change touches `vardct.zig`, the JPEG
   XL orb's, and must land in one commit with the writer's side, so it
   is `c6-zigzag-order.patch` (with `vardct.zig`'s test comparing in
   zigzag order); with it applied, `just test` and `just test-be` pass
   and `just oracle 100000 1 jxl_jbrd` agrees on 100,120 of 100,120.

| change          | operation   | before | after | change | rows faster / slower | mosaic            |
| --------------- | ----------- | ------ | ----- | ------ | -------------------- | ----------------- |
| 5. in `conform` | baseline    | 78.97  | 77.35 | −2.1%  | 0 / 15               | 121.3 → 116.8     |
|                 | progressive | 63.90  | 63.42 | −0.8%  | 1 / 5                | 91.3 → 88.8 (~)   |
| 6. in `onBlock` | baseline    | 79.61  | 80.31 | +0.9%  | 8 / 0                | 122.2 → 122.3 (~) |
|                 | progressive | 63.89  | 65.56 | +2.6%  | 15 / 0               | 93.2 → 94.7 (~)   |

(Rows faster or slower: of 44 an operation, at p ≤ 0.05.) Neither
changes memory. The gain is small because the shuffle was small: one
64-lane permute, about 3% of a progressive rebuild's samples
(`zigzagged`, from `perf record` over the progressive rows). Most of the
progressive writer's time is in AC refinement's correction bits, which
go in and out of `scratch` a bit at a time; holding a block's bits in a
register and writing them in one put is the next candidate.

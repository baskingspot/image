# Rotating icon rows: do PNG's and QOI's icon numbers move?

2026-11-02, Intel Xeon @ 2.60GHz (4 threads, an Amp orb), every arm pinned to
core 3. Raw output is in `icon-rotation-20261102/`. Measured on 9caf0db,
before performance pass 1 changed QOI's and PNG's decoders (0469a46 and the
PNG commits before it).

## Question

A row times one file again and again. On a 16×16 icon a call is a few hundred
nanoseconds, and the branch predictor can learn that one file's branches, so
an icon row may measure a memorized file rather than a decoder. The rotating
rows (`png-decode-icons`, `qoi-decode-icons`, bench/README.md) cycle through
64 distinct icons of one size, from `bench/corpus/icons.sh`.

## Method

1. `just bench-compare 5 png-decode png-decode-icons qoi-decode qoi-decode-icons`:
   the usual rounds, every arm. `summary.txt`, `benchstat.txt`,
   `compare-raw-*.txt`.
2. Alone against rotating on the same files: `bench/ops.tsv` pointed for the
   run at `png-decode` and `qoi-decode` on `icons/png` and `icons/qoi`, so
   each of the 64 icons per size is also its own row, and
   `bench-<arm> bench png-decode png-decode-icons qoi-decode qoi-decode-icons`
   at `BENCHTIME_MS=30`, three passes over the arms, pinned with `taskset -c 3`. A row's time is the median of the passes;
   "alone" is the mean time per call over the 64 single-file rows, which is
   what a rotating call would cost if nothing were memorized.
   `alone-vs-rotating-*.txt`.
3. The harness cost of cycling an index in every timed loop: qoih's arm built
   from the previous `arm.c` and from this one, six interleaved runs of
   `qoi-decode` on the 16×16 icons. `harness-before.txt`,
   `harness-after.txt`, `harness-benchstat.txt`.

## Results

Time per call, alone and rotating, on the same 64 icons, and this package's
throughput over each bar library's (higher is better for us):

| Row       | image alone | image rotating | slowdown | image/wuffs alone → rotating | image/libpng or qoih alone → rotating |
| --------- | ----------: | -------------: | -------: | ---------------------------: | ------------------------------------: |
| PNG 16×16 |     9463 ns |       12930 ns |    1.37× |                  0.73 → 0.72 |                    libpng 1.08 → 1.15 |
| PNG 32×32 |    19422 ns |       24899 ns |    1.28× |                  0.70 → 0.71 |                    libpng 1.27 → 1.44 |
| PNG 64×64 |    47477 ns |       64748 ns |    1.36× |                  0.69 → 0.68 |                    libpng 1.58 → 1.50 |
| QOI 16×16 |      507 ns |        1041 ns |    2.06× |                  2.17 → 1.64 |                      qoih 1.55 → 1.13 |
| QOI 32×32 |     1752 ns |        4369 ns |    2.49× |                  1.89 → 1.49 |                      qoih 1.56 → 1.32 |
| QOI 64×64 |     9775 ns |       14924 ns |    1.53× |                  1.10 → 1.43 |                      qoih 0.96 → 1.38 |

In MP/s, image's rotating rows are 19.8, 41.1, and 63.3 for PNG and 245.9,
234.4, and 274.5 for QOI, against 27.1, 52.7, 86.3 and 505.3, 584.6, 419.0
alone. Every arm slows down when it rotates: PNG by 1.3–1.5× (wuffs 1.35,
1.31, 1.35; libpng 1.46, 1.45, 1.29; spng 1.49, 1.53, 1.36) and QOI by
1.5–2.5× (wuffs 1.55, 1.97, 1.97; qoih 1.50, 2.12, 2.19).

In the `bench-compare` run, the geometric means of the icon class:
`PngDecode/icon` 53.8 MP/s and image/wuffs 0.69 (17 rows, one file each);
`PngDecodeIcons/icon` 38.5 MP/s and 0.72; `QoiDecode/icon` 401.2 MP/s and
image/wuffs 1.53, image/qoih 1.17; `QoiDecodeIcons/icon` 248.0 MP/s,
1.49, and 1.26.

The harness change costs nothing measurable: qoih's 16×16 QOI rows have a
geometric mean of 344.2 ns before and 346.1 ns after (+0.56%; benchstat finds no row different, p ≥ 0.065).

## Conclusion

- **PNG's icon numbers do not move against its bars.** Every arm loses about a
  third of its single-file speed, and image/wuffs stays at 0.68–0.73 alone
  and rotating. The single-file PNG icon rows rank the arms correctly.
- **QOI's do.** A QOI call on a small icon is short enough that the memorized
  file is most of the speed: every arm runs 1.5–2.5× slower rotating, and
  this package more than the others at 16 and 32 pixels, where its lead over
  Wuffs shrinks from 2.2× and 1.9× to 1.6× and 1.5×, and over qoi.h from 1.55×
  to 1.13× and 1.32×. At 64 pixels the reverse: it loses less than they do and
  its lead grows. QOI icon claims should cite the rotating rows.
- Keep the single-file rows: they are per-file regressions, and the
  rotating rows are the icon numbers to quote.

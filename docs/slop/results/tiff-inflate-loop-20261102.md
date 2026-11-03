# TIFF Deflate and PNG decode: compress's input cursor in the fast loop, 2026-11-02

`tiff-deflate-20261102.md` left photographs as the TIFF Deflate rows
under libtiff (0.79–0.81), with the time in compress's fast decode loop,
which libdeflate runs about 1.3× faster on literal-heavy streams.
compress commit e383aa8
(`docs/slop/results/flate-fast-loop-photos-20261102.md` in that
repository) reads the loop's input through a cursor instead of a slice
and an index, so the loop keeps one fewer value live; inflate alone gains
3–4% on photographs' strips and PNG streams and 9–17% on long-run
images. This branch moves the pin from 364ef40 to it; nothing in this
package changes.

Two further loop changes were measured here and dropped in compress
(that file has the numbers): copying a match's first 32 bytes
unconditionally gained about 3 more points on photographs but made the
256×256 test card's rows 3–4% slower in this package's TIFF decode,
though its strips inflated faster alone; and looking up the next symbol
before a match's copy cost the 128×128 water texture's row 6%.

## Method

`run.sh` runs `ab.sh` from `convert-tails-20261102/` (the
`bench-compare` method: checksums, peak RSS of one pass, then rounds that
time every arm on a row back to back in a rotating order, pinned to one
core, `CORE=3`), 8 rounds of 50 ms samples: `bench-image` built against
the new compress (`image`) and against 364ef40 (`before`), beside
libtiff, the `tiff` crate (through `image-rs`), and Go for
`tiff-decode-deflate` (44 files), and beside Wuffs, libspng, and libpng
for `png-decode` (52 files) and `png-decode-icons` (3). A ratio is this
build's throughput over the arm's, the geometric mean over a class's
rows of each row's median paired ratio. `tiff/` and `png/` hold each
run's `summary.txt`, `summary-before.txt` (the build before against the
arms), `rows.txt`, `benchstat.txt`, `rss.txt`, `checksums.txt`,
`config.txt`, and the benchstat inputs for this build, the build before,
and libtiff or Wuffs.

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host, so only paired ratios are steady; Linux 6.1, Zig 0.16.0 ReleaseFast
for this CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`, Go
`GOAMD64=v3`. Every arm's checksums match on every row of both runs.

Classes: icons (at most 64×64), to 1 MP, and larger.

## TIFF Deflate

| class   | rows | MP/s  | vs before | vs libtiff (before) | vs tiff crate | vs Go |
| ------- | ---- | ----- | --------- | ------------------- | ------------- | ----- |
| icons   | 13   | 119.3 | 1.00      | 2.15 (2.15)         | 2.04          | 4.49  |
| to 1 MP | 23   | 208.0 | 1.03      | 1.16 (1.13)         | 2.58          | 5.16  |
| larger  | 8    | 159.2 | 1.02      | 1.06 (1.05)         | 2.34          | 4.40  |

No row is slower than before (none below 1 at p < 0.05). Most
photographs gain 2–5% (kodim01 1.05, the 50-megapixel mosaic 1.03) and
remain the rows under libtiff: 12 photographs from 0.80 (tecnick 002) to
0.87 (kodim03), 0.79 to 0.84 before, and academy_awards at 0.95 (0.92
before).

Peak RSS is unchanged: 253.9 MiB for a pass over the 44 files, both
builds (libtiff 256.7, the tiff crate 593.2, Go 620.3).

## PNG decode

| class          | rows | MP/s  | vs before | vs Wuffs (before) | vs libspng | vs libpng |
| -------------- | ---- | ----- | --------- | ----------------- | ---------- | --------- |
| icons          | 17   | 122.1 | 1.01      | 1.45 (1.44)       | 2.43       | 2.68      |
| to 1 MP        | 27   | 199.6 | 1.03      | 1.34 (1.31)       | 2.38       | 2.53      |
| larger         | 8    | 165.7 | 1.03      | 1.34 (1.31)       | 2.15       | 2.26      |
| icon rotations | 3    | 87.6  | 1.03      | 1.62 (1.57)       | 2.88       | 3.07      |

No row is slower than before (none below 1 at p < 0.05; the slowest
median, 0.97, has the interval [0.91, 1.07]), and small PNGs hold their
speed. Peak RSS: 240.1 MiB for `png-decode` and 3.2 MiB for the icons,
both builds.

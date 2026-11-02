# TIFF Deflate and PNG decode: compress's short-stream inflate, 2026-11-02

`tiff-speed-20261102.md` left TIFF Deflate at 0.95× libtiff to 1 MP and
0.93× above, with inflate the rest of the gap: libtiff inflates with
libdeflate, and on libtiff's 8 KiB strips a block's setup (the Huffman
table builds and the dynamic header) was about 10% of `compress`'s
inflate time. compress commit 364ef40
(`docs/slop/results/flate-short-streams-20261102.md` in that repository)
builds the tables from per-length bit masks instead of counting and
sorting the symbols, reads the dynamic header from a 64-bit bit buffer,
and folds Adler-32 with two vector adds a chunk. This branch moves the
pin from 6319823 to it; nothing in this package changes. The `image`
arm was built against that commit's tree before it was rebased over an
unrelated brotli commit, with the same flate and zlib sources.

## Method

`run.sh` runs `ab.sh` from `convert-tails-20261102/` (the
`bench-compare` method: checksums, peak RSS of one pass, then rounds that
time every arm on a row back to back in a rotating order, pinned to one
core, `CORE=3`), 8 rounds of 50 ms samples: `bench-image` built against
the new compress (`image`) and against 6319823 (`before`), beside
libtiff, the `tiff` crate (through `image-rs`), and Go for
`tiff-decode-deflate` (44 files), and beside Wuffs, libspng, and libpng
for `png-decode` (52 files) and `png-decode-icons` (3). A ratio is this
build's throughput over the arm's, the geometric mean over a class's
rows of each row's median paired ratio. `tiff/` and `png/` hold each
run's `summary.txt`, `summary-before.txt` (the build before against the
arms), `rows.txt`, `benchstat.txt`, `rss.txt`, `checksums.txt`,
`config.txt`, and the benchstat inputs.

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host, so only paired ratios are steady; Linux 6.1, Zig 0.16.0 ReleaseFast
for this CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`, Go
`GOAMD64=v3`. Every arm's checksums match on every row of both runs.

Classes: icons (at most 64×64), to 1 MP, and larger.

## TIFF Deflate

| class   | rows | MP/s  | vs before | vs libtiff (before) | vs tiff crate | vs Go |
| ------- | ---- | ----- | --------- | ------------------- | ------------- | ----- |
| icons   | 13   | 100.9 | 1.18      | 2.16 (1.83)         | 2.04          | 4.67  |
| to 1 MP | 23   | 172.5 | 1.19      | 1.12 (0.94)         | 2.49          | 5.10  |
| larger  | 8    | 129.9 | 1.11      | 1.02 (0.92)         | 2.28          | 4.26  |

No row is slower than before. Photographs remain the rows under libtiff
(14 of 44, from 0.79 on the 50-megapixel mosaic to 0.81 on kodim01, from
0.75 before); the time there is compress's fast decode loop, which
libdeflate runs about 1.3× faster on literal-heavy streams.

Peak RSS is unchanged: 253.9 MiB for a pass over the 44 files, both
builds (libtiff 256.6, the tiff crate 593.2, Go 619.9).

## PNG decode

| class          | rows | MP/s  | vs before | vs Wuffs (before) | vs libspng | vs libpng |
| -------------- | ---- | ----- | --------- | ----------------- | ---------- | --------- |
| icons          | 17   | 104.9 | 1.15      | 1.47 (1.27)       | 2.46       | 2.72      |
| to 1 MP        | 27   | 167.1 | 1.03      | 1.31 (1.27)       | 2.33       | 2.49      |
| larger         | 8    | 135.1 | 1.03      | 1.30 (1.25)       | 2.03       | 2.16      |
| icon rotations | 3    | 74.2  | 1.20      | 1.58 (1.32)       | 2.80       | 3.00      |

Small PNGs gain the most, and no row is significantly slower than before
(none below 1 at p < 0.05; the slowest median, 0.98 on the gray-alpha
kodim01, has the interval [0.84, 1.07]). Peak RSS: 239.9 MiB for
`png-decode` and 3.0 MiB for the icons, against 240.0 and 3.1 before.

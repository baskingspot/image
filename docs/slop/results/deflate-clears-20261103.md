# TIFF Deflate and PNG encode: compress's encoder clears, 2026-11-03

`memset-20261103.md` left `flate.Writer.initInPlace` at about 1% of
tiff-encode-deflate and png-encode-fast, in baskingspot/compress. compress
commit 61998af (`docs/slop/results/flate-encode-clears-20261103.md` in
that repository) clears the encoder's per-stream emitter state (8 KiB, one
compiler_rt `memset` a stream) and each Huffman tree's 1 KiB scratch (one
`memset` a tree, several a block) with `fastmem.set` instead. Encoding a
TIFF's 8 KiB strips alone gains 3–8% at levels 6 and 7 and 4–28% at level
1, with the same output. This branch moves the pin from e383aa8 to it;
nothing in this package changes.

## Method

`run.sh` runs `ab.sh` from `convert-tails-20261102/` (the
`bench-compare` method: checksums, peak RSS of one pass, then rounds that
time every arm on a row back to back in a rotating order, pinned to one
core, `CORE=3`), 8 rounds of 50 ms samples: `bench-image` built against
the new compress (`image`) and against e383aa8 (`before`), beside
libtiff, the `tiff` crate (through `image-rs`), and Go for
`tiff-encode-deflate` (44 files), and beside libpng and libspng for
`png-encode-fast` and `png-encode` (44 files each). The encoders' outputs
differ by design; this build's and the build before's match on every row.
`tiff/` and `png/` hold each run's `summary.txt`, `summary-before.txt`,
`rows.txt`, `benchstat.txt`, `rss.txt`, `checksums.txt`, `config.txt`,
and the benchstat inputs for this build, the build before, and libtiff or
libpng.

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host, so only paired ratios are steady; Linux 6.1, Zig 0.16.0 ReleaseFast
for this CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`, Go
`GOAMD64=v3`.

Classes: icons (at most 64×64), to 1 MP, and larger.

## TIFF Deflate encode

| class   | rows | MP/s | vs before | vs libtiff (before) | vs tiff crate | vs Go |
| ------- | ---- | ---- | --------- | ------------------- | ------------- | ----- |
| icons   | 13   | 12.3 | 1.05      | 0.83 (0.79)         | 2.04          | 2.32  |
| to 1 MP | 23   | 21.2 | 1.05      | 0.71 (0.68)         | 1.79          | 1.06  |
| larger  | 8    | 16.5 | 1.04      | 0.68 (0.66)         | 1.98          | 0.80  |

No row is slower than before (none below 1 at p < 0.05). Go encodes 28
of the 44 files. Peak RSS is unchanged: 435.1 MiB for a pass, both builds
(libtiff 437.8, the tiff crate 436.8).

## PNG encode

| op              | class   | rows | MP/s | vs before | vs libpng (before) | vs libspng |
| --------------- | ------- | ---- | ---- | --------- | ------------------ | ---------- |
| png-encode-fast | icons   | 13   | 18.0 | 1.04      | 1.53 (1.47)        | 1.39       |
| png-encode-fast | to 1 MP | 23   | 48.8 | 1.01      | 2.06 (2.04)        | 2.78       |
| png-encode-fast | larger  | 8    | 40.9 | 1.00      | 1.96 (1.96)        | 2.58       |
| png-encode      | icons   | 13   | 15.1 | 1.03      | 2.20 (2.13)        | 2.00       |
| png-encode      | to 1 MP | 23   | 24.7 | 1.01      | 3.54 (3.49)        | 4.03       |
| png-encode      | larger  | 8    | 18.0 | 1.00      | 3.45 (3.45)        | 3.79       |

Icons gain 3–4%, where a stream's fixed cost counts most; larger images
hold their speed, and no row is slower than before (none below 1 at
p < 0.05). Peak RSS is unchanged: 387.8 and 387.7 MiB, both builds.

# JPEG XL lossless encode against libjxl, 2026-11-02

`image.jxl.encode` (wave 5, stage 1) against libjxl's lossless encoder
(`cjxl -d 0`), efforts 1 to 9: speed, output size, and peak memory. Every arm
encodes raw 8-bit RGB or RGBA pixels from memory into a bare codestream in
memory per call (`jxl-encode-e1` … `jxl-encode-e9`, bench/ops.tsv, all
`own`: the encoders choose differently, so outputs are compared by size, not
checksum). Ours runs the effort nearest each libjxl effort: `fast` for 1–3,
`default` for 4–7, `best` for 8–9 (bench/zig/jxl_encode.zig).
docs/slop/jxl-encode.md has the encoder's design.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU; libjxl 0.12.0 with
`cc -O3 -march=native`, one thread (no parallel runner), a new encoder per
call. Each arm runs pinned to the last core, the arms interleaved row by row
(`just bench-compare 5 jxl-encode-e1 … jxl-encode-e9`, exit 0; raw output
in `jxl-encode-20261102/`). Inputs: `bench/corpus-gen/jxl_encode`, the 43
sources of the shared corpus without the 50-megapixel mosaic (which libjxl's
slowest efforts take minutes over), RGBA when the source has alpha. Size
classes as bench-compare's: icons (at most 4096 pixels, 13 rows), up to a
megapixel (23), larger (7).

## Size

Total bytes per class over libjxl's at the same effort, and the geometric
mean of the per-file ratios (`size-by-class.txt`, from the check pass; below
1, ours is smaller):

| libjxl effort | ours    | icons total | icons geomean | ≤1 MP total | ≤1 MP geomean | >1 MP total | >1 MP geomean | all total | all geomean |
| ------------- | ------- | ----------- | ------------- | ----------- | ------------- | ----------- | ------------- | --------- | ----------- |
| e1            | fast    | 0.708       | 0.693         | 0.829       | 0.708         | 0.853       | 0.848         | 0.843     | 0.725       |
| e2            | fast    | 0.756       | 0.801         | 0.907       | 0.817         | 0.905       | 0.927         | 0.906     | 0.829       |
| e3            | fast    | 0.762       | 0.759         | 0.988       | 0.880         | 1.016       | 1.004         | 1.004     | 0.860       |
| e4            | default | 0.790       | 0.822         | 0.939       | 0.803         | 0.945       | 0.933         | 0.943     | 0.829       |
| e5            | default | 0.840       | 0.883         | 0.957       | 0.862         | 0.974       | 0.962         | 0.967     | 0.884       |
| e6            | default | 0.865       | 0.903         | 0.983       | 0.900         | 0.989       | 0.976         | 0.986     | 0.913       |
| e7            | default | 0.878       | 0.909         | 1.010       | 0.936         | 1.012       | 1.001         | 1.011     | 0.938       |
| e8            | best    | 0.887       | 0.913         | 0.994       | 0.930         | 1.007       | 0.992         | 1.002     | 0.935       |
| e9            | best    | 0.904       | 0.928         | 0.999       | 0.951         | 1.014       | 0.998         | 1.008     | 0.951       |

All 43 files: fast 16,141,195 bytes, default 14,744,464, best 14,410,096;
libjxl e1 19,152,571, e2 17,825,266, e3 16,073,531, e4 15,642,257, e5
15,251,523, e6 14,949,332, e7 14,585,294, e8 14,384,563, e9 14,300,111.

Against e7, ours at `default` is smaller on most files (geomean 0.938) and
1.1% larger in total. Where it loses: Kodak photos +2.6 to +4.4%,
`screenshot_web-apple_com` +6.7%, `amazon_com` +3.4%, `test-dice` +8.8%.
Where it wins: icons, textures, synthetic images (`textures_pk-_0mod_button1`
0.59, `pngimg-Number_2` 0.66, `screenshot_game-3dbrick2` 0.77).

## Speed

Megapixels per second, each row's median over the 5 rounds, geometric mean
over the class (`mpps-by-class.txt`, made by `mpps-by-class.py` from
`raw-*.txt`): ours / libjxl, and the ratio (above 1, ours is faster).
`summary.txt` gives bench-compare's own geomean of paired ratios, within
0.01 of these.

| libjxl effort | ours    | icons                | ≤1 MP                | >1 MP                | all                  |
| ------------- | ------- | -------------------- | -------------------- | -------------------- | -------------------- |
| e1            | fast    | 0.37 / 1.53 (0.24)   | 6.01 / 132.8 (0.05)  | 5.51 / 240.7 (0.02)  | 2.55 / 37.96 (0.07)  |
| e2            | fast    | 0.36 / 1.73 (0.21)   | 6.01 / 11.39 (0.53)  | 5.49 / 14.75 (0.37)  | 2.53 / 6.72 (0.38)   |
| e3            | fast    | 0.37 / 1.39 (0.26)   | 6.01 / 6.13 (0.98)   | 5.52 / 6.48 (0.85)   | 2.55 / 3.95 (0.64)   |
| e4            | default | 0.146 / 0.684 (0.21) | 1.15 / 2.78 (0.41)   | 1.60 / 2.80 (0.57)   | 0.649 / 1.823 (0.36) |
| e5            | default | 0.146 / 0.530 (0.28) | 1.13 / 1.96 (0.58)   | 1.61 / 2.24 (0.72)   | 0.645 / 1.347 (0.48) |
| e6            | default | 0.145 / 0.447 (0.32) | 1.14 / 1.60 (0.71)   | 1.61 / 1.77 (0.91)   | 0.647 / 1.106 (0.58) |
| e7            | default | 0.147 / 0.344 (0.43) | 1.14 / 1.15 (0.99)   | 1.61 / 1.26 (1.27)   | 0.648 / 0.811 (0.80) |
| e8            | best    | 0.027 / 0.152 (0.18) | 0.241 / 0.392 (0.61) | 0.645 / 0.415 (1.55) | 0.145 / 0.297 (0.49) |
| e9            | best    | 0.027 / 0.105 (0.26) | 0.241 / 0.234 (1.03) | 0.649 / 0.226 (2.87) | 0.146 / 0.182 (0.80) |

libjxl's e1 is a separate fast path, unlike anything here. Icons are where
we trail most. Medians for `icon_64-actions_address_book_new-64x64`: fast
8.3 ms (e3 1.6), default 28 ms (e7 9.4), best 159 ms (e8 24, e9 39). For
the 16×16 one: fast 1.6 ms (e3 0.5), default 3.1 ms (e7 1.3), best 17.5 ms
(e8 2.7). The time goes to tree learning: every node scans a table per
property bucket, predictor, and token. A sweep over the samples instead,
tried for small nodes, gained too little to keep. Judging best's splits
with 2 or 4 predictors instead of all of them took 44–48 s on the corpus
instead of 80 s, for 14.47 MB instead of 14.41 MB (unpinned); all are kept
so best stays at e8's size.

## Peak memory

Peak RSS (MiB) of one pass over each class's inputs through
`bench-<arm> serve` (`rss.txt`): the input and output buffers, which both
arms hold alike, plus the encoder's memory. Ours takes its work memory from
the page allocator, so only touched pages count.

| ours / libjxl effort | icons     | ≤1 MP        | >1 MP         | all rows      |
| -------------------- | --------- | ------------ | ------------- | ------------- |
| fast / e1            | 4.3 / 6.8 | 50.5 / 16.4  | 119.3 / 84.0  | 121.7 / 81.0  |
| fast / e2            | 4.3 / 8.1 | 50.5 / 60.9  | 119.3 / 258.3 | 121.7 / 249.2 |
| fast / e3            | 4.3 / 8.2 | 50.5 / 61.1  | 119.3 / 253.4 | 121.7 / 250.0 |
| default / e4         | 5.1 / 8.3 | 69.9 / 61.3  | 140.7 / 249.3 | 158.3 / 249.2 |
| default / e7         | 5.1 / 8.4 | 69.9 / 66.7  | 140.7 / 260.7 | 158.3 / 260.8 |
| best / e8            | 6.6 / 8.9 | 117.8 / 73.3 | 225.4 / 267.4 | 255.1 / 266.9 |
| best / e9            | 6.6 / 9.0 | 117.8 / 73.3 | 225.4 / 267.0 | 255.1 / 266.9 |

(e5 and e6 are within 0.2 MiB of e7.) Ours uses less on icons and large
images. Up to a megapixel it uses more than libjxl's e2–e9 at `best`, and
more than e1 at every effort. The samples a tree is learned from hold i32
properties: 112 bytes a sample at `best` (2^19 samples, 58 MiB), 100 at
`default` (2^18, 26 MiB). Choosing thresholds from a subsample first and
keeping only the bucket indices would cut that by about four (Next, in
jxl-encode.md).

## Recommended default

`default`, the owner decides. Above icon size it runs at e7's speed (0.99×
up to a megapixel, 1.27× above). It writes 1.1% more bytes in total and
6.2% fewer per file (geomean), and on icons 12% fewer at 0.43× the speed.
`fast` is e3 in speed and total size (0.98× and 0.85× the speed above
icons; 1.004× the bytes, 0.860 geomean). `best` matches e8's total (1.002×)
and is 1.55× faster above a megapixel, but 0.61× up to one and 0.18× on
icons.

## Interoperability

- `just oracle 100000 1 jxl_encode`: 100,000 generated inputs, 74,989
  comparable (the rest mutated), 0 mismatches against libjxl, in 929 s
  (after the rebase onto 9c30bff, which added the `rgb_f32` and
  `gray_f32` sources).
- jxl-oxide 0.12.6 through the bench arms (`check jxl-decode-lossless`, a
  one-off): 117 files from our encoder at every effort decoded identically
  to libjxl. The files covered 12 source formats from 16×16 to 1313×6097,
  one to 120 groups, palette and RCT, with and without alpha, 8- and 16-bit,
  and premultiplied. Our decoder matched on all but the 12 premultiplied
  files, where the bench op un-premultiplies and libjxl does not; the oracle
  compares those premultiplied.
- Before that check, jxl-oxide failed on every multi-group file coded with
  ANS (`UnexpectedEof`). The global stream codes no channel there, and we
  wrote no ANS state for it. jxl-oxide reads one; libjxl and our decoder do
  not. Every stream now writes its state.

## Tuning on the corpus

Single runs of a scratch encoder over the 43 files, one thread, not pinned
(totals of the per-file times), in the order the changes were made. Raw
per-file numbers are not kept; the bench above is the measurement.

| change                                                                            | fast                | default              | best                            |
| --------------------------------------------------------------------------------- | ------------------- | -------------------- | ------------------------------- |
| first working version                                                             | 16,172,928 B, 7.0 s | 14,781,358 B, 27.1 s | 14,388,612 B, 79.8 s            |
| palette only up to an eighth of the pixels (was half)                             |                     | 32–64 px icons −25%  |                                 |
| splits judged with the 2 cheapest predictors (default)                            |                     | 14,713,184 B, 24.3 s | 14,466,358 B, 43.9 s (not kept) |
| u16 counts, thresholds from 1024–4096 samples, vector bucketing, RCT row segments | 16,188,779 B, 6.5 s | 14,744,372 B, 23.4 s | 14,410,004 B, 80.2 s            |

A 64×64 icon went from 46 to 28 ms at `default` and from 200 to 159 ms at
`best` (bench medians below), mostly from per-node costs in tree learning
that no longer scale with the count table.

## LZ77 (not kept)

`jxl-encode-20261102/lz77.patch`, against the encoder as committed: copies
at the special 2D distances and at hashed distances, lengths from just past
the largest literal symbol, chosen by literal costs from the histograms,
then again with the copies' own costs. Taken only when the histograms with
copies cost less in total. Every file still decoded in our decoder (the unit
tests and a round trip through the decoder's entropy reader).

| file                              | without                  | with, default                        | with, best |
| --------------------------------- | ------------------------ | ------------------------------------ | ---------- |
| photo_kodak-kodim03               | 346,515                  | 346,519 (guarded; 347,452 unguarded) |            |
| screenshot_web-apple_com          | 1,182,439                | 1,185,879 to 1,188,317 (unguarded)   |            |
| screenshot_game-20XX_Menu_picture | 84,688 / 84,648 (best)   | 84,692                               | 84,974     |
| test-dice                         | 147,929 / 133,528 (best) | 147,599                              | 133,879    |
| textures_pk-_0mod_button1         | 2,898 / 2,842 (best)     | 2,916                                | 2,862      |
| screenshot_game-3dbrick2          | 2,039 (best)             |                                      | 2,096      |
| test-qoi_logo                     | 3,999 (best)             |                                      | 3,940      |

Encoding took 20–50% longer. The MA tree already gives runs of residuals
contexts where they cost a fraction of a bit. A copy takes tokens out of a
context, so the rest cost more, and the per-token estimate misses it. The
first version also put lengths at symbol 224, which made every histogram
holding one describe 170 empty symbols (+830 bytes on kodim03 for nine
copies). An exact guard would need a second write pass.

## Files

`jxl-encode-20261102/`: `config.txt`, `check-image.txt` and
`check-libjxl.txt` (lengths and hashes per row), `size-by-class.txt` (made
by `size-by-class.sh`), `rss.txt`, `rows.txt`, `summary.txt`,
`benchstat.txt`, the raw benchmark lines (`raw-*.txt`), `mpps-by-class.txt`
(made by `mpps-by-class.py`), and `lz77.patch`.

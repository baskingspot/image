# TIFF encode against libtiff, 2026-11-02

`image.tiff.encode` (wave 5) against libtiff 4.7.2, the bar, and the
comparison arms Rust's `image` 0.25.9 (its `TiffEncoder` for uncompressed
files, which is all it writes, and the `tiff` 0.10.3 crate it builds on for
the compressed rows) and Go's `golang.org/x/image/tiff`. Every arm encodes
raw pixels from memory into a buffer per call (bench/ops.tsv:
`tiff-encode-none`, `-packbits`, `-lzw`, `-deflate`). Throughput is
megapixels per second; a ratio is this package's throughput over the arm's
(above 1, ours is faster), the geometric mean over rows of each row's
median paired ratio. docs/slop/tiff-encode.md has the encoder's design.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host, so only paired ratios are steady), Linux 6.1, Zig 0.16.0 ReleaseFast
for this CPU; C arms `cc -O3 -march=native`, Rust `target-cpu=native`, Go
`GOAMD64=v3`.

Inputs, `bench/corpus-gen/qoi_encode/` (bench/corpus/qoi_encode.sh, the QOI
encode rows' inputs): every shared source as raw 8-bit pixels, RGBA when it
has alpha (28 files) and RGB otherwise (16), from 16×16 icons to the
50-megapixel mosaic. Settings, the same in every arm that has them: 8-bit
samples, straight alpha (ExtraSamples 2), strips of libtiff's default 8 KiB
(`TIFFDefaultStripSize`), Predictor 2 with LZW and Deflate, Deflate at zlib
level 6 (libtiff's default; `compress` has only levels 1 and 6, so ours is
its level 6 too), no palette. Arms that differ: the `tiff` crate writes
strips of about 1 MB; Go writes one strip, Deflate without a predictor (it
predicts only for LZW, which it does not write), no PackBits or LZW, and no
RGB (it has no RGB image type), so its rows are the 28 RGBA files.

## On the pushed code

`just bench-compare 10 tiff-encode-none tiff-encode-packbits
tiff-encode-lzw tiff-encode-deflate` (exit 0) on the branch rebased onto
main 47dc0a3, whose `compress` (6319823) has the lazy deflate levels, so
`Effort.default` is level 7 with the filtered strategy, as in the PNG
encoder. `compare/summary.txt`:

| rows (count)       | image MP/s | vs libtiff | vs image-rs | vs Go |
| ------------------ | ---------: | ---------: | ----------: | ----: |
| none, icons (13)   |     1652.4 |      13.84 |        1.27 |  2.47 |
| none, to 1 MP (23) |     4252.1 |       1.15 |        0.77 |  0.82 |
| none, large (8)    |     2200.0 |       0.95 |        0.82 |  0.84 |
| PackBits, icons    |      131.4 |       2.80 |        1.34 |     - |
| PackBits, to 1 MP  |      177.6 |       1.49 |        1.09 |     - |
| PackBits, large    |      147.2 |       1.49 |        0.97 |     - |
| LZW, icons         |       37.8 |       1.70 |       24.66 |     - |
| LZW, to 1 MP       |       41.4 |       1.25 |        2.13 |     - |
| LZW, large         |       40.2 |       1.31 |        2.00 |     - |
| Deflate, icons     |       10.4 |       0.73 |        1.03 |  2.33 |
| Deflate, to 1 MP   |       18.5 |       0.62 |        1.59 |  1.11 |
| Deflate, large     |       14.3 |       0.60 |        1.75 |  0.82 |
| all (176)          |      127.9 |       1.39 |        1.59 |  1.39 |

Headline: LZW 1.25–1.70× libtiff and PackBits 1.49–2.80×, uncompressed
0.95–13.8×, Deflate 0.60–0.73×. Deflate at `Effort.fast` (level 6, greedy)
is 0.81–0.92× libtiff and makes files 1.2% larger than the default
(`effort/`, a 5-round A/B of the two efforts and libtiff):

| Deflate rows | default MP/s | fast MP/s | default vs fast | fast vs libtiff |
| ------------ | -----------: | --------: | --------------: | --------------: |
| icons        |         10.7 |      12.6 |            0.85 |            0.89 |
| to 1 MP      |         19.0 |      24.2 |            0.78 |            0.81 |
| large        |         14.6 |      21.8 |            0.67 |            0.92 |

Bytes over all 44 files: default 92,194,326, fast 93,279,702, libtiff
90,962,410.

The default effort stays `.default`, as in the PNG encoder: smaller files
for a slower encode, and `.fast` is there for the other trade.

## The change measured: compress a page once

The encoder writes to an `Io.Writer`, which cannot go back, so the IFD comes
before the strips and needs their byte counts first (tiff-encode.md). The
first version compressed every strip twice: once to count, once to write.
The change: while compressing to count, it also copies each strip into the
writer's free buffer after the room the IFD needs; when every strip fits,
it fills in the IFD in front of them and hands the writer both at once, and
nothing is compressed again. When the buffer runs out, the rest is counted
and the page is written as before. The work memory is unchanged; the extra
room is the caller's writer buffer, which a fixed writer for the output has
anyway. The files are the same bytes: every row's checksum matches across
the three variants, a unit test compares a growing writer (no room, two
passes) with a fixed one (one pass) on every test image, and the fuzz target
compares a fixed writer with a 1–512-byte buffered one.

This A/B ran before the rebase, on `compress` 1cdd3d8, when every effort
was level 6; its Deflate columns are level 6. A/B: `tiff-encode-20261102/ab.sh` (the method of `just bench-compare` with
arms given as binaries), 10 rounds, 50 ms a sample, pinned to core 3, arms
`image` (this change, a fixed writer), `twopass` (before it), `streamed`
(this change through a writer with a 64 KiB buffer, as a file writer has,
so pages larger than that take two passes), and libtiff, image-rs, and Go.
`ab/summary.txt`:

| rows (count)       | image MP/s | vs twopass | vs streamed | vs libtiff | vs image-rs | vs Go |
| ------------------ | ---------: | ---------: | ----------: | ---------: | ----------: | ----: |
| none, icons (13)   |     2093.3 |       1.00 |        1.15 |      17.37 |        1.67 |  3.12 |
| none, to 1 MP (23) |     4737.5 |       1.00 |        1.34 |       1.27 |        0.85 |  0.91 |
| none, large (8)    |     2577.9 |       1.00 |        1.18 |       1.02 |        0.89 |  0.92 |
| PackBits, icons    |      136.8 |       1.92 |        1.00 |       2.93 |        1.39 |     - |
| PackBits, to 1 MP  |      186.6 |       1.96 |        1.80 |       1.56 |        1.13 |     - |
| PackBits, large    |      155.0 |       1.94 |        1.96 |       1.56 |        1.02 |     - |
| LZW, icons         |       63.9 |       1.94 |        1.00 |       2.85 |       41.12 |     - |
| LZW, to 1 MP       |       42.1 |       1.99 |        1.61 |       1.27 |        2.10 |     - |
| LZW, large         |       40.7 |       1.99 |        1.99 |       1.32 |        1.97 |     - |
| Deflate, icons     |       11.7 |       1.96 |        0.99 |       0.82 |        1.15 |  2.67 |
| Deflate, to 1 MP   |       23.2 |       2.00 |        1.62 |       0.78 |        2.00 |  1.33 |
| Deflate, large     |       21.0 |       2.01 |        2.00 |       0.88 |        2.57 |  0.91 |
| all (176)          |      148.2 |       1.66 |        1.42 |       1.60 |        1.82 |  1.62 |

Headline: one pass is 1.92–2.01× two passes on every compressed class, and
moves LZW from 0.64–0.67× libtiff to 1.27–1.32× (2.85× on icons), PackBits
from 0.80× to 1.56×. Uncompressed pages were always one pass; `streamed` is
slower on them by the copy through the 64 KiB buffer. Through a buffer too
small for the page (`streamed`, pages over 64 KiB) the encoder is where it
was (`ab/summary-twopass.txt`): LZW 0.64–0.67× libtiff, Deflate 0.39–0.44×.

The remaining gaps:

- **Deflate, 0.78–0.88× libtiff at level 6** (0.60–0.73× at the default
  effort on the pushed code, above). zlib's level 6 is faster than
  `compress`'s and makes files 1.5–2.6% smaller (sizes below). The
  encoder's own work around it (strips, predictor, layout) is the same as
  for LZW, where we lead; this is `compress`'s to close.
- **Uncompressed, 0.85–0.92× the `tiff` crate and Go above 64×64.** Both
  write one strip (Go) or 1 MB strips (the crate), so they copy the image in
  a few large writes where we copy 8 KiB strips; libtiff, with the same
  strips as ours, is 1.02–1.27× slower than us.
- **Pages larger than the writer's buffer take two passes.** A caller
  writing to a file with a small buffer gets the `streamed` column. The
  alternatives are a file layout that cannot be read forward (the IFD after
  the strips, so the header's offset needs a seek) or work memory as large
  as the compressed page; this file's numbers are the trade for whoever
  wants either (owner decision, below).

## Output size

Total bytes by class, ours, and each arm's total over ours on the files it
writes (`ab/check-*.txt`, `len=`). Sizes from the A/B, at level 6 for Deflate. Our files are libtiff's to the byte in
total; per file, libtiff's is one byte longer where its strips end on an odd
offset, because it pads before the IFD it writes last.

| row, class (files) | image bytes | libtiff | image-rs (`tiff` crate) | Go         |
| ------------------ | ----------: | ------: | ----------------------: | ---------- |
| none, icons (13)   |      100332 |   1.000 |                   1.007 | 1.005 (12) |
| none, to 1 MP (23) |    30207046 |   1.000 |                   0.999 | 0.999 (12) |
| none, large (8)    |   252947812 |   1.000 |                   0.999 | 0.999 (4)  |
| PackBits, icons    |       82535 |   1.000 |                   1.058 | -          |
| PackBits, to 1 MP  |    26394937 |   1.000 |                   1.002 | -          |
| PackBits, large    |   230895657 |   1.000 |                   1.000 | -          |
| LZW, icons         |       48263 |   1.000 |                   1.004 | -          |
| LZW, to 1 MP       |    11655302 |   1.000 |                   0.955 | -          |
| LZW, large         |    84242798 |   1.000 |                   0.962 | -          |
| Deflate, icons     |       42410 |   0.981 |                   0.985 | 0.993 (12) |
| Deflate, to 1 MP   |    10894866 |   0.985 |                   0.919 | 1.072 (12) |
| Deflate, large     |    82342426 |   0.974 |                   0.926 | 0.938 (4)  |

The `tiff` crate's LZW and Deflate files are 4–8% smaller because its strips
are about 1 MB: LZW's table and Deflate's window start over each strip.
`EncodeOptions.rows_per_strip` buys the same. Measured on two 1024×1024
images (a scratch test, sizes in bytes, work memory from `workLen`):

| image, compression  | 8 KiB strips (default) | 16 rows (64 KiB) | 64 rows | 1024 rows (one strip) |
| ------------------- | ---------------------: | ---------------: | ------: | --------------------: |
| alpha RGBA, LZW     |                 177573 |           115168 |   98186 |                 94345 |
| alpha RGBA, Deflate |                 134193 |           110369 |  108996 |                108499 |
| photo RGB, LZW      |                2002162 |          1954407 | 1949308 |               1947661 |
| photo RGB, Deflate  |                1995168 |          1905879 | 1878703 |               1869716 |
| work memory, LZW    |                  83744 |           448544 | 1628000 |              25220900 |

The default stays libtiff's 8 KiB: it keeps the work memory under 100 KiB
for LZW, every reader handles it, and it is what lets the oracle compare
libtiff's strips byte for byte. 64 KiB strips would save 2–35% for 5× the
work memory; that is a default the owner may prefer.

## Peak RSS

Peak RSS by class from the pushed run (`compare/rss.txt`), MiB, the
largest file of each class; it includes the harness's input and output
buffers, which dominate the large class (the 50-megapixel mosaic, which Go
skips as RGB, so its large column is smaller files). Ours is the work
memory the encoder states (under 100 KiB for LZW, about 515 KiB for
Deflate's zlib state) on top of those.

| row      | class   | image | libtiff | image-rs |    Go |
| -------- | ------- | ----: | ------: | -------: | ----: |
| none     | icons   |   2.4 |     5.5 |      3.4 |   3.5 |
| none     | to 1 MP |  10.4 |    13.2 |     11.2 |  17.9 |
| none     | large   | 385.9 |   389.2 |    386.6 | 140.7 |
| PackBits | icons   |   2.5 |     5.5 |      3.4 |     - |
| PackBits | to 1 MP |  11.2 |    14.0 |     11.9 |     - |
| PackBits | large   | 434.4 |   437.1 |    435.0 |     - |
| LZW      | icons   |   2.5 |     5.7 |     19.6 |     - |
| LZW      | to 1 MP |  12.3 |    15.1 |     30.2 |     - |
| LZW      | large   | 482.3 |   485.3 |    500.2 |     - |
| Deflate  | icons   |   3.0 |     5.9 |      3.7 |   8.6 |
| Deflate  | to 1 MP |  11.7 |    14.4 |     13.4 |  18.7 |
| Deflate  | large   | 434.8 |   437.6 |    436.5 | 144.1 |

We are below libtiff by about 3 MiB in every class and below the `tiff`
crate everywhere (by 17–18 MiB on LZW, whose 1 MB strips it buffers).

## Raw output

`tiff-encode-20261102/ab/`: `config.txt`, `checksums.txt`, `check-*.txt`
(every arm's lengths and checksums), `rss.txt`, `raw-*.txt` (every
sample), `benchstat.txt`, `summary.txt` (against `twopass`),
`summary-twopass.txt` (`twopass` against the rest; its column `streamed` is
this change through a 64 KiB buffer), and `rows.txt`.
`tiff-encode-20261102/compare/`: the `just bench-compare` run on the
pushed code (`config.txt`, `check-*.txt`, `rss.txt`, `raw-*.txt`,
`benchstat.txt`, `summary.txt`, `rows.txt`).
`tiff-encode-20261102/effort/`: the Deflate effort A/B, the same files,
`summary.txt` against `fast` and `summary-fast.txt` for `fast` against
libtiff.

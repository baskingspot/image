# TIFF decode: the compressed paths, 2026-11-02

Decision 23's follow-up to TIFF stage 2: the LZW, Deflate, PackBits, and
Group 4 rows ran at about half libtiff's speed past icon size
(`tiff-stage2-20261102.md`: LZW 0.47 and 0.50, Deflate 0.67 and 0.71,
PackBits 0.59 and 0.55, G4 0.49 and 0.50, to 1 MP and above). Deflate was
measured again on the current `compress` pin (6319823, unchanged since
stage 2): 0.66 and 0.71 of libtiff in this run's `before` arm, so the gap
was this package's, not inflate's alone.

Profiles of `bench-image` (perf, each row's files) put the time in:

- Deflate: inflate (`flate.Reader.fill`) 46%, and the horizontal predictor
  26%, whose 8-bit loop waited on the store of the sample a pixel before.
- LZW: the decoder 77%, walking each string's prefix chain a byte at a
  time and refilling its bits a byte at a time, and the predictor 16%.
- PackBits: the decoder 55% and `memset` and `memcpy` calls 27%, a call
  for every run of a few bytes.
- Group 4: writing 1-bit gray as 8-bit pixels, a bit at a time, 53%.
- Icons, every compression: the YCbCr tables (768 float divisions), built
  for every page whatever its photometric interpretation.

## Method

`run.sh` in `tiff-speed-20261102/` runs `ab.sh` from
`convert-tails-20261102/` (the `bench-compare` method: checksums, peak RSS
of one pass, then rounds that time every arm on a row back to back in a
rotating order, pinned to one core, `CORE=3`): each change against the
build before it, beside libtiff, the `tiff` crate (through `image-rs`),
and Go, 8 rounds of 50 ms samples over the operation's files
(`bench/corpus-gen/tiff/`, 44 per compression, 35 for G4). A ratio is
this build's throughput over the arm's, the geometric mean over a class's
rows of each row's median paired ratio. Each directory holds the run's
`summary.txt`, `summary-before.txt` (the build before against the arms),
`rows.txt`, `benchstat.txt`, `rss.txt`, `checksums.txt`, `config.txt`, and
the benchstat inputs of this package's arms and libtiff's.

CPU: Intel Xeon Processor @ 2.60GHz, 4 vCPUs, AVX-512, a shared cloud
host, so only paired ratios are steady; Linux 6.1, Zig 0.16.0 ReleaseFast
for this CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`, Go
`GOAMD64=v3`. Every run's checksums match libtiff's and the `tiff`
crate's on every row: the pixels are unchanged. (Go differs on the 35 G4
rows, which it reads as black-is-zero; the row is `own`.)

Classes: icons (at most 64×64), to 1 MP, and larger.

## The horizontal predictor (`predictor/`)

Predictor 2 on 8-bit samples of 1 to 4 per pixel is a prefix sum per
channel over 16-byte vectors: shifts by the stride, 2 strides, 4, and 8
add each lane's earlier samples in the vector, and the previous vector's
last pixel, shuffled to each lane of its channel, carries the sums across.
16-bit samples keep a pixel's running sums in registers. Other layouts
keep the loop over bytes.

| row            | MP/s  | vs before | vs libtiff |
| -------------- | ----- | --------- | ---------- |
| LZW, icons     | 69.6  | 1.14      | 1.00       |
| LZW, to 1 MP   | 82.1  | 1.19      | 0.57       |
| LZW, large     | 75.7  | 1.16      | 0.59       |
| Deflate, icons | 89.5  | 1.19      | 1.72       |
| Deflate, 1 MP  | 162.7 | 1.40      | 0.94       |
| Deflate, large | 135.3 | 1.31      | 0.94       |

## LZW strings 8 bytes a step (`lzw/`)

Each table entry holds its string's last block, the bytes from the last
multiple of 8 before its end, and the entry whose string is the rest; a
new entry copies its prefix's block and appends a byte, or starts a block.
A string is written out a block at a time, last first, as whole 8-byte
moves where the row buffer has room, the bytes past its end overwritten
by the strings after it. The decoder keeps its state in locals (stores to
the row could alias it), refills its bit buffer with 7 bytes at once from
the reader's buffer, and takes literals on a branch of their own; the
first-byte table is gone, its byte the string's first written.

| row          | MP/s  | vs before | vs libtiff |
| ------------ | ----- | --------- | ---------- |
| LZW, icons   | 87.8  | 1.24      | 1.22       |
| LZW, to 1 MP | 146.8 | 1.75      | 1.00       |
| LZW, large   | 128.7 | 1.67      | 0.99       |

Memory: the table grows from 24 to 48 KiB (8 bytes a block in place of a
suffix byte and a first byte), so an LZW page's work memory grows by
24 KiB, 28 KiB to 52 KiB for the decompressor; peak RSS is unchanged at
the tenth of a MiB (`rss.txt`: 255.3 MiB against 255.2). The speed is the
trade's other side: 1.67–1.75× past icons.

## PackBits runs from the reader's buffer (`packbits/`)

While the reader's buffer holds the next run, runs decode straight from
it: with room for any run in the row, a literal or repeat moves as a fixed
32 or 128 bytes (bytes past its end are overwritten by the runs after
it), and near the row's end, exactly, by overlapping fixed-size moves; no
call either way. The rest (a run cut by the row or the buffer) takes the
old path. A fill that finds the data's end is not tried again.

| row               | MP/s   | vs before | vs libtiff |
| ----------------- | ------ | --------- | ---------- |
| PackBits, icons   | 364.1  | 2.17      | 2.53       |
| PackBits, to 1 MP | 2556.9 | 3.28      | 1.70       |
| PackBits, large   | 1683.8 | 3.32      | 1.61       |

A first version moved runs only with room for 128 bytes and filled the
reader's buffer on every row; it lost on 16-pixel rows (0.89 on one icon)
and is not the one that landed.

## 1-bit gray a byte at a time (`gray1/`)

A byte of 1-bit gray becomes eight 8-bit pixels from a 2 KiB table, XORed
with 0xff for white-is-zero, before the conversion to the caller's format.

| row         | MP/s   | vs before | vs libtiff |
| ----------- | ------ | --------- | ---------- |
| G4, icons   | 343.7  | 1.35      | 4.02       |
| G4, to 1 MP | 2369.4 | 3.18      | 1.51       |
| G4, large   | 1815.0 | 2.61      | 1.25       |

## The YCbCr tables only for YCbCr (`ycc/`)

The icon rows only, since the tables cost the same on every page.

| row                   | MP/s   | vs before | vs libtiff |
| --------------------- | ------ | --------- | ---------- |
| uncompressed, icons   | 1028.0 | 1.68      | 6.03       |
| PackBits, icons (old) | 209.1  | 1.16      | 1.44       |

## Every change against main (`final/`)

Main 8a97cbc against every change above and the Group 4 fix that lands
with them (b1 after a leading pass, `tiff.md`), in one run.

| row                   | image MP/s | vs main | vs libtiff | vs `tiff` crate | vs Go |
| --------------------- | ---------- | ------- | ---------- | --------------- | ----- |
| uncompressed, icons   | 1018.1     | 1.66    | 5.93       | 1.97            | 5.74  |
| uncompressed, to 1 MP | 4758.2     | 1.02    | 2.00       | 5.25            | 18.58 |
| uncompressed, large   | 3309.8     | 1.00    | 1.48       | 5.85            | 14.84 |
| LZW, icons            | 91.7       | 1.47    | 1.32       | 1.67            | 3.20  |
| LZW, to 1 MP          | 133.9      | 1.91    | 0.91       | 2.04            | 3.65  |
| LZW, large            | 115.8      | 1.81    | 0.91       | 1.94            | 3.45  |
| Deflate, icons        | 99.1       | 1.27    | 1.84       | 1.71            | 3.87  |
| Deflate, to 1 MP      | 163.2      | 1.41    | 0.94       | 2.10            | 4.27  |
| Deflate, large        | 132.0      | 1.29    | 0.92       | 1.95            | 3.83  |
| PackBits, icons       | 508.8      | 2.98    | 3.41       | 1.72            | 5.80  |
| PackBits, to 1 MP     | 2732.9     | 3.37    | 1.73       | 3.89            | 18.90 |
| PackBits, large       | 1690.5     | 3.44    | 1.59       | 3.88            | 14.81 |
| JPEG, icons           | 78.9       | 1.00    | -          | -               | -     |
| JPEG, to 1 MP         | 298.0      | 1.00    | -          | -               | -     |
| JPEG, large           | 337.7      | 0.99    | -          | -               | -     |
| G4, icons             | 453.8      | 1.74    | 5.20       | 5.79            | 6.56  |
| G4, to 1 MP           | 2412.0     | 3.20    | 1.53       | 21.98           | 19.54 |
| G4, large             | 1735.3     | 2.63    | 1.19       | 16.46           | 14.48 |
| all (255)             | 493.6      | 1.66    | 1.69       | 3.39            | 7.63  |

(ab.sh times libtiff on the JPEG row only where its checksums are listed;
`tiff-stage2-20261102.md` has JPEG against libtiff, and nothing here
changes it.)

Peak RSS of one pass over each operation's inputs (MiB, `final/rss.txt`):
every row within 0.1 of main's, and 3 MiB under libtiff's.

| op           | image | main  | libtiff | `tiff` crate | Go    |
| ------------ | ----- | ----- | ------- | ------------ | ----- |
| uncompressed | 338.5 | 338.5 | 341.5   | 677.7        | 777.4 |
| LZW          | 255.3 | 255.2 | 258.1   | 594.8        | 664.8 |
| Deflate      | 253.9 | 253.8 | 256.8   | 593.2        | 675.5 |
| PackBits     | 332.8 | 332.8 | 335.6   | 672.1        | 785.1 |
| JPEG         | 198.7 | 198.7 | -       | -            | -     |
| G4           | 33.1  | 33.1  | 36.0    | 73.3         | 136.2 |

## `just bench-compare` on the branch (`bench-compare/`)

`just bench-compare 10` over the six TIFF operations on the branch's last
commit (these changes, the Group 4 fix, and JPEG tables carried across
strips), on main 49ffbd3, exit 0: every checksum matches libtiff's and the
`tiff` crate's (Go differs on the G4 rows, `own`).

| row                   | image MP/s | vs libtiff | vs `tiff` crate | vs Go |
| --------------------- | ---------- | ---------- | --------------- | ----- |
| uncompressed, icons   | 959.4      | 6.08       | 1.91            | 5.81  |
| uncompressed, to 1 MP | 4522.8     | 2.03       | 5.28            | 18.40 |
| uncompressed, large   | 3118.0     | 1.49       | 5.93            | 14.70 |
| LZW, icons            | 84.6       | 1.30       | 1.69            | 3.20  |
| LZW, to 1 MP          | 121.8      | 0.90       | 2.00            | 3.60  |
| LZW, large            | 104.9      | 0.89       | 1.90            | 3.33  |
| Deflate, icons        | 88.7       | 1.83       | 1.73            | 3.89  |
| Deflate, to 1 MP      | 149.8      | 0.95       | 2.10            | 4.27  |
| Deflate, large        | 122.2      | 0.93       | 1.98            | 3.80  |
| PackBits, icons       | 458.4      | 3.37       | 1.69            | 5.63  |
| PackBits, to 1 MP     | 2490.3     | 1.75       | 3.89            | 18.94 |
| PackBits, large       | 1540.7     | 1.62       | 3.90            | 14.68 |
| JPEG, icons           | 71.0       | 4.27       | -               | -     |
| JPEG, to 1 MP         | 279.7      | 1.11       | -               | -     |
| JPEG, large           | 315.0      | 1.04       | -               | -     |
| G4, icons             | 414.7      | 5.18       | 5.59            | 6.51  |
| G4, to 1 MP           | 2225.9     | 1.51       | 21.48           | 19.61 |
| G4, large             | 1616.8     | 1.22       | 16.35           | 14.81 |
| all (255)             | 454.6      | 1.68       | 3.37            | 7.59  |

The JPEG rows are below stage 2's (6.50, 1.26, 1.12) with the same
decoding: two alternating `bench` passes per binary, pinned to one core,
of main 49ffbd3 against this branch give 0.97, 1.03, and 1.02 on them, and main 8a97cbc against 49ffbd3
1.01 each; libtiff's per-file setup, which the icons row mostly measures,
varies from run to run on this shared host.

Peak RSS (MiB) by size class, one `serve` pass over each class's inputs:

| op, class       | image | libtiff | `tiff` crate | Go    |
| --------------- | ----- | ------- | ------------ | ----- |
| none, icons     | 2.7   | 5.8     | 3.8          | 3.6   |
| none, 1 MP      | 9.7   | 12.3    | 21.0         | 25.1  |
| none, large     | 338.0 | 341.3   | 675.4        | 869.6 |
| LZW, icons      | 2.8   | 5.9     | 3.7          | 4.7   |
| LZW, 1 MP       | 8.7   | 11.3    | 21.4         | 21.2  |
| LZW, large      | 255.0 | 258.1   | 592.2        | 795.4 |
| Deflate, icons  | 2.9   | 5.8     | 4.0          | 4.4   |
| Deflate, 1 MP   | 8.5   | 10.9    | 20.0         | 20.3  |
| Deflate, large  | 253.9 | 256.6   | 591.0        | 730.0 |
| PackBits, icons | 2.8   | 5.7     | 3.7          | 4.3   |
| PackBits, 1 MP  | 9.7   | 12.3    | 21.1         | 23.5  |
| PackBits, large | 332.6 | 335.6   | 669.8        | 891.3 |
| JPEG, icons     | 2.9   | 6.2     | -            | -     |
| JPEG, 1 MP      | 7.1   | 10.1    | -            | -     |
| JPEG, large     | 198.6 | 202.4   | -            | -     |
| G4, icons       | 2.7   | 5.8     | 3.7          | 3.3   |
| G4, 1 MP        | 6.5   | 9.3     | 14.8         | 11.6  |
| G4, large       | 33.2  | 36.0    | 73.3         | 52.0  |

Every class is 0.3 to 0.5 MiB above stage 2's, the uncompressed and JPEG
rows as much as the rest: `bench-image` itself grew with main's new
formats (7.9 to 8.7 MB). Against main in one run (`final/rss.txt`) no
row moves by more than 0.1 MiB.

## What is left

Past icons, LZW is at 0.89–1.00 of libtiff (1.00 and 0.99 in its own run,
0.89 to 0.91 in the runs of every row) and Deflate at 0.92–0.95. Deflate's rest is
`compress`'s: on libtiff's 8 KiB strips each strip is a zlib stream with
its own dynamic Huffman header, and building the 2048-entry primary table
(`HuffmanDecoder.build`, 10%) and reading the header (7%) cost as much as
a fifth of inflating it. A smaller primary table for short streams would
pay here (asked of the `compress` owner). The stage buffer's copy of the
compressed bytes is about 7% of PackBits's time and stays: the codecs read
a strip through a reader limited to its bytes.

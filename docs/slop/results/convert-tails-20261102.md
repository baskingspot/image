# Conversion kernels' tails, 2026-11-02

Swap3's 192-byte blocks are reverted under Zig 0.17, which compiles them
a byte at a time: `convert-swap3-20261105.md`.

`image.convert`'s SIMD kernels ran whole blocks of 16 pixels and sent the
rest of a call, up to 15 pixels, through the general per-pixel path. On a
166-pixel row that tail cost about as much as the 160 pixels before it,
and every decoder that converts a row at a time paid it once per row: the
narrow 24- and 32-bit BMPs ran 0.69× Wuffs in `bmp-20261101.md`, and the
TGA 50-megapixel mosaic 0.71× in `tga-20261101.md`.

This change, in `src/convert.zig`:

- `blocks` takes the kernel as a type with a `wide` and a `narrow` block
  size. When the buffers are disjoint and the call has at least one
  block, the tail is one more block that ends at the last pixel and
  overlaps the block before it: every kernel works pixel by pixel, so it
  rewrites the same bytes. When the buffers overlap (a same-size
  conversion in place) or there is less than one block, the tail goes
  through a zero-padded copy, out of line, which reads no byte the call
  wrote.
- Swap3 (RGB and BGR, either way) runs 192-byte blocks from the first
  pixel whose output starts a 64-byte line, after narrow blocks up to it
  (`lineStart`), so none of its stores splits a cache line. Unaligned
  192-byte blocks were 3–5% slower than 48-byte ones on rows in the cache
  (they lost the TGA 1200×1200 rows 6% in an earlier A/B); aligned ones
  win at every width measured (`micro-swap3/`).
- Swap4 (RGBA and BGRA) is a byte `@shuffle` in 32-byte blocks. 64-byte
  blocks lost about 10% on images past the cache, aligned or not.
- Expand3 (RGB to RGBA), gray to color, and Drop4 (RGBA to RGB) are
  generic over the block size, at 16 pixels. Aligning Expand3's stores
  measured within noise.
- The 16-bit narrowing and widening loops end with an overlapped vector.
- `copy` skips `@memcpy` when source and destination are the same buffer,
  and `Converter.run` documents that same-size formats may convert in
  place. The test "every SIMD path gives the general path's bytes" now
  converts at every offset from a cache line and each same-size pair in
  place too; with the padded tail or the aligned head's first block
  removed it fails.

Output is bit-identical: the A/B's checksums match the arm before the
change on all 425 rows (`ab/checksums.txt`).

## Method

`ab.sh` (here) is `convert-rounding-20261101/ab.sh` with the operations,
a row filter, and the core taken from the environment. It runs
`bench-image` from origin/main 8e7e4c8 (`before`), `bench-image` with this
change (`image`), and `bench-wuffs`, 10 interleaved rounds pinned to core
3, 50 ms a sample, and gives benchstat and peak RSS:

```
CORE=3 OPS="bmp-decode bmp-decode-bgra tga-decode tga-decode-bgra \
  netpbm-decode-ppm-rgba convert-rgba8-bgra8 convert-rgb8-rgba8 \
  convert-rgba8-rgb8 convert-rgba8-premul convert-gray8-rgba8 \
  convert-rgba16-rgba8" \
  ab.sh OUT 10 image=bench-image.new before=bench-image.8e7e4c8 \
  wuffs=zig-out/bin/bench-wuffs
```

`tga-decode` decodes BGR files to RGB (Swap3) and BGRA files to RGBA
(Swap4); `tga-decode-bgra` decodes BGR to BGRA (Expand3) and copies BGRA.

CPU: Intel Xeon Processor @ 2.60GHz (it runs at 3.3 GHz under load), 4
vCPUs, AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0, ReleaseFast
for this CPU, Wuffs with `cc -O3 -march=native`.

Two micro-benchmarks, built against a directory holding `convert.zig` and
`pixel.zig`, pinned to core 2, three runs each, alternating:
`micro/main.zig` times one `Converter.run` call of n pixels (best of 7);
`micro-swap3/bigw.zig` converts an image of BGR rows to RGB, w×h with the
output 2048 bytes past a page, as `bw.sh DIR OUT W H` builds it.

## Results

Megapixels per second of this change, and its speed over the arm before
it and over Wuffs, geometric means by size class (`ab/summary.txt`):

| rows               | image MP/s | vs before | vs Wuffs  |
| ------------------ | ---------- | --------- | --------- |
| BMP decode, icons  | 1974       | 1.07      | 1.39      |
| BMP decode, ≤ 1 MP | 3892       | 1.08      | 1.08      |
| BMP decode, > 1 MP | 2317       | 1.03      | 1.01      |
| TGA decode, icons  | 3070       | 1.05      | 1.79      |
| TGA decode, ≤ 1 MP | 5290       | 1.22      | 1.41      |
| TGA decode, > 1 MP | 2679       | 1.15      | 1.13      |
| TGA decode BGRA    | 2496–4674  | 0.99–1.01 | 1.01–1.53 |
| PPM decode to RGBA | 2914–5065  | 0.99–1.01 | 1.01–2.35 |
| all 425 rows       | 3355       | 1.04      | 1.24      |

The rows this pass was after (`ab/rows.txt`, median ratio and range over
rounds; "Wuffs before" is the before arm's speed over Wuffs's):

| row                               | vs before         | Wuffs before | vs Wuffs now      |
| --------------------------------- | ----------------- | ------------ | ----------------- |
| BMP 24-bit plant 166×1022         | 1.25 [1.19, 1.38] | 0.90         | 1.13 [1.09, 1.20] |
| BMP 32-bit plant 166×1022         | 1.16 [1.07, 1.24] | 0.94         | 1.16 [0.97, 1.42] |
| BMP 24-bit plant 166×1022 to BGRA | 1.29 [1.20, 1.33] | 0.91         | 1.17 [1.14, 1.46] |
| TGA mosaic 8192×6144 (BGR)        | 1.26 [1.20, 1.29] | 0.74         | 0.94 [0.87, 1.03] |
| TGA tecnick 1200×1200 (BGR)       | 1.17 [1.12, 1.23] | 1.17         | 1.38 [1.30, 1.46] |
| TGA wikipedia_008 1152×858 (BGR)  | 1.23 [1.20, 1.26] | 1.14         | 1.41 [1.36, 1.45] |
| TGA 32-bit near 1 MP (BGRA)       | 1.03–1.09         | 0.92–0.98    | 0.98–1.01         |

This host's Wuffs ratios run higher than the reports of 2026-11-01 (the
plant BMPs read 0.90–0.94 before the change here, against 0.69 there):
the bars moved with the host, so read the "vs before" column.

Peak RSS is unchanged in every operation (`ab/rss.txt`: the benchmark's
input and output buffers, 82–386 MiB, within 0.1 MiB of the before arm).

Per call (`micro/`, ns, median of three runs):

| pair           | n=22       | n=166       | n=1000        | n=8192      |
| -------------- | ---------- | ----------- | ------------- | ----------- |
| BGR → RGBA     | 15.8 → 8.9 | 34.7 → 27.7 | 123.2 → 107.9 | 1045 → 1041 |
| BGR → RGB      | 15.9 → 7.4 | 20.0 → 15.9 | 67.6 → 40.0   | 664 → 336   |
| BGRA → RGBA    | 11.0 → 5.4 | 16.9 → 9.7  | 45.9 → 28.9   | 807 → 663   |
| gray → RGBA    | 12.6 → 5.7 | 22.1 → 15.8 | 83.3 → 75.3   | 629 → 615   |
| RGBA16 → RGBA8 | 11.0 → 5.5 | 24.8 → 16.4 | 98.8 → 81.0   | 1015 → 1136 |

A row's fixed cost past its blocks dropped from 6–10 ns to 0–3 ns.

Swap3 over whole images (`micro-swap3/raw.txt`, MP/s, three runs):

| rows                  | 48-byte blocks | 192-byte, unaligned | 192-byte, aligned |
| --------------------- | -------------- | ------------------- | ----------------- |
| 1200 wide, 1200 rows  | 4029–4348      | 3678–4361           | 4917–5250         |
| 1200 wide, 40000 rows | 1336–1382      | 1437–1550           | 1815–1837         |
| 8192 wide, 6144 rows  | 1320–1498      | 1772–1855           | 1849–1876         |

Two readings went the other way, both on a loop this change left alone:
the whole-buffer RGBA16 → RGBA8 conversion at 256×256 read 0.92
[0.89, 0.93] in the A/B (its class 0.96, the 4096² row 1.03), and the
micro-benchmark's 8192-pixel call of the same pair read 0.89. Its main
loop compiles to the same two instructions before and after (`vpsrlw`
and `vpmovwb`, objdump); only its placement moved.

## Raw output

`ab/`: `image.txt`, `before.txt`, and `wuffs.txt` (benchstat input),
`benchstat.txt`, `summary.txt` (against Wuffs) and `summary-before.txt`,
`rows.txt`, `rss.txt`, and `checksums.txt` with `check-diff-wuffs.txt`
(RGBA8 → RGB8 differs from Wuffs by design: Wuffs composites onto black,
we drop alpha). `micro/`: `before-N.txt` and `after-N.txt`.
`micro-swap3/`: `raw.txt`, `s16` being Swap3 with 48-byte blocks,
`fin` 192-byte blocks without the aligned head, and `al` this change.

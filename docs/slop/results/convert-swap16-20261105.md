# Swap3 and Swap4 shuffle bytes under Zig 0.17, 2026-11-05

`convert-swap3-20261105.md` left the 16-bit swap kernels slow on Zig
0.17.1. Each block `@bitCast` its bytes to `@Vector(l * c, u16)`, swapped
lanes with `@shuffle(u16, …)`, and cast back, and Zig 0.17.1 lowers those
casts with shifts, `vpinsrw`/`vpinsrb`, and scalar moves: `Swap3(u16)`
(RGB16 and BGR16, either way) ran at about 25 MP/s at any n, native or
baseline, in 8.3 KB, and `Swap4(u16)` (RGBA16 and BGRA16) at about 400
MP/s native, slower than its 1,050 baseline.

This change, in `src/convert.zig`: both kernels' blocks take the input as
`@Vector(l * c * @sizeOf(T), u8)` and `@shuffle(u8, …)` it with a mask
that moves each sample's bytes together, for both sample types. A sample's
bytes keep their order, so the shuffle is the same on either endianness.
For 8-bit samples the mask is the one before; only the cast is gone.
Block sizes are unchanged (Swap3 16 pixels, Swap4 32 bytes).

Output is bit-identical: the existing test that runs every fast pair
against the general path at 11 lengths, in place and not, passes under
`just test` and `just test-cpu` (baseline and `x86_64_v3`), and both A/Bs'
checksums match on all 93 rows.

## Method

Zig 0.17.1 from the flake, ReleaseFast. CPU: Intel Xeon Processor @
2.60GHz, 4 vCPUs, AVX-512, a shared cloud host; Linux 6.1. "Before" is
`zig-0.17` with the Swap3 16-pixel change (`convert-swap3-20261105.md`),
"after" this change on top of it.

- Code size: `nm -S` on the micro-benchmark and on `bench-image` built
  with `zig build bench -Doptimize=fast`, native and `-Dcpu=baseline`;
  both give the same kernel sizes (`sizes.txt`, with `size` and each
  kernel's top instructions).
- `micro/main.zig`: `convert-swap3-20261105/micro/main.zig` extended to
  the four swap pairs, one `Converter.run` of n pixels, best of 7, and
  whole images of rows of the two 16-bit pairs, the output 2048 bytes
  past a page:
  `zig build-exe -OReleaseFast -mcpu=native --dep conv -Mroot=main.zig -Mconv=DIR/src/convert.zig`.
  Three runs of each arm, interleaved, pinned to core 2 (`micro/`);
  tables give the median.
- The repository's A/B, `convert-tails-20261102/ab.sh` unchanged, over
  `tga-decode`, `tga-decode-rle`, and `convert-rgba8-bgra8`, 6 rounds on
  core 2, native (`ab-native/`) and baseline (`ab-baseline/`, whose
  `config.txt` says "native" because the script prints that line as
  written). No benchmark row converts 16-bit samples between RGB and BGR;
  these rows run the 8-bit kernels, whose casts went too:

```
CORE=2 OPS="tga-decode tga-decode-rle convert-rgba8-bgra8" \
  docs/slop/results/convert-tails-20261102/ab.sh OUT 6 \
  after=bench-image.after before=bench-image.before
```

## Results

Code size, bytes (`sizes.txt`):

| kernel           | before, native | after, native | before, baseline | after, baseline |
| ---------------- | -------------: | ------------: | ---------------: | --------------: |
| `Swap3(u16).run` |          8,291 |         1,171 |            5,888 |           1,340 |
| `Swap4(u16).run` |          1,886 |           736 |            1,124 |             259 |
| `Swap3(u8).run`  |          1,069 |           893 |            2,775 |           1,568 |
| `Swap4(u8).run`  |            736 |           736 |              439 |             439 |
| all four         |         11,982 |         3,536 |           10,226 |           3,606 |
| bench-image text |      2,592,177 |     2,580,457 |        2,661,769 |       2,653,265 |

Native, `Swap3(u16)` is now `vpermw`/`vpermt2w` and `Swap4(u16)` the same
`vpshufb` loop as `Swap4(u8)`; baseline, `Swap4(u16)` is `pshuflw` and
`pshufhw`. `Swap4(u8)`'s instructions are the same in both arms, up to
register names and padding.

MP/s, median of three runs (`micro/`):

| call               | before, native | after, native | before, baseline | after, baseline |
| ------------------ | -------------: | ------------: | ---------------: | --------------: |
| rgb16→bgr16 16     |             23 |          3299 |               25 |            1931 |
| rgb16→bgr16 166    |             26 |          7677 |               19 |            2340 |
| rgb16→bgr16 1000   |             26 |          8767 |               20 |            2492 |
| rgb16→bgr16 8192   |             26 |          6993 |               22 |            2447 |
| rgba16→bgra16 16   |            325 |          3517 |              926 |            2284 |
| rgba16→bgra16 166  |            378 |        12,600 |             1053 |            3649 |
| rgba16→bgra16 1000 |            389 |        15,891 |             1086 |            4968 |
| rgba16→bgra16 8192 |            398 |          5398 |             1089 |            4326 |
| rgb8→bgr8 16       |           3655 |          3976 |             1375 |            1703 |
| rgb8→bgr8 1000     |         15,990 |        17,466 |             1649 |            2125 |
| rgba8→bgra8 16     |           3984 |          3993 |             3246 |            2213 |
| rgba8→bgra8 1000   |         30,508 |        29,474 |             3699 |            3602 |
| rgb16 1200×1200    |             26 |          2110 |               20 |            1890 |
| rgb16 4096×3072    |             26 |          1147 |               21 |             777 |
| rgba16 1200×1200   |            344 |          1421 |              799 |            1567 |
| rgba16 4096×3072   |            244 |           821 |              428 |             636 |

The rgba8→bgra8 rows run the same instructions in both arms; their spread
is this host's (baseline n = 16 after read 2213, 2155, and 3253 MP/s,
before 3448, 3163, and 3246; n = 22 and 166 are in the raw files).

TGA decode and `convert-rgba8-bgra8` (`ab-*/rows.txt`; 24-bit files run
`Swap3(u8)`, 32-bit ones `Swap4(u8)`; geometric means of the median
ratios, after / before):

| build    | 24-bit rows (32)          | 32-bit rows (56)          | convert-rgba8-bgra8 (5) |
| -------- | ------------------------- | ------------------------- | ----------------------- |
| native   | 1.007, 0 faster, 1 slower | 1.013, 6 faster, 0 slower | about 1, none differ    |
| baseline | 1.284, 32 faster          | 0.990, 2 faster, 5 slower | about 1, none differ    |

The five slower baseline rows are 32-bit RLE files (the lowest
`TgaDecodeRLE/test-dice-800x600`, 0.905 [0.861, 0.953]), which run
`Swap4(u8)`, unchanged here, and TGA code of the same sizes. A second
baseline A/B of `tga-decode-rle` alone, not kept, read its 28 32-bit rows
at 0.972 with three slower, different files, and the 16 24-bit rows at
1.242. `Swap4(u8)` moved from a 64-byte boundary to a 16-byte one in the
baseline binary; that layout, or the host, is the likely cause, and this
change has no code to tune there. Peak RSS is unchanged (`ab-*/rss.txt`).

## Raw output

`sizes.txt`; `micro/`: `main.zig` and `{before,after}-{native,baseline}-N.txt`;
`ab-native/` and `ab-baseline/`: `after.txt` and `before.txt` (benchstat
input), `benchstat.txt`, `summary.txt`, `rows.txt`, `rss.txt`,
`config.txt`, and `checksums.txt` with the empty `check-diff-before.txt`.

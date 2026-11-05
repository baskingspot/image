# Swap3 back to 16-pixel blocks under Zig 0.17, 2026-11-05

`convert-tails-20261102.md` gave Swap3 (RGB and BGR, either way) 192-byte
blocks of 8-bit samples (`wide = 64 / @sizeOf(T)`, one `@shuffle` of 64
pixels) aligned to cache lines, and measured them at about 1,850 MP/s on
Zig 0.16, built only for the native AVX-512 CPU, with no code size taken.
On the `zig-0.17` branch, Zig 0.17.1 lowers that shuffle one byte at a
time even with AVX-512: the 8-bit kernel is 1,440 `vpinsrb` and 720
`vpextrb`, 35.9 KB, and runs at 20–28 MP/s. The Zig 0.17 port's speed
check (`zig017-20261104.md`) timed no TGA or BMP row, so it missed this.

This change, in `src/convert.zig`:

- Swap3 runs 16-pixel blocks, as before 7510413, for both sample types.
- Every kernel then has one block size, so `blocks` loses its wide-block
  branch and `lineStart`, the aligned head before it, and each kernel's
  `wide` and `narrow` are one `pixels`. The SIMD test no longer converts
  at each of 64 offsets from a cache line, which only the aligned head
  needed; the overlapped tail, the padded tail, and the in-place runs are
  tested as before.

Output is bit-identical: both A/Bs' checksums match on all 88 rows, and
`just test` and `just test-cpu` (baseline and `x86_64_v3`) pass.

## Method

Zig 0.17.1 from the flake, ReleaseFast. CPU: Intel Xeon Processor @
2.60GHz, 4 vCPUs, AVX-512, a shared cloud host; Linux 6.1. "Before" is
`zig-0.17` at b4c1ebe, "after" this change.

- Code size: `nm -S` on the micro-benchmark and on `bench-image` built
  with `zig build bench -Doptimize=fast`, native and `-Dcpu=baseline`
  (`sizes.txt`, with `size` and the top instructions of each kernel).
  Plain `zig build bench`, as `just bench-build` runs it, leaves the
  compress dependency in Debug, so both arms here pass `-Doptimize=fast`.
- `micro/main.zig`: one `Converter.run` of n pixels, best of 7, and whole
  images of rows with the output 2048 bytes past a page, formats chosen at
  run time as a decoder chooses them, built against a directory holding
  `convert.zig` and `pixel.zig`:
  `zig build-exe -OReleaseFast -mcpu=native --dep conv -Mroot=main.zig -Mconv=DIR/convert.zig`.
  Three runs of each arm, interleaved, pinned to core 2 (`micro/`).
- The repository's A/B, `convert-tails-20261102/ab.sh` unchanged, over
  `tga-decode` and `tga-decode-rle` (24-bit files decode BGR to RGB
  through Swap3; 32-bit ones go through Swap4 and are controls), 6 rounds
  on core 2, once with native builds (`ab-native/`) and once with baseline
  builds (`ab-baseline/`, whose `config.txt` says "native" because the
  script prints that line as written):

```
CORE=2 OPS="tga-decode tga-decode-rle" \
  docs/slop/results/convert-tails-20261102/ab.sh OUT 6 \
  image=bench-image.after before=bench-image.before
```

## Results

Code size, bytes (`sizes.txt`):

| kernel           | before, native | after, native | before, baseline | after, baseline |
| ---------------- | -------------: | ------------: | ---------------: | --------------: |
| `Swap3(u8).run`  |         35,891 |         1,069 |           54,434 |           2,775 |
| `Swap3(u16).run` |         37,227 |         8,291 |           26,469 |           5,888 |
| both             |         73,118 |         9,360 |           80,903 |           8,663 |
| bench-image text |      2,656,257 |     2,592,177 |        2,734,025 |       2,661,769 |

`bench-image` loses 64 KB of text native and 72 KB baseline.

RGB8 to BGR8, MP/s, median of three runs (`micro/`):

| call           | before, native | after, native | before, baseline | after, baseline |
| -------------- | -------------: | ------------: | ---------------: | --------------: |
| n = 16         |           3514 |          4718 |             1649 |            1616 |
| n = 166        |             20 |        11,936 |                8 |            1506 |
| n = 1000       |             27 |        16,230 |                9 |            1599 |
| n = 8192       |             28 |        15,203 |               10 |            1615 |
| 1200×1200 rows |             23 |          4332 |                9 |            1485 |
| 8192×6144 rows |             28 |          2106 |               10 |             863 |

Calls under 64 pixels never took the wide blocks, so n = 16 runs the same
code in both arms. The whole-image rows compare with the 1,320–1,876
MP/s Zig 0.16 measured in `convert-tails-20261102.md`; this host's numbers
move with the host, so that comparison is rough.

TGA decode (`ab-*/rows.txt`, the 32 rows from 24-bit files and the 56
from 32-bit ones, geometric means of the median ratios):

| build    | 24-bit rows, after | before | after / before | 32-bit rows, after / before |
| -------- | -----------------: | -----: | -------------- | --------------------------- |
| native   |          3233 MP/s |   22.9 | 140× (38–397×) | 0.985 (0.83–1.05)           |
| baseline |          1195 MP/s |    8.7 | 136× (64–197×) | 1.002 (0.96–1.06)           |

The 32-bit rows run code this change left alone. Seven of them read
below 1 in the native A/B (the lowest `TgaDecodeRLE/test-qoi_logo`, 0.83
[0.81, 0.97]) and one in the baseline A/B; every one is a 32-bit file.
Peak RSS is unchanged (`ab-*/rss.txt`).

## Not changed: Swap3 for 16-bit samples

`Swap3(u16)` is still slow after this change: 24–28 MP/s for rgb16 to
bgr16 at every n, native and baseline, and 8.3 KB native. Block size is
not the cause; it ran as slowly at 16 pixels before. Its block
`@bitCast`s the bytes to `@Vector(48, u16)`, and Zig 0.17.1 lowers that
cast with shifts and `vpinsrw` (`sizes.txt`). A probe that shuffles the
block's bytes instead (`@Vector(l * 6, u8)`, each sample's two bytes
moving together) ran at 9,479 MP/s native and 3,017 baseline at n = 1000,
in 1.2–1.3 KB (`u16-probe.txt`, one run). Swap4's 16-bit kernel uses the
same cast and reads 400 MP/s native against 1,050 baseline there. Neither
is part of this change.

## Raw output

`sizes.txt`; `micro/`: `main.zig` and `{before,after}-{native,baseline}-N.txt`;
`ab-native/` and `ab-baseline/`: `image.txt` and `before.txt` (benchstat
input), `benchstat.txt`, `summary.txt`, `rows.txt`, `rss.txt`, and
`checksums.txt` with the empty `check-diff-before.txt`; `u16-probe.txt`.

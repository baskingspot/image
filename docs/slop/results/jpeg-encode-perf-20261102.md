# JPEG encode performance pass, 2026-11-02

Closing the baseline color gap over 1 MP that results/jpeg-encode-20261102.md
left (0.93× libjpeg-turbo at 4:2:0, 0.98× at 4:4:4), with the output still
byte-identical to libjpeg-turbo's (the oracle, and the benchmark's checksums
on all 220 rows). Same machine, corpus, operations, and method as that
file: Intel Xeon Processor @ 2.60GHz (Ice Lake server, 4 vCPUs, a shared
host whose rows swing by ±10% between rounds), Zig 0.16.0 ReleaseFast for
this CPU, libjpeg-turbo 3.2.0 with SIMD, 10 rounds, each row's ratio the
median of its paired ratios. Raw output in `jpeg-encode-perf-20261102/`.

## Results

Ratio of our throughput to libjpeg-turbo's, before (results/jpeg-encode-20261102.md)
and after this pass, with our MP/s after:

| operation, class          | before | after | image MP/s after |
| ------------------------- | ------ | ----- | ---------------- |
| baseline 4:2:0, icons     | 6.43   | 7.31  | 213.5            |
| baseline 4:2:0, to 1 MP   | 1.07   | 1.33  | 535.9            |
| baseline 4:2:0, over 1 MP | 0.93   | 1.18  | 507.9            |
| 4:4:4, icons              | 4.93   | 5.92  | 155.1            |
| 4:4:4, to 1 MP            | 1.06   | 1.35  | 300.3            |
| 4:4:4, over 1 MP          | 0.98   | 1.26  | 291.3            |
| optimized, icons          | 2.87   | 2.70  | 68.9             |
| optimized, to 1 MP        | 1.67   | 1.97  | 378.7            |
| optimized, over 1 MP      | 1.51   | 1.91  | 381.0            |
| progressive, icons        | 2.32   | 1.99  | 32.4             |
| progressive, to 1 MP      | 1.70   | 1.75  | 134.9            |
| progressive, over 1 MP    | 1.55   | 1.68  | 134.4            |
| gray, icons               | 9.11   | 9.66  | 315.5            |
| gray, to 1 MP             | 1.29   | 1.68  | 955.0            |
| gray, over 1 MP           | 1.09   | 1.43  | 941.2            |
| all (220)                 | 1.87   | 2.16  | 268.0            |

No row's median is below 1 against libjpeg-turbo (before: 30, and 7 whose
interval was below 1). Against the other arms, all rows: stb 5.47×,
`image` 4.74×, Go 8.02×. The optimized and progressive icon rows read lower
than before; a direct interleaved A/B of the two builds on 16×16 and 64×64
photos, pinned, shows the new one 10-12% faster on both, so we take that as
the shared host, not the change. Peak RSS is unchanged (within 0.1 MiB), at
or below libjpeg-turbo's in every class.

## What changed

Each step measured with interleaved best-of-N runs pinned to one core
(`taskset -c 3`), two encoder builds back to back, on a 1 MP and a 16 MP
photo at quality 85, and the bytes compared with libjpeg-turbo's after each:

1. **No 512-bit instructions.** The WebP pass found that this host lowers
   the core clock after any zmm instruction (plan.md). Four places made
   them: the quantization's high multiplies (LLVM widened the 16-lane u16
   multiply to 32-bit lanes and used `vpmulhuw zmm`; now `simd.mulhu`,
   spelled out as `vpmulhuw ymm` like `madd`), the nonzero mask and the
   progressive magnitudes (64-lane compares; now four 16-lane ones), and
   the optimal table builder's 32-bit counts narrowed to bytes (now 16-bit).
   `objdump` finds no zmm in any `jpeg.*` function. Baseline 4:2:0 at 1 MP
   1.19×, 4:4:4 1.20×, 4:2:0 at 16 MP 1.25×.
2. **The coder's loop.** The AC table pointers are hoisted out of the
   block's loop (they were recomputed from the coder each symbol), and the
   0xff test for a full 64-bit word is a vector compare (`vpcmpeqb` on the
   word in an xmm register), so its constants no longer hold two general
   registers; the loop's mask and run no longer spill. 3-5% overall.
3. **Prefetching the source.** Over 1 MP the source comes from memory, and
   the color conversion alone did not keep enough reads in flight: it cost
   2.26 cycles a pixel on a 16 MP photo against 0.92 at 1 MP, at 3.4 GB/s
   where one core streams 12 GB/s. `fill` now prefetches the source row 4
   rows ahead: 418 to 553 MP/s on the 16 MP photo at 4:2:0 (1.32×; 2 to 8
   rows all alike, 1 row 1.08×), 1.13× at 4:4:4, 1.06× at 1 MP, and no
   change at 256×256.

Tried and dropped: each coefficient's category and value bits computed for
the whole block in vectors before the loop, as libjpeg-turbo's x86 coder
does (1.02× at 4:2:0, 0.98× at 4:4:4: not worth the code); the rare
stuffing path in a separate function (the same as an inline loop).

After the pass, stage costs on the 1 MP photo at 4:2:0 (rdtsc, cycles a
pixel): color conversion and downsampling 0.9, DCT and quantization 0.9,
entropy coding 2.7.

## Commands

```
just bench-compare 10 jpeg-encode jpeg-encode-444 jpeg-encode-optimized jpeg-encode-progressive jpeg-encode-gray
```

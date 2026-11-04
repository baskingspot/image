# JPEG XL decode: trees on one property as tables, 2026-11-04

A change to `image.jxl.Decoder`'s Modular decoding on `wave4-jxl-sptable`,
the second item of `jxl.md`'s speed list. It keeps the output bit for bit.

cjxl's fast lossless efforts write trees that test one property: at
`-e 2`, 33 splits all on property 9 (W + N − NW) with gradient leaves; at
`-e 3`, splits only on property 15 (the weighted predictor's largest
error) with weighted leaves. Both test values from −500 to 500. Walking
such a tree takes several dependent loads a pixel and computes every
property up to the one tested.

**The change.** `plan` now records the one property every reachable
non-static split tests (`Plan.single`), and the least and greatest values
they test (`lo`, `hi`). When that property is 2 to 15 and the range needs
no more than `flat_bytes / @sizeOf(Node)` entries (24,577) and no more
than the channel's pixels, `decodeChannel` fills a table of the leaf each
value reaches, from `lo` up to `hi` + 1, which stands for every value past
`hi` (`fillTable`, the statics resolved as `plan` resolves them). Each
pixel then computes only that property, clamps it into the table, and
loads its leaf (`decodeTabled`). The loop is specialized at compile time
for property 9 with the gradient and property 15 with the weighted
predictor, the trees cjxl writes; any other one-property tree takes the
same loop with the property and predictor read at run time. The table
takes the place of the flattened tree within `flat_bytes`, so
`Config.work_len` is unchanged. A 1,002-entry table is 16 KB.

## Results

Geometric means of the rows' medians, MP/s; peak RSS of the whole
operation, MiB, before → after. `cb` rows compare the generic loop alone
(before) with the specialized one (after).

| corpus               | operation (rows)           | before | after | change  | peak RSS      |
| -------------------- | -------------------------- | ------ | ----- | ------- | ------------- |
| `-e 2`               | `jxl-decode-lossless` (44) | 9.115  | 16.33 | +79.16% | 443.9 → 443.8 |
| `-e 3`               | `jxl-decode-lossless` (44) | 6.328  | 9.440 | +49.17% | 440.1 → 440.1 |
| `-e 7` (the bench's) | `jxl-decode-lossless` (44) | 6.025  | 6.014 | −0.18%  | 437.1 → 437.1 |
| `-e 2`, cb           | `jxl-decode-lossless` (44) | 15.98  | 16.55 | +3.59%  | 444.0 → 443.8 |
| `-e 3`, cb           | `jxl-decode-lossless` (44) | 9.274  | 9.692 | +4.51%  | 440.2 → 440.1 |

On `-e 2`, 41 of 44 rows are faster at p < 0.05 and none slower: the
photos and screenshots about 2× (kodim01 8.40 → 15.69 MP/s, the
50-megapixel mosaic 8.94 → 18.03, the 1313×6097 amazon.com screenshot
6.97 → 13.94), 16×16 icons +12–15%. On `-e 3` all 44 rows are faster:
kodim01 5.99 → 9.16, the mosaic 6.30 → 9.90, amazon.com 5.04 → 8.13,
16×16 icons +12–14%. The bench's own lossless files (`-e 7`) have mixed
trees and take the old walk: one row of 44 moves at p < 0.05 (a 16×16
icon, +12%). The specialized loop beats the generic one on 15 rows of
each corpus and loses on none (photos up to +12%), so it is kept.

Peak RSS does not move.

Method: `bench-image serve` builds side by side on the last core
(`taskset -c 3`), loops sized once (`BENCHTIME_MS=50`), 8 rounds
alternating which build goes first per row, benchstat (median MP/s,
Mann-Whitney U, n = 8), and GNU time's peak RSS per size class. The
`-e 2` and `-e 3` corpora are the bench's 44 lossless files decoded with
`djxl` and re-encoded with `cjxl -d 0 -e 2` and `-e 3` (libjxl 0.12),
under the bench's own file names. Both builds checksum the same on every
row of all three corpora, and the 303 JPEG XL files of `corpus/` and
`bench/corpus-gen/` and the 132 lossless files of the three bench corpora
hash the same as main.

Machine: Intel Xeon Processor @ 2.60GHz (Ice Lake, 4 vCPUs, AVX-512, a
shared cloud host), Linux 6.1, Zig 0.16.0. Base: main 6cf7a57.

Raw output in `jxl-sptable-20261104/`: `e2-*`, `e3-*`, and `e7-*` are main
against the change, and `e2-cb-*` and `e3-cb-*` the generic loop against
the specialized one.

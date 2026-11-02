# WebP lossless encode, stage 2, 2026-11-02

The follow-ups that docs/slop/results/webp-encode-20261102.md left open:
the encoder's 512-bit instructions, work memory for small images, and
speed at the low efforts on flat, few-color images. Machine and method as
there: Intel Xeon Processor @ 2.60GHz (Ice Lake server, 4 vCPUs), Zig
0.16.0 ReleaseFast for this CPU; A/Bs through
docs/slop/results/qoi-icons-20261102/ab.sh (`bench-compare`'s rounds with
the two builds as arms, pinned to core 3, interleaved, benchstat), on the
`webp-encode-z*` rows over the 21 files of `bench/corpus-gen/webp_encode`.

## No 512-bit instructions

The WebP decode pass found that this host lowers its clock after any zmm
instruction. The encoder had two sources: `std.sort.pdq` in
`codes.buildLengths`, whose pivot selection LLVM widens to 512 bits (110
zmm instructions), and `codes.lengthCodeCost`'s 16 products of counts and
lengths in 64-bit lanes (9). First an experiment: the same source built
with `-Dcpu=native-avx512f`, against the normal build, efforts 0, 1, 3, 5,
and 7, 8 rounds (`webp-encode-stage2-20261102/a0-no-avx512-experiment/`):

| effort | icons | 16 KP–1 MP | above 1 MP |
| ------ | ----- | ---------- | ---------- |
| 0      | 1.15× | 1.07×      | 0.98×      |
| 1      | 1.10× | 1.01×      | 0.99×      |
| 3      | 1.09× | 1.02×      | 1.00×      |
| 5      | 1.10× | 1.02×      | 1.00×      |
| 7      | 1.10× | 1.02×      | 1.02×      |

Geomean speed of the no-zmm build over the normal one, per size class (6
icons, 12 files to 1 MP, 3 above); all 105 rows 1.05×. Three rows are
significantly slower, all photos at effort 0 (down to 0.97×, kodim01 and
the Wikipedia photo), so the experiment was not shipped as is.

So the zmm cost icons about a tenth. The change keeps AVX-512 and removes
the zmm: `buildLengths` sorts its keys (count, symbol) with a byte-wise
radix sort that skips the bytes every key shares (the keys are distinct,
so any sort gives the same order and the same code), and `lengthCodeCost`
sums the products in 16 lanes of 16 bits, which cannot overflow (at most
`max_green` tokens of at most 7 bits). `objdump` finds no zmm instruction
in any `webp.encode*` function after it.

## Output-identical speedups

Three more changes that leave every output byte the same:

- The optimal parse relaxes the lengths 2 to 32 of each match eight at a
  time (`@Vector(8, f32)` costs and `@select`): each length writes its own
  entry, so it is the scalar loop reordered.
- Choosing the color cache size counts every literal once, and each
  size's cache hits apart, subtracting them after, instead of four
  histogram updates per literal for each of 11 sizes; inside a backward
  reference, a pixel equal to the one before is not stored again.
- Group tables sized by the entropy image's tile count, not the effort's
  cluster limit (memory, below).

Checked byte for byte against main's encoder on all 21 files at every
effort 0 to 9. All four changes together against main, 5 rounds, every
effort (`webp-encode-stage2-20261102/a1-identical/`):

| effort | icons | 16 KP–1 MP | above 1 MP |
| ------ | ----- | ---------- | ---------- |
| 0      | 1.19× | 1.08×      | 0.99×      |
| 1      | 1.13× | 1.15×      | 1.05×      |
| 2      | 1.12× | 1.10×      | 1.02×      |
| 3      | 1.12× | 1.11×      | 1.02×      |
| 4      | 1.11× | 1.09×      | 1.02×      |
| 5      | 1.06× | 1.08×      | 1.02×      |
| 6      | 1.11× | 1.07×      | 1.01×      |
| 7      | 1.10× | 1.06×      | 0.99×      |
| 8      | 1.11× | 1.03×      | 1.00×      |
| 9      | 1.11× | 1.01×      | 1.00×      |

Geomean speed after over before; all 210 rows 1.08×, and benchstat finds
no row significantly slower (96 rows within noise). Peak RSS of the
bench process is unchanged, 109–155.5 MiB in both arms (it holds the
whole corpus); the encoder's own memory is `workLen`, below.

## Work memory

`workLen` before and after, bytes (efforts 0, 1, 5, 9):

| size      | before                                            | after                                             |
| --------- | ------------------------------------------------- | ------------------------------------------------- |
| 16×16     | 1,110,624 / 516,608 / 1,242,016 / 4,082,080       | 174,368 / 294,464 / 309,856 / 309,856             |
| 64×64     | 1,187,440 / 608,880 / 1,976,224 / 6,491,488       | 251,184 / 386,736 / 861,936 / 861,936             |
| 768×512   | 8,972,880 / 10,964,752 / 17,839,360 / 22,354,624  | 8,036,624 / 10,979,280 / 17,853,888 / 22,369,152  |
| 1200×1200 | 23,639,920 / 32,121,008 / 42,680,144 / 47,195,408 | 22,703,664 / 32,135,536 / 42,694,672 / 47,209,936 |

The group tables (a `codes.Group` and a `codes.Histogram`, about 8 KiB
each, per group) were sized for the effort's cluster limit, up to 256 at
effort 9, even for an image with one tile. Effort 0, which has no entropy
image, now sizes no cluster groups at all. The 14,528 bytes the larger
sizes gain are the radix sort's buffer and the cache-size histograms'
literal totals. What remains on a 16×16 icon is fixed scratch, the color cache
size histograms the largest (94 KiB).

## The low efforts

`lz77.Params.nice` is the match length at which the finder stops
searching and the optimal parse takes a match whole. Measured with a
scratch CLI (each level's plan replaced, bytes exact, times one core and
indicative), the mid-size class (12 files) and all 21:

| plan                         | mid bytes | mid ms | all bytes | all ms |
| ---------------------------- | --------- | ------ | --------- | ------ |
| effort 1, nice 256 (stage 1) | 1,670,090 | 397    | 5,359,162 | 1,349  |
| effort 1, nice 64            | 1,671,912 | 351    | 5,362,536 | 1,320  |
| effort 1, nice 32            | 1,673,768 | 347    | 5,366,256 | 1,260  |
| effort 1, greedy parse only  | 1,709,282 | 312    | 5,576,350 | 1,047  |
| effort 2, chain 8, nice 256  | 1,614,660 | 607    | 5,175,126 | 2,135  |
| effort 2, chain 4, nice 64   | 1,616,902 | 535    | 5,180,100 | 1,940  |
| effort 3, nice 64            | +0.09%    | −6%    | +0.08%    | −6%    |
| effort 4, nice 64            | +0.09%    | −7%    | +0.09%    | −4%    |
| effort 5, nice 64            | +0.14%    | −7%    | +0.09%    | −4%    |
| effort 6, nice 64            | +0.31%    | −7%    | +0.14%    | −6%    |
| effort 7, nice 64            | −0.11%    | −7%    | −0.02%    | −3%    |
| effort 8, nice 64            | +0.17%    | 0%     | +0.19%    | −5%    |

Kept: nice 64 at effort 1, and chain 4 with nice 64 at effort 2: both
levels stay about 1% smaller than libwebp's in total and 1.6–2.7% file by
file (geomean), so a tenth of a percent buys an eighth of the time. Not at efforts 3 to 6 and 8,
where we are already up to 1.6% larger than libwebp file by file.

Effort 7 looked smaller and faster in total, and the bench-compare run
showed why that misleads. Per file, against stage 1 (`check-image.txt`
lengths):

| file           | effort 1 | effort 2 | effort 7 |
| -------------- | -------- | -------- | -------- |
| Number_2       | +5.3%    | +4.7%    | +5.4%    |
| qoi_logo       | +3.7%    | +3.3%    | +3.6%    |
| 3dbrick2       | +2.2%    | +5.0%    | +4.5%    |
| testcard_rgba  | +0.3%    | +3.4%    | +1.4%    |
| icon_512       | +0.9%    | +0.9%    | +0.7%    |
| academy_awards | +0.1%    | +0.1%    | −1.4%    |

Every other file moves under 0.3%. The flat, run-heavy images lose: on
them most matches reach 64, so the parse takes them whole instead of
weighing where to cut, and the chain search stops at a shorter candidate.
Effort 7's smaller total is academy_awards alone, and libwebp's `-z 7` is
already smaller than ours on exactly the files that grow (Number_2 12,092
bytes against our 12,218 before, 12,878 after). So effort 7 keeps stage
1's plan (chain 32, nice 256): its output is stage 1's, and its speed is
the output-identical A/B's. At efforts 1 and 2 the cost stays: libwebp's
`-z 1` and `-z 2` are larger than ours on Number_2 (15,242 and 15,294
bytes) and 3dbrick2 at effort 1, though qoi_logo at effort 1 (6,568
against 6,270) and 3dbrick2 and testcard_rgba at effort 2 (1,884 against
1,786, 9,670 against 9,586) cross over to larger than libwebp's.

Splitting the two uses of `nice`, the search stopping at 64 and the parse
weighing every match up to 256, recovered half of the flat images' loss
(effort 1: Number_2 +2.5%, qoi_logo +1.3%) and gave back half their time
(Number_2 23.0 ms against 13.5 at nice 64 and 30.4 in stage 1; all 21
files 1,295 ms against 1,215 and 1,419). At effort 7 the split was 0.1%
smaller in total than stage 1 and 4% faster, but still grew the flat
images by 0.5–2.9%. Not kept: at the speed levels the time is worth more
than the bytes, and at effort 7 the flat images are where we already
trail libwebp.

The flat images stay behind at effort 1: qoi_logo 6.5 ms (libwebp
1.65 ms), Number_2 13.7 ms (7.7 ms), water1 2.6 ms (1.45 ms). Their time is
spread out (qoi_logo: match finding about a quarter, the optimal parse a
fifth, ranking the transforms 7%, clustering a tenth, memset 7%), so
closing a 4× gap needs a different path for them, not a cheaper setting.

## Against libwebp

`just bench-compare 5 webp-encode-z0 … webp-encode-z9` on the final code,
6 rounds interleaved with libwebp and image-rs (`a2-final/`), and effort 7
again after it went back to stage 1's plan (`a2-final/z7-stage1-plan/`).
Our speed over libwebp's at the same level, geomean per class, stage 1
(docs/slop/results/webp-encode-20261102.md) then now; our MP/s now:

| effort | icons       | 16 KP–1 MP  | above 1 MP  | MP/s icon / mid / large |
| ------ | ----------- | ----------- | ----------- | ----------------------- |
| 0      | 1.28 → 1.51 | 1.12 → 1.19 | 1.57 → 1.55 | 10.9 / 52.5 / 35.7      |
| 1      | 0.97 → 1.08 | 0.61 → 0.90 | 1.20 → 1.33 | 3.5 / 11.9 / 7.9        |
| 2      | 1.01 → 1.13 | 0.68 → 0.93 | 1.15 → 1.31 | 2.7 / 7.7 / 5.4         |
| 3      | 1.49 → 1.64 | 1.02 → 1.11 | 1.27 → 1.31 | 2.4 / 5.6 / 4.4         |
| 4      | 1.53 → 1.67 | 0.95 → 1.03 | 1.29 → 1.34 | 2.4 / 5.0 / 4.2         |
| 5      | 2.43 → 2.69 | 0.94 → 1.01 | 1.28 → 1.27 | 2.3 / 4.4 / 3.8         |
| 6      | 2.75 → 3.04 | 0.92 → 0.98 | 1.23 → 1.27 | 2.2 / 3.7 / 3.0         |
| 7      | 2.72 → 2.98 | 0.84 → 0.93 | 1.53 → 1.56 | 1.9 / 3.0 / 2.4         |
| 8      | 9.51 → 10.6 | 1.77 → 1.84 | 1.27 → 1.31 | 1.9 / 1.7 / 1.7         |
| 9      | 18.5 → 20.8 | 2.47 → 2.54 | 2.10 → 2.15 | 0.6 / 0.3 / 0.4         |

All 210 rows: 1.38 → 1.55 (with effort 7's nice-64 row, which no longer
ships). The two runs are separate sessions, so libwebp's own times move
a few percent between them; the A/Bs above are the controlled numbers.
The mid-size class stays below libwebp at efforts 1, 2, 6, and 7, and
in each it is the flat images: qoi_logo runs 0.31× libwebp at effort 1,
0.22× at 2, 0.41× at 7, and Number_2 0.20× at 8; the photos and
screenshots are at or above 1. Against image-rs's one level (on the
effort 0 row) we are 0.41×, 0.35×, and 0.31× as fast, from 0.33× overall
in stage 1; it writes 1.10× our effort 0's bytes.

Size (`a2-final/size-by-level.txt`), ours over libwebp's at the same
level, total and geomean per file, all 21 files; unchanged from stage 1
except efforts 1 and 2 (`a2-final/size-by-level.txt`'s effort 7 line is
the nice-64 plan that no longer ships; the one here is stage 1's, which
`z7-stage1-plan/check-image.txt` matches byte for byte):

| effort | total  | geomean | vs libwebp `-z 9` |
| ------ | ------ | ------- | ----------------- |
| 0      | 0.8968 | 0.9147  | 1.1793            |
| 1      | 0.9911 | 0.9735  | 1.0610            |
| 2      | 0.9887 | 0.9839  | 1.0249            |
| 3      | 0.9955 | 1.0007  | 1.0213            |
| 4      | 0.9942 | 1.0009  | 1.0182            |
| 5      | 0.9878 | 1.0025  | 1.0078            |
| 6      | 0.9867 | 1.0033  | 1.0067            |
| 7      | 0.9897 | 1.0046  | 1.0063            |
| 8      | 0.9976 | 1.0156  | 1.0022            |
| 9      | 0.9998 | 1.0255  | 0.9998            |

The default (`a2-final/default-vs-libwebp.txt`): our effort 5 against libwebp's default `-z 6` is 3.19×
its speed on icons, 1.17× to 1 MP and 1.62× above (stage 1: 2.89×, 1.10×,
1.61×), at 0.988 of its bytes in total (icons 1.028, mid 0.992, large
0.986), the same bytes as stage 1. Decision 42 stands.

Peak RSS (MiB, `a2-final/rss.txt`) is stage 1's to within 0.1 MiB at
every level and class (icons 2.7–3.0 against libwebp's 4.3–8.7, mid
13.7–26.5 against 17.3–58.2, large 109–155.5 against 158–260): RSS counts
touched pages, and the group tables that `workLen` no longer asks for
were mostly never touched. The smaller `workLen` matters to a caller
that allocates it, such as an icon encoder holding a buffer per thread.

## What remains

- Flat, few-color images at the low and middle efforts: 0.2–0.5× libwebp
  on qoi_logo and Number_2. Their time is spread over match finding, the
  optimal parse, transform ranking, and clustering, so a fix is a
  separate path for them (libwebp tries a cheaper pipeline first), not a
  setting.
- File by file, efforts 3 to 9 are 0–2.6% larger than libwebp's at the
  same level (geomean), while smaller in total: our small and flat files
  lose, the photos win.

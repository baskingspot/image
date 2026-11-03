# WebP lossless encode: flat and few-color images, 2026-11-03

Stage 3 left flat, few-color images as the encoder's slow case: qoi_logo
ran 0.21–0.41× libwebp at efforts 1 to 7 on main, Number_2 0.40–0.76×,
and water1 0.57–0.83× (this stage's A/B), with
the time spread over match finding, the optimal parse, ranking the
transforms, and clustering. This stage finds where that time went and
takes it out without changing a byte of output: every change writes the
same stream as before, checked file by file at every effort.

Headline, from the direct A/B of this branch against main 93289ad:
over all 210 bench rows `image.webp.encode` is
1.28× as fast as main (geomean) and 1.96× libwebp, with the same bytes;
1.17–2.66× main on the 16 KP–1 MP class at efforts 1 to 9, 2.2× on
qoi_logo and 2.5× on Number_2 at effort 5. Three rows of 210 are slower
than main, by 0.5–1.5%. `webp.encodeAlpha`, the lossy encoder's ALPH
path, is 1.28×, 1.79×, and 2.71× main's speed at efforts 1, 5, and 8.
qoi_logo is still 0.39–0.66× libwebp at efforts 1 to 6, for a reason
that is about bytes, not speed (What remains).

Intel Xeon Processor @ 2.60GHz (Ice Lake server, 4 vCPUs; cores 2 and 3
are hyperthread siblings), Zig 0.16.0 ReleaseFast for this CPU, libwebp
1.6.0.
Raw output and scripts are in `webp-encode-flat-20261103/`.

## Sets

- `bench/corpus-gen/webp_encode`, the 21 bench files.
- A few-color set: the GIF bench stills up to 5 MP, 42 files, as raw RGBA
  (`scripts/few.sh`): the same sources quantized to at most 256 colors,
  dithered photos as well as flat images. The bench files have only three
  palette images (qoi_logo, water1, 3dbrick2), so this set checks that a
  change for them holds on palette images in general.
- The ten alpha planes of `webp-encode-alpha-20261102.md`, for
  `webp.encodeAlpha`.

## Where the time went

The scratch CLI (`scripts/rgb.zig`) built with rdtsc timers around the
encoder's phases (`scripts/phases.py` patches a copy of `src`), main and
this branch, 30 encodes each on core 0, Mcycles per encode
(`a6-phases/`). "parse + cache" is the greedy parse and the color cache
choice; "transforms" includes the predictor and color transforms' search.

| file                    | rank        | transforms    | find        | parse + cache | optimal     | groups       | total         |
| ----------------------- | ----------- | ------------- | ----------- | ------------- | ----------- | ------------ | ------------- |
| qoi_logo, effort 1      | 1.4 → 1.1   | 1.0 → 0.4     | 5.1 → 2.9   | 0.8 → 0.6     | 3.8 → 2.8   | 2.7 → 1.3    | 15.2 → 9.4    |
| qoi_logo, effort 5      | 1.4 → 1.1   | 1.1 → 0.4     | 9.7 → 3.5   | 0.9 → 0.6     | 9.7 → 5.6   | 24.8 → 6.5   | 48.0 → 18.0   |
| Number_2, effort 5      | 1.9 → 2.0   | 0.7 → 0.7     | 32.7 → 11.7 | 2.4 → 1.9     | 23.2 → 16.8 | 39.3 → 9.6   | 101.4 → 43.8  |
| kodim01 few, effort 1   | 18.7 → 17.8 | 9.2 → 4.5     | 43.1 → 49.3 | 43.8 → 22.3   | 39.2 → 42.0 | 14.4 → 15.1  | 178.0 → 161.2 |
| kodim01 photo, effort 5 | 9.3 → 9.4   | 141.5 → 141.1 | 54.4 → 60.3 | 37.5 → 25.2   | 30.0 → 32.5 | 144.2 → 71.3 | 430.0 → 353.2 |

On main, clustering was half of qoi_logo's time at effort 5 and two
fifths of Number_2's: the merge priced pairs of groups 26,000 and 50,000
times (4,110 and 4,101 now). At effort 1 the color cache choice was a
quarter of a dithered photo's time (few-color kodim01), and on flat
images the match finder and the parse compared the same long matches
pixel after pixel. The photos' match finding and optimal parse are 7–14%
slower than on main (What remains).

## The changes

Each writes the same bytes. `scripts/same.sh` encodes the 21 bench files
and the 42 few-color files with main and this branch and compares every
output with `cmp`: 0 of 63 differ at each effort from 0 to 9
(`same-final.txt` has efforts 2, 4, 6, and 9 of the final build; 0, 1,
3, 5, 7, and 8 were run on it before). The bench harness's checksums
agree with main on all 210 rows, and the ten alpha planes' streams have
main's sizes, plane by plane, at efforts 1, 5, and 8.

- **Clustering keeps each pair's cost** (`encode_entropy.zig`, `merge`).
  The merge of groups priced a pair (`histCost`) again every time either
  group's best partner had to be found anew, though a pair's cost only
  changes when one of the two is merged. It now prices each pair once and
  again only for the merged group: on qoi_logo at effort 5, 4,110
  `histCost` calls instead of 25,972; on Number_2, 4,101 instead of 50,142. The
  pairs take k² floats of work memory, k being the starting groups (at
  most 64 at effort 5, 256 at effort 9: 16 KiB and 256 KiB).
- **Tile symbols by their bits** (`cluster`). Listing each tile's symbols
  walked all 1,352 of a group's symbols per tile; it now walks a bit set
  of the ones the tile used, in the same order. The tile's column follows
  the tokens instead of a division per token.
- **Match lengths carried along a match** (`encode_lz77.zig`, `Known`).
  The lengths of the left and upper matches in the match finder, and of
  the near distance codes in the optimal parse, were compared afresh at
  every pixel: in a flat region, up to the full match at each pixel. A
  match at distance d that runs to pixel e from pixel i runs to e from
  i + 1 too, so the next pixel's length is known, or known up to where it
  stopped being compared.
- **The chain passes a run's own pixels by.** Inside a run of equal
  pixels, the hash chain's newest entries are the run's earlier pixels,
  which match only to the run's end, as the left pixel does, so they can
  never be the longest. The search now starts after them, from the link
  the run's first pixel left, with their share of its budget spent, and
  with none left it does not start.
- **Near matches the longest already covers** (parse). A
  near distance code's match is not relaxed when its code costs at least
  the longest match's and every length it would weigh is one the longest
  match's relaxation already weighed: with float rounding monotone, its
  totals are never below the longest's, which the parse wrote first and
  keeps on ties.
- **The color cache chosen in one pass** (`encode.zig`, `chooseCache`).
  Every cache size sees the same pixels, and a slot holds the last pixel
  whose hash starts with its index, so a pixel one size holds, every
  larger size holds too. A literal's channels are now counted once, by
  the smallest size that holds it, and the sizes' tallies summed from the
  largest down, instead of five counts for each of up to ten sizes; the
  slots are checked and written without branches.
- **Fewer divisions.** The left and upper pixels' distance codes are
  worked out once per image, not per match (each took an `i64` division);
  the clustering follows a token's column instead of dividing; the color
  transform's sampling counts down instead of a modulo. Ranking the
  transforms keeps its `i % width` (Tried and not kept).
- **The palette found once.** `build` reuses the palette and table that
  `rankModes` found, while they are still unchanged.
- **The hash head emptied by its entries.** Every search cleared the
  whole head table, sized for the main image (512 KiB for qoi_logo),
  even for a 256-entry palette image. The head now starts empty once per
  encode, and each search empties the entries it filled when they are
  few, or clears the table when not; a search without a chain (effort
  0, alpha planes) touches none.

## A/B

`scripts/ab.sh` (the harness's interleaved rounds, arms as binaries,
pinned to core 3, 50 ms samples), benchstat, `zig build bench`'s
`bench-image` per arm, all ten `webp-encode-z*` rows, 210 rows an arm.

### This branch against main (`a3-final/`)

5 rounds, three arms: this branch (9537525), main (93289ad), and
libwebp. 0 of 210 checksums differ from main. Our speed over main per
class (geomean), over libwebp in brackets, and our MP/s:

| effort | icons        | 16 KP–1 MP  | above 1 MP  | MP/s icon / mid / large |
| ------ | ------------ | ----------- | ----------- | ----------------------- |
| 0      | 1.01 (1.55)  | 1.08 (1.32) | 0.99 (1.55) | 11.0 / 55.8 / 35.0      |
| 1      | 1.03 (1.11)  | 1.17 (1.03) | 1.04 (1.34) | 3.6 / 13.6 / 8.1        |
| 2      | 1.03 (1.16)  | 1.22 (1.13) | 1.04 (1.35) | 2.8 / 9.3 / 5.5         |
| 3      | 1.03 (1.69)  | 1.32 (1.47) | 1.04 (1.35) | 2.4 / 7.3 / 4.4         |
| 4      | 1.02 (1.68)  | 1.36 (1.42) | 1.06 (1.39) | 2.4 / 6.9 / 4.3         |
| 5      | 1.03 (2.76)  | 1.47 (1.48) | 1.06 (1.35) | 2.3 / 6.3 / 4.0         |
| 6      | 1.04 (3.12)  | 1.53 (1.50) | 1.05 (1.29) | 2.2 / 5.5 / 3.0         |
| 7      | 1.03 (3.14)  | 1.52 (1.36) | 1.10 (1.68) | 1.9 / 4.6 / 2.6         |
| 8      | 1.03 (10.87) | 2.03 (3.68) | 1.17 (1.51) | 2.0 / 3.3 / 2.0         |
| 9      | 1.04 (21.43) | 2.66 (6.70) | 1.32 (2.75) | 0.6 / 0.7 / 0.5         |

All 210 rows: 1.28× main, 1.96× libwebp. Three rows are significantly
slower than main: tecnick 1200×1200 at effort 0 (0.985×) and the 16×16
appointment icon at efforts 3 and 8 (0.982× and 0.995×). The flat
files, ours over main and over libwebp:

| effort | qoi_logo ×main | ×libwebp | Number_2 ×main | ×libwebp | water1 ×main | ×libwebp |
| ------ | -------------- | -------- | -------------- | -------- | ------------ | -------- |
| 0      | 1.29           | 1.25     | 1.10           | 1.79     | 1.05         | 2.42     |
| 1      | 1.46           | 0.45     | 1.29           | 0.89     | 1.23         | 0.71     |
| 2      | 1.73           | 0.39     | 1.41           | 1.08     | 1.23         | 0.77     |
| 3      | 1.84           | 0.46     | 2.02           | 1.28     | 1.26         | 0.98     |
| 4      | 1.96           | 0.42     | 2.05           | 1.20     | 1.23         | 0.95     |
| 5      | 2.21           | 0.61     | 2.47           | 1.13     | 1.25         | 1.04     |
| 6      | 2.34           | 0.66     | 2.82           | 1.13     | 1.24         | 1.02     |
| 7      | 2.35           | 0.96     | 2.84           | 1.28     | 1.23         | 0.76     |
| 8      | 2.50           | 7.72     | 4.88           | 0.93     | 1.23         | 8.85     |
| 9      | 2.29           | 13.89    | 7.58           | 4.69     | 1.19         | 27.00    |

27 of 210 rows are below libwebp's speed, against 48 on main: qoi_logo
at efforts 1 to 7, water1 at 1 to 4 and 7, kodim01 at efforts 1 and 2
(0.74× and 0.86×), plant_01 at effort 0 (0.80×), and 32×32 and 64×64
icons at efforts 1 and 2 (0.91–0.98×). The output is main's, byte for
byte, so the size standing against libwebp is still that of
`webp-encode-stage2-20261102.md`.

Peak RSS of the bench process (all inputs loaded), MiB:

| effort | ours  | main  | libwebp |
| ------ | ----- | ----- | ------- |
| 0      | 109.1 | 109.1 | 157.9   |
| 1      | 152.4 | 152.4 | 155.5   |
| 2      | 152.7 | 152.7 | 214.2   |
| 3      | 152.7 | 152.9 | 214.0   |
| 4      | 152.9 | 152.9 | 213.3   |
| 5      | 153.5 | 153.5 | 216.9   |
| 6      | 153.5 | 153.5 | 212.9   |
| 7      | 153.4 | 153.4 | 212.7   |
| 8      | 154.2 | 154.2 | 212.9   |
| 9      | 156.0 | 155.7 | 251.2   |

### The two batches

The work went in two commits, each measured against the one before.
The first (`a1-batch1/`, 5 rounds, main and libwebp beside it): the
clustering's pair costs and tile bits, the carried match lengths and the
run skip, the one-pass cache choice, and the divisions; 1.27× main over
all 210 rows. Its effort 0 was 1–4% slower than main (the photos 5–7%),
and its ranking took each pixel's column from a counter.

The second (`a2-batch2/`, 4 rounds against the first): the dominated
near matches, the hash head emptied by its entries, the palette found
once, left and upper matching inside the match loop, and the ranking's
`i % width` back. 1.01× the first over all rows: effort 0 1.02–1.10× by
class (it won back the first's loss), flat files 3–24% faster, and 22
rows 0.92–0.97× the first, at efforts 1 to 9 on flat or few-color
images (dice 0.92 at effort 1, Number_2 0.93 at effort 2), which we
put down to the ranking's division coming back: the first batch had
taken it out, which made the photos' ranking 1.3× slower (Tried and not
kept). The direct A/B above
is the net of both.

## The few-color set against cwebp

`scripts/fewcmp.sh`: the 42 files, best of three encodes each with
`scripts/rgb.zig` on core 2, and cwebp `-z L` from the same files as
PNG, its own "Time to encode", best of three (`a5-few/`). Our bytes are
main's, byte for byte. Main's times are from a separate run of the same
script, so the column is a guide, not an A/B.

| effort | our bytes | libwebp bytes | size  | main ms | ours ms | libwebp ms | × main | × libwebp |
| ------ | --------- | ------------- | ----- | ------- | ------- | ---------- | ------ | --------- |
| 1      | 5,052,524 | 5,528,586     | 0.914 | 1,896   | 1,744   | 1,336      | 1.09   | 0.77      |
| 3      | 4,781,704 | 4,783,846     | 1.000 | 2,415   | 2,204   | 2,712      | 1.10   | 1.23      |
| 5      | 4,697,320 | 4,768,478     | 0.985 | 2,776   | 2,273   | 3,113      | 1.22   | 1.37      |
| 7      | 4,645,366 | 4,725,868     | 0.983 | 4,675   | 3,905   | 5,987      | 1.20   | 1.53      |

At effort 1 we write 8.6% fewer bytes than cwebp `-z 1` in 1.3× its
time.

## Alpha planes

`scripts/abalpha.sh`: `webp.encodeAlpha` on the ten planes, best of five
encodes per plane, main and this branch interleaved within each round,
pinned to core 3, 8 rounds at efforts 1, 5, and 8 and 12 more at effort
1 (`a4-alpha/`; the first run's effort 1 rows were disturbed, with
±46–81% spreads). Every plane's stream has main's size.

| effort | main, ms for ten | this branch | geomean speedup | range      |
| ------ | ---------------- | ----------- | --------------- | ---------- |
| 1      | 117.7            | 93.7        | 1.28×           | 1.11–1.42× |
| 5      | 342.6            | 217.1       | 1.79×           | 1.23–2.29× |
| 8      | 825.3            | 316.8       | 2.71×           | 1.36–4.97× |

Alpha planes are the flat case at its purest: long runs and few values,
so the carried lengths, the run skip, and the cached pair costs all
apply.

## Work memory

`webp.workLen` is 36 KiB smaller at efforts 1 to 7 on a 16×16 icon
(12–32 KiB on large images: the cache choice's tallies shrank) and
larger at efforts 8 and 9, by 36 KiB and 228 KiB: the pair costs take k²
floats, k the starting groups (16 KiB for 64 groups to effort 7, 64 KiB
for 128 at effort 8, 256 KiB for 256 at effort 9), less what the tallies
saved. Effort 0 is unchanged.

## Tried and not kept

- **The cache tallies by index.** Counting each literal once, by its
  smallest holding cache and its index in the largest, and folding the
  tallies down after, saves nine increments a literal: 2–3% on
  literal-heavy images, but icons 15% slower at effort 1 (0.12 → 0.14
  ms) from the 48 KiB more it clears.
- **Cheaper `histCost` arithmetic.** The pair cost is latency-bound on
  one float sum (perf: the add of `x log x` and the loop counter after
  it). Its header bits in an integer (exact, since they are small whole
  numbers) and the sum split in two (not exact) measured the same as
  main.
- **Ranking without a division.** Taking each pixel's column from the
  loop instead of `i % width` made the ranking 1.8× faster on flat
  images but 1.3× slower on photos (kodim01 and wikipedia_001, efforts 0
  and 1), with or without the division elsewhere and with the
  histograms split by pixel parity. Unexplained; the first batch had
  it, the second puts the division back in the ranking loop and keeps
  the column only in the palette's, which runs on palette images alone.
- **Lengths not carried at effort 0, and the chain search called only
  when it searches.** Both measured slower at effort 0 than what ships
  (findMatches 3–8%), though each does less; the code layout of the
  match loop moves its time by about that much.
- **Pricing the parse from a first parse without the chain** (as the
  alpha planes' write-up suggested): bench files 0.0% at effort 1 and
  −0.1% at 5, but the few-color set +5.1% and +2.2%.
- **Cheaper plans** (all images, effort 5): 16 starting groups instead of
  64, +0.44% bytes on the bench files and +1.3% on the few-color set, for
  qoi_logo 1.39× and Number_2 1.23×; the parse without its near codes,
  +0.20% and +0.66%, 1.18× on the few-color set. Neither is proposed.

## What remains

- qoi_logo at efforts 1 to 6, 0.39–0.66× libwebp. libwebp writes 6,270
  bytes for it at every level from `-z 1` to `-z 9`; our effort 0 writes
  6,252 at 1.25× libwebp's `-z 0` speed, but efforts 1 to 9 write
  6,356–6,568, because the hash chain's far matches lead the parse to
  dearer codes, as on the alpha planes. Effort 1 without the chain writes
  6,238 bytes in 0.8× the time; over the bench files it is 28% faster for
  +0.74% bytes (3dbrick2 +19%, which needs its far matches), the trade
  decision 66 declined. No cheap feature found yet tells qoi_logo from
  3dbrick2 (both palette images, 96% of pixels equal to the left or upper
  one), and encoding both ways costs 1.7× the time.
- water1 (128×128) at the low efforts: 0.71–0.77× at efforts 1, 2, and 7, and 0.95–0.98× at 3 and 4 libwebp. Its time is a
  fixed cost per encode more than per pixel (the cache choice's tallies
  and the clustering's setup).
- The photos' match finding and optimal parse take 7–14% more cycles than
  main's in the phase build (kodim01, few-color and photo); taking the
  carried lengths out did not change it, and repeated runs vary by about
  as much, so it is not traced. The whole encode of those files is still
  1.04–1.23× main's speed.

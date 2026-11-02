# WebP lossless encode: alpha planes, 2026-11-02

The lossy encoder's orb (it compresses ALPH with `image.webp.encodeAlpha`)
found three things on ten RGBA images with transparency: our alpha
streams were 5–8% larger than libwebp's at the matching method, effort 9
wrote a larger stream than effort 5 (135,972 bytes against 134,951), and
effort 1 was slow on planes with much transparency. One change answers all
three: `encodeAlpha` searches no hash chain, at any effort. Alpha streams
are 5–9% smaller and 1.16–1.60× faster from effort 1 up, effort 9 is the
smallest, and `image.webp.encode`'s output is unchanged.

Intel Xeon Processor @ 2.60GHz (Ice Lake server, 4 vCPUs), Zig 0.16.0
ReleaseFast for this CPU, libwebp 1.6.0.

## The set and the bar

The lossy orb's ten images, from `bench/corpus-gen/.src`, their alpha
channels extracted to one byte a pixel (`scripts/planes.sh`): Number_2
600×600, academy_awards 447×1192, air_pump 999×772, dice 800×600,
qoi_logo 448×220, testcard_rgba 256×256, plant_01 166×1022, plant_02
1024×1316, and two icons, 512×512 and 64×64; 4.1 megapixels. libwebp's
streams are the ALPH chunks of `cwebp -q 75 -m M` (`libwebp-alph.txt`,
read by `scripts/alph.py`); its time for them is cwebp's own encode time
with `-alpha_method 1` less with `0`, once per image:

| cwebp  | ALPH bytes (filter fast) | none    | best    | alpha time |
| ------ | ------------------------ | ------- | ------- | ---------- |
| `-m 0` | 183,755                  | 215,190 | 178,708 |            |
| `-m 2` | 138,509                  | 134,978 | 134,083 | 142 ms     |
| `-m 4` | 131,943                  | 131,988 | 130,858 | 258 ms     |
| `-m 6` | 124,968                  | 125,021 | 123,629 | 20.1 s     |

The filter is not where libwebp wins: unfiltered, its streams are within
0.1% of filtered from `-m 4` up. `webpinfo -bitstream_info` reports no
transform in its ALPH streams (air_pump's, for one): no palette, no
predictor, only backward references, a color cache, and prefix codes. So
the gap was in our backward references and their codes.

## Where the bytes went

Our streams per effort before (main 9c30bff), from the scratch CLI
(`scripts/cli.zig`), all ten planes:

| effort | 0       | 1       | 2       | 3       | 4       | 5       | 6       | 7       | 8       | 9       |
| ------ | ------- | ------- | ------- | ------- | ------- | ------- | ------- | ------- | ------- | ------- |
| before | 147,524 | 145,502 | 143,507 | 137,398 | 136,483 | 134,951 | 135,644 | 135,610 | 136,094 | 135,972 |
| after  | 147,524 | 132,681 | 131,078 | 130,689 | 129,518 | 127,787 | 127,787 | 127,606 | 127,123 | 127,084 |

Each plane is green-only, and the encoder picked the direct or predictor
mode for every one. Counting the final tokens of air_pump at effort 1 (a
scratch build): with the hash chain (4 candidates), 892 literals, 800
references to the left or upper pixel covering 147,284 pixels, and 1,331
references at other distances covering 623,052, whose distance codes took
3,170 bytes, 19 bits each; 6,830 bytes in all. Without the chain, 3,336
literals and 1,533 left or upper references; distances 191 bytes; 4,891
bytes in all. The far matches are exact and longer than the left or upper
one, but the parse that takes them is worse: the optimal parse prices
symbols from a first parse, and a first parse full of far references
makes literals and near references look dear and far ones cheap, so the
optimal parse keeps them; in a parse without them the prices are the
other way round. Experiments at effort 5 (all ten planes, bytes):

| plan                                                     | bytes   | time     |
| -------------------------------------------------------- | ------- | -------- |
| main (chain 8, nice 256)                                 | 134,951 | 1.0×     |
| the parse weighs 4, 8, or 16 neighborhood codes, not 2   | 134,699 | 1.2–2.2× |
| the parse takes no match whole (nice 4096)               | 129,319 | 1.8×     |
| that, priced from a parse without the chain              | 127,408 | 2.3×     |
| far distance symbols priced 4, 8, or 16 bits dearer      | 133,305 | 1.0×     |
| the chain searched only below a left/upper match of 4–32 | 134,775 | 1.0×     |
| no hash chain (left and upper references only)           | 127,787 | 0.82×    |

At effort 1 the same: no chain, 132,681 bytes at 0.82× the time; the
parse without its whole-match shortcut, 138,056 at 2×.

The chain does help some planes, ones with repeated shapes away from
the left and upper pixels: Number_2 (3,761 bytes at effort 5 with it,
3,952 without) and testcard_rgba (1,369, 1,641). Keeping the smaller of
both encodes saves 263 bytes over no chain at effort 5 (0.2%), for twice
the time; not done. On RGB images the chain earns its time: no chain is
0.5–1.1% larger over `bench/corpus-gen/webp_encode` at efforts 1 to 8
(3dbrick2 +19–31%, the apple screenshot +3%), so `encode` keeps it.

## The change and its A/B

`Encoding.run` sets the plan's chain to 0 for an alpha source; nothing
else differs. A/B, main against the change, the scratch CLI's best of 5
encodes per plane, both binaries interleaved within each of 10 rounds,
pinned to core 3 (`scripts/abalpha.sh`), benchstat (`a1-alpha/`):

| effort | bytes before | after   | size  | speed (geomean) | MP/s before | after |
| ------ | ------------ | ------- | ----- | --------------- | ----------- | ----- |
| 0      | 147,524      | 147,524 | 0     | 0.97×           | 111.1       | 108.0 |
| 1      | 145,502      | 132,681 | −8.8% | 1.16×           | 29.5        | 35.6  |
| 4      | 136,483      | 129,518 | −5.1% | 1.17×           | 11.5        | 13.9  |
| 5      | 134,951      | 127,787 | −5.3% | 1.16×           | 10.4        | 12.2  |
| 8      | 136,094      | 127,123 | −6.6% | 1.60×           | 3.4         | 5.1   |

From effort 1 every plane is significantly faster (effort 1: 6–23%;
academy_awards 1.17×, plant_02 1.29×) but one: testcard_rgba at effort 4,
3.8% slower. Effort 0 already used no chain,
so its work is the same; four of its planes measured 2–7% slower and the
rest the same. An A/A of main against a copy of itself (`a0-aa/`) shows
no order effect (+0.08%, no plane significant), and the same rows came
out again with the plan passed in by `encodeAlpha` instead, so it is the
build's code layout, not the change's work. `encode` writes the same
bytes as before (`a2-rgb/checksums.txt`: 0 of 42 rows differ), and its
bench rows at efforts 0 and 1, 8 rounds, are 1.00× with no row slower
(`a2-rgb/summary.txt`).

Per plane, bytes:

| plane                     | effort 1 before | after   | effort 5 before | after   | effort 8 before | after   | libwebp `-m 4` | `-m 6`  |
| ------------------------- | --------------- | ------- | --------------- | ------- | --------------- | ------- | -------------- | ------- |
| icon_512 (512×512)        | 6,944           | 6,335   | 6,583           | 6,180   | 6,269           | 6,167   | 5,824          | 5,715   |
| icon_64 (64×64)           | 342             | 341     | 431             | 427     | 431             | 427     | 327            | 327     |
| Number_2 (600×600)        | 3,973           | 4,036   | 3,761           | 3,952   | 3,759           | 3,958   | 3,966          | 3,267   |
| academy_awards (447×1192) | 9,678           | 6,563   | 8,284           | 6,563   | 8,267           | 6,493   | 6,428          | 6,357   |
| air_pump (999×772)        | 6,830           | 4,891   | 6,554           | 4,809   | 6,585           | 4,634   | 4,619          | 4,610   |
| dice (800×600)            | 49,097          | 48,659  | 46,407          | 45,727  | 47,475          | 45,561  | 49,503         | 45,197  |
| qoi_logo (448×220)        | 6,175           | 5,843   | 5,962           | 5,771   | 5,966           | 5,827   | 5,854          | 5,785   |
| testcard_rgba (256×256)   | 1,471           | 1,573   | 1,369           | 1,641   | 1,368           | 1,641   | 1,683          | 1,311   |
| plant_01 (166×1022)       | 9,430           | 8,513   | 8,486           | 8,484   | 8,465           | 8,485   | 8,547          | 7,803   |
| plant_02 (1024×1316)      | 51,562          | 45,927  | 47,114          | 44,233  | 47,509          | 43,930  | 45,192         | 44,596  |
| total                     | 145,502         | 132,681 | 134,951         | 127,787 | 136,094         | 127,123 | 131,943        | 124,968 |

Against libwebp: effort 1 (115 ms for the ten) is 0.6% larger than `-m 4`
in under half its alpha time (258 ms), and 4.2% smaller than `-m 2`
(138,509 bytes, 142 ms). Effort 4 (294 ms) is 1.8% smaller than `-m 4`.
Effort 8 (0.79 s) is 1.7% larger than `-m 6` at a twenty-fifth of its time
(20.1 s); effort 9 (10 s) saves 39 bytes more. Per heavy plane at effort
1, against `-m 4`'s alpha time: academy_awards 9.2 ms (14 ms), plant_02
32 ms (38), air_pump 11 ms (30), dice 31 ms (84). Effort 0 stays the fast
one: 38 ms, 6.5% larger than `-m 2`.

Every stream decodes exactly: through our ALPH decoder (the unit test),
through libwebp (`scripts/splice.py` puts each into cwebp's file as its
ALPH chunk and compares dwebp's alpha with the plane: efforts 0, 1, 5, 9,
0 mismatches), and now in the fuzz target and the oracle, which wrap the
stream in a VP8L header (`test/fuzz/webp_encode.zig`'s `alphaFile`): a
quarter of the oracle's inputs are alpha planes, about 3,100 of 20,000,
and agree with libwebp and Wuffs.

## Not kept

- A table of each length prefix's longest length, for the optimal parse's
  relaxation past length 32 instead of computing the prefix per bucket:
  the same bytes, but on the RGB bench rows at efforts 1, 3, 5, and 7, 5
  rounds, 1.00× with 5 of 84 rows 2–5% slower (`x-length-tops/`).
- Finding the left and upper match lengths from run ends that only move
  forward, in `findMatches` and the parse: 13% slower at effort 1, 10%
  faster at effort 5 on the planes, and other bytes on RGB images.

## For the lossy encoder

It maps `.fast` to effort 0, `.default` to 1, and `.best` to 5. By size at
libwebp's time: effort 1 for `.fast` (132,681 bytes in 115 ms, against
`-m 2`'s 138,509 in 142 ms), effort 1 or 4 for `.default` (1 is 0.6%
larger than `-m 4` in under half the time; 4 is 1.8% smaller in about the
same), and effort 8 for `.best` (127,123 bytes in 0.79 s; 5 is 127,787 in
0.33 s; `-m 6` is 124,968 in 20 s).

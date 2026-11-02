# WebP lossless encode against libwebp, 2026-11-02

`image.webp.encode` (wave 5) against libwebp's lossless encoder, the bar
for speed and size, at each of cwebp's `-z` levels, and against image-rs
(`image-webp`), whose one level runs on the `-z 0` row. Go has no WebP
encoder (golang.org/x/image/webp decodes only). Every arm encodes raw RGB
or RGBA8 pixels from memory into a WebP in memory per call
(`webp-encode-z0` to `webp-encode-z9`, bench/ops.tsv, all `own`: outputs
differ, so they are compared by size, not checksum). Throughput is
megapixels per second; a ratio is this package's throughput over the
arm's (above 1, ours is faster), the geometric mean over a size class's
rows of each row's median paired ratio over the rounds.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU; C arms `cc -O3
-march=native`, Rust `target-cpu=native`. `just bench-compare 5` over the
ten rows: each arm runs as a server pinned to the last core (`taskset`),
the arms of a row back to back in an order that rotates by row and round,
`BENCHTIME_MS=50`, 5 counted rounds, compared with benchstat (`raw-*.txt`,
`benchstat.txt`, `summary.txt`, `rows.txt`; `config.txt`).

Inputs: the 21 files of `bench/corpus-gen/webp_encode`
(bench/corpus/webp_encode.sh): six icons (16×16 to 64×64), twelve images
up to a megapixel (photos, screenshots, textures, line art, test images),
and three larger (photos of 1200×1200 and 1276×850, and a 1313×4755 web
page screenshot), RGBA when the source has alpha. Not the 50-megapixel mosaic:
cwebp's `-z 9` takes seconds a megapixel.

The libwebp arm (bench/c/libwebp-webp_encode.c) is libwebp 1.6.0 through
`WebPConfigLosslessPreset(level)`, cwebp's `-z`, with `exact` set so that
the colors under transparent pixels survive, as ours keep them. Our
outputs of all 21 files decode exactly in dwebp at efforts 0, 3, 6, 8,
and 9; the oracle (test/oracle/webp_encode.zig) checks libwebp and Wuffs
on generated images at every effort. image-rs is `image` 0.25.9's
`WebPEncoder::new_lossless`.

## Speed

From `summary.txt`: our geometric-mean throughput per class and the
ratio of ours to libwebp's at the same level (above 1, ours is faster),
with the class's slowest row; "corpus" is the sum over the 21 files of each
arm's median time per call:

| effort | icons MP/s | icons vs libwebp | ≤1 MP MP/s | ≤1 MP vs libwebp | >1 MP MP/s | >1 MP vs libwebp | corpus: ours, libwebp | slowest row vs libwebp |
| ------ | ---------- | ---------------- | ---------- | ---------------- | ---------- | ---------------- | --------------------- | ---------------------- |
| 0      | 9.1        | 1.28             | 49.1       | 1.12             | 35.6       | 1.57             | 0.27 s, 0.40 s        | 0.69 (plant_01)        |
| 1      | 3.2        | 0.97             | 8.2        | 0.61             | 7.3        | 1.20             | 1.37 s, 1.68 s        | 0.16 (qoi_logo)        |
| 2      | 2.5        | 1.01             | 5.6        | 0.68             | 4.9        | 1.15             | 2.14 s, 2.48 s        | 0.13 (qoi_logo)        |
| 3      | 2.2        | 1.49             | 5.2        | 1.02             | 4.2        | 1.27             | 2.47 s, 3.53 s        | 0.20 (qoi_logo)        |
| 4      | 2.2        | 1.53             | 4.7        | 0.95             | 4.1        | 1.29             | 2.59 s, 3.58 s        | 0.17 (qoi_logo)        |
| 5      | 2.1        | 2.43             | 4.1        | 0.94             | 3.8        | 1.28             | 2.86 s, 3.89 s        | 0.24 (qoi_logo)        |
| 6      | 2.0        | 2.75             | 3.4        | 0.92             | 2.9        | 1.23             | 3.53 s, 4.65 s        | 0.25 (qoi_logo)        |
| 7      | 1.8        | 2.72             | 2.8        | 0.84             | 2.4        | 1.53             | 4.47 s, 5.99 s        | 0.36 (qoi_logo)        |
| 8      | 1.7        | 9.51             | 1.6        | 1.77             | 1.7        | 1.27             | 6.92 s, 9.18 s        | 0.19 (Number_2)        |
| 9      | 0.5        | 18.45            | 0.3        | 2.47             | 0.4        | 2.10             | 47.7 s, 74.4 s        | 0.66 (Number_2)        |

Against image-rs's one level on the `-z 0` row we are 0.33× as fast (it
runs 3× our speed) for files 1.10× larger than ours.

We are faster than libwebp on the large files at every level (1.15–2.10×)
and on icons from effort 2 (at effort 1, 0.97×), and slower on the
mid-size class at efforts 1, 2, and 4 to 7. That class's deficit comes
from three flat, few-color images: qoi_logo (448×220, 256 colors,
antialiased), Number_2 (600×600, 609 colors), and 3dbrick2 (320×240):
at efforts 1 to 7 we run 0.12–0.69× libwebp's speed on them, for files
20% smaller (Number_2 at efforts 1 and 2) to 3% larger. The class's other
nine files run 0.56–1.92× across those levels. A profile of qoi_logo at
effort 1 (`perf`, one core): the transforms, parse, and cache choice,
inlined into one function, take 52% of the time, about two fifths of it
in the optimal parse's relaxation of every length from 2 to 32; the match
finder 26%; the clustering's cost estimate 5%. On the mid-size class as a
whole, choosing the color cache size (four histogram updates per literal
for each of 11 sizes) is about a sixth of that function, and the
predictor about an eighth.

## Size

Bytes are exact (`size-by-level.txt`, made by `size-by-level.sh` from the
`check` passes). "total" is our class total over libwebp's at the same
level, "geomean" the geometric mean of the per-file ratios, and "vs z9" our
total over libwebp's `-z 9`:

| effort | icons total | icons geomean | ≤1 MP total | ≤1 MP geomean | >1 MP total | all total | all geomean | all vs z9 |
| ------ | ----------- | ------------- | ----------- | ------------- | ----------- | --------- | ----------- | --------- |
| 0      | 0.980       | 0.955         | 0.966       | 0.900         | 0.869       | 0.897     | 0.915       | 1.179     |
| 1      | 0.943       | 0.953         | 0.999       | 0.970         | 0.987       | 0.990     | 0.968       | 1.060     |
| 2      | 0.962       | 0.964         | 0.995       | 0.979         | 0.985       | 0.988     | 0.976       | 1.024     |
| 3      | 1.019       | 0.998         | 0.998       | 1.004         | 0.994       | 0.996     | 1.001       | 1.021     |
| 4      | 1.020       | 0.998         | 1.000       | 1.005         | 0.992       | 0.994     | 1.001       | 1.018     |
| 5      | 1.028       | 1.010         | 0.992       | 1.003         | 0.986       | 0.988     | 1.003       | 1.008     |
| 6      | 1.025       | 1.007         | 0.992       | 1.006         | 0.984       | 0.987     | 1.003       | 1.007     |
| 7      | 1.021       | 1.004         | 0.996       | 1.009         | 0.987       | 0.990     | 1.005       | 1.006     |
| 8      | 1.028       | 1.015         | 1.009       | 1.022         | 0.992       | 0.998     | 1.016       | 1.002     |
| 9      | 1.026       | 1.034         | 1.012       | 1.029         | 0.994       | 1.000     | 1.026       | 1.000     |

By total bytes we are smaller than libwebp at every level, by 10% at
`-z 0` and 0.02% at `-z 9`; the large files carry that. File by file we
are smaller up to effort 2 and 0.1–2.6% larger from effort 3 up, most on
icons (2–3% from effort 3) and, at efforts 8 and 9, on the mid-size
images: libwebp's slow levels try more per small file (its `-z 9` runs
several whole encodes per image) where ours stop at two. image-rs's one
level writes 6,577,700 bytes over the set, 1.10× ours at effort 0 and
1.30× libwebp's `-z 9`.

## Memory

Peak RSS (MiB), one pass over each class's inputs through
`bench-<arm> serve`, so the input and output buffers plus each library's
own memory (`rss.txt`):

| effort | icons ours | icons libwebp | ≤1 MP ours | ≤1 MP libwebp | >1 MP ours | >1 MP libwebp |
| ------ | ---------- | ------------- | ---------- | ------------- | ---------- | ------------- |
| 0      | 2.6        | 4.3           | 13.6       | 17.3          | 108.9      | 159.8         |
| 1      | 2.7        | 4.3           | 19.5       | 18.8          | 152.3      | 158.3         |
| 2      | 2.8        | 4.3           | 20.8       | 22.7          | 152.6      | 215.0         |
| 3      | 2.9        | 4.3           | 22.4       | 52.9          | 152.6      | 205.6         |
| 4      | 2.9        | 4.3           | 22.7       | 52.9          | 152.8      | 205.6         |
| 5      | 2.9        | 4.3           | 22.8       | 52.9          | 153.2      | 205.6         |
| 6      | 2.9        | 4.3           | 22.9       | 52.9          | 153.2      | 204.9         |
| 7      | 2.9        | 4.6           | 22.8       | 52.9          | 153.3      | 204.9         |
| 8      | 2.9        | 6.2           | 23.4       | 53.7          | 153.9      | 218.7         |
| 9      | 2.9        | 8.7           | 26.5       | 58.2          | 155.5      | 260.2         |

image-rs at its one level: 3.4, 10.7, and 87.6 MiB. Ours is at or below
libwebp's everywhere but effort 1 on the mid-size class (+0.7 MiB). Our
work memory (`workLen`) is fixed by the size and effort: 12–20 bytes a
pixel above 5 megapixels (the ARGB image, tokens, matches, the hash
chains, and the optimal parse's costs), 16–33 at 1200×1200 and 23–57 at
768×512 from effort 0 to 9, where the clustering's tables and fixed
scratch weigh more. Bench RSS counts only the pages touched.

## How each effort spends its time

All levels share one pipeline (docs: the module comment of
src/webp/encode.zig):

1. Rank the transform choices — none, subtract green, predictor (with the
   color transform), both, or color indexing when there are at most 256
   colors — by the entropy of the pixels that differ from their left and
   upper neighbors, which LZ77 would not cover. `tries` of them (2 at
   effort 9, else 1) are encoded fully and the smallest kept.
2. Predictor: per tile, a shortlist of `pred_keep` modes by absolute
   residual (always with the left and upper tiles' modes), chosen by the
   entropy of the residuals against what earlier tiles produced, with an
   8-bit bias toward repeating a neighbor's mode. Effort 9 adds a pass that
   chooses again against the whole image's residuals.
3. Color transform: per tile, least-squares starting multipliers, then
   steps of 8 down to 1, on every `cross_sample`th pixel.
4. LZ77: hash chains of `chain` candidates over two pixels, the longest
   match per pixel, a greedy parse, the color cache size that the parse's
   literals favor (exact histogram bits for every size), then, above
   effort 0, one optimal parse: a forward pass over costs from the greedy
   parse's histogram, trying the longest match, the same match a pixel
   shorter, and the two nearest distance codes.
5. Entropy image: tiles' histograms clustered (from quantiles of their
   entropy and, from effort 7, also from bins of their mean colors, keeping
   the smaller), merged pairwise while a merge saves bits by an estimate of
   each group's code cost, tiles moved to their cheapest group, for
   `rounds` passes, and kept only when its exact size beats one group.
6. Canonical codes from Huffman lengths, with any past 15 bits moved up
   until the code fits, written with the code-length code. Sizes come from histograms, so the file's length
   is known before a byte is written; the tests check that the count equals
   the bits written.

| effort | pred tiles           | keep | cross tiles      | chain       | cache | meta tiles | clusters                | other                                     |
| ------ | -------------------- | ---- | ---------------- | ----------- | ----- | ---------- | ----------------------- | ----------------------------------------- |
| 0      | 32 (3 modes, by SAD) | –    | none             | 0 (nice 16) | none  | none       | 1                       | greedy parse only, analysis every 4th row |
| 1      | 16 (SAD)             | –    | none             | 4           | all   | 64         | 16, 1 round             |                                           |
| 2      | 16                   | 2    | 64, every 4th px | 8           | all   | 32         | 32, 2 rounds            |                                           |
| 3      | 16                   | 4    | 32, every 4th px | 8           | all   | 16         | 32, 2 rounds            |                                           |
| 4      | 16                   | 4    | 32, every 4th px | 8           | all   | 16         | 48, 3 rounds            |                                           |
| 5      | 8                    | 4    | 32, every 2nd px | 8           | all   | 16         | 64, 3 rounds            |                                           |
| 6      | 8                    | 4    | 32, every 2nd px | 32          | all   | 16         | 64, 3 rounds            |                                           |
| 7      | 8                    | 6    | 32               | 32          | all   | 16         | 64, 3 rounds, 2 starts  |                                           |
| 8      | 8                    | 6    | 32               | 64          | all   | 16         | 128, 4 rounds, 2 starts |                                           |
| 9      | 8                    | 6    | 32               | 128         | all   | 16         | 256, 5 rounds, 2 starts | 2 transform tries, predictor refined      |

Tiles are side lengths in pixels; the entropy image's tiles grow until
there are at most 2600. "All" cache sizes means 0 to 10 bits.

## Rejected along the way

Measured with a scratch CLI over the same 21 files (bytes exact, times
single-core and ±5–10%), none kept:

- A bias toward the neighbors' color transform elements: no gain.
- A second optimal-parse pass: under 0.05% smaller for its time.
- Regrouping by parsing with each group's costs: oscillates.
- Starting the clustering from 512 bins: larger files.
- Two transform tries at effort 8: 0.1% for about 1.5× the time.
- 16-pixel color transform tiles at the default effort: larger.
- A literal cost of 4 bits before the optimal parse is right; the greedy
  levels use 12 (6 for color-indexed images), which keeps references only
  where they clearly pay.

## Recommended default

Effort 5, the current default. Against libwebp's default (`-z 6`,
`WebPConfigLosslessPreset(6)`: method 4 at quality 75, which is cwebp's
lossless default) it writes 1.2% fewer bytes over the set (icons 2.8%
more, mid-size 0.8% fewer, large 1.4% fewer) at 2.89× libwebp's speed on
icons, 1.10× on mid-size images, and 1.61× on large ones
(`default-vs-libwebp.txt`, from `default-vs-libwebp.py`). Effort 6 is 0.1%
smaller than 5 for 23% more time; effort 4 is 1% larger than 5 for 9%
less.

## Open

- Efforts 1 and 2 on flat, few-color images: libwebp's fast levels do far
  less per pixel there. The per-length relaxation and the cache-size
  histograms have output-identical speedups (5–10% on those files); the
  rest needs those levels to do less.
- Work memory has a fixed part sized by the effort's cluster limit, not
  the image: `workLen` asks for 0.5–4 MB for a 16×16 icon (13–57 bytes a
  pixel above a megapixel). Sizing the group tables by the entropy image's
  tile count would cut it to tens of KiB for icons without changing output.
- Icons are 2–3% larger than libwebp's from effort 3.

# JPEG XL lossless encode

`src/jxl/encode.zig` and `src/jxl/encode_*.zig`: a lossless Modular encoder
written from ISO/IEC 18181-1. The rest of `src/jxl/` is the decoder, owned
by the JPEG XL orb; the encoder uses its predictors, weighted predictor,
and alias table (below). Measurements: `results/jxl-encode-20261102.md` (stage 1) and
`results/jxl-encode2-20261102.md` (stage 2).

## Status

Stage 1: a working encoder at three efforts, decoding bit for bit in
libjxl, jxl-oxide, and our decoder, at about cjxl's sizes for its speed.
LZ77 was written and measured, and is not kept: it saved nothing on the
corpus (results file, "LZ77"). `default` is the default effort (decision
56).

Stage 2 (`wave5-jxl-encode2`): the oracle under a minute in oracle-ci,
tree learning faster on small images and in a third of the memory up to a
megapixel, and larger trees at fast and default, which closed most of the
gap on photos.

Stage 3 (`wave5-jxl-encode3`, `results/jxl-encode3-20261102.md`):
default's tree stops at 1024 leaves (decision 71), and groups take
palettes and color transforms of their own, which closed most of the
gap on screenshots.

Stage 4 (`wave5-jxl-encode4`, `results/jxl-encode4-20261103.md`): tree
learning counts faster, the same files.

Stage 5 (`wave5-jxl-encode5`, `results/jxl-encode5-20261103.md`): the
decoder's `pixelProps` replaces the encoder's copy, the same files; its
`walk` measured slower for the encoder and is not used.

Stage 6 (`wave5-jxl-encode6`, `results/jxl-encode6-20261103.md`): work
tables sized by the image, the same files; `workLen` at 16×16 is about a
seventh of what it was at fast and default.

Stage 7 (`wave5-jxl-encode7`, `results/jxl-encode7-20261103.md`):
default learns from one in 16 of a large image's samples, up to 2^20
(decision 75); images above a megapixel come out 1.0% smaller.

## What it writes

- A bare codestream (`FF 0A`). No option needs the container yet: there is
  no metadata to write.
- One Modular frame, lossless, no XYB. `ImageMetadata` gives the bit depth,
  the color space (sRGB, or gray with the sRGB transfer function), and
  alpha as an extra channel, `alpha_associated` for premultiplied sources.
- The stored format: an 8-bit source stays 8-bit, and 16-bit and float
  sources become 16-bit. CMYK becomes RGB. The file decodes to the source
  converted by `image.convert` to the stored format; the fuzz target and the
  unit tests check exactly that.
- Groups of 256 by 256 (`group_size_shift` 1). With one group, everything
  is in one section. Otherwise the TOC lists LfGlobal (tree, code, and the
  global stream), the LF groups and HfGlobal (empty), then the pass groups.
  The sections must all be written before the TOC, so the work memory
  holds the whole compressed image.
- Every stream writes its 32-bit ANS state, even one without tokens. With
  several groups, the global stream codes no channel. libjxl and our
  decoder do not read its state, but jxl-oxide does and failed with
  `UnexpectedEof` until we wrote it.

## Transforms

- **Palette** (global, every channel, alpha included) when the image has at
  most `palette_max` colors (256 fast, 1024 otherwise), and the palette's
  samples are at most an eighth of the image's. At half, as first written,
  32×32 and 64×64 icons with a few hundred colors came out 25–40% larger
  than without the palette. Gray only takes a palette when it uses at most a
  quarter of its range. Colors are sorted by alpha, then luma.
- **RCT** otherwise, for RGB: all 42 (6 permutations × 7 types), each
  scored by the entropy of its clamped-gradient residuals on row segments
  spread over the image (about `rct_pixels` pixels: as many segments as
  each is wide). The first version sampled whole rows, so a fast encode of
  a 768-wide photo saw one row and picked badly (Kodak +20–50%). The 42
  transforms' 126 channels are 15 distinct functions of R, G, and B; each
  is scored once, and a transform costs its three channels' sum.
- **Per group** (stage 3), when the image has several groups and no
  palette of its own: each group declares its own transform in its stream
  header, a palette of its colors or an RCT, scored like the image's on
  the group's own segments (`regionCosts`). The tree stays global, so a
  group's channels mean different things from group to group, and the
  rules below came from corpus runs rather than the estimate alone:
  - A group takes its own RCT only when it scores 3% under the image's
    (`rct_margin`). With no margin, Kodak photos and icons grew 1–3%;
    without group RCTs, the dice photo lost most of its 10% gain.
  - A group takes a palette (at most `palette_max` colors, at most an
    eighth of its samples) when its indices plus five bits a palette
    sample score under its channels, when it has at most 8 colors, or
    when 70% of the groups can take one (`pal_majority`). The estimate has
    no contexts and undervalues palettes on text: on cnn.com it turned
    down groups whose palettes save 3% of the file. A cost estimate with
    five gradient contexts judged worse, not better.
    libjxl e7 does the same per group: on the apple.com screenshot,
    `--modular_palette_colors=0` costs it 2.5%, and the best fixed RCT
    (`-C 13`) 0.9%.

## Tree learning

One tree codes every group. It is learned from samples: rows from every
stream, in a band whose offset moves from group to group, up to `samples`
samples; default takes one in 16 of a large image's, up to `samples_max`
(decision 75). Learning from a corner of the image, as the first version did, made
the tree fit only that corner.

- Properties: the specification's 16 (including the weighted predictor's
  error, property 15, at default and best), plus four for each of up to
  `refs` earlier channels (|v|, v, |v − pred|, v − pred), the properties
  that let a channel lean on the ones before it.
- Thresholds per property: every distinct value when there are few;
  otherwise half at quantiles of the samples and half spread over the
  distinct values, so that a long tail gets some. They are chosen from a
  sixteenth of the samples, between 1024 and 4096, sorted by counting when
  a property's values span fewer than 4096 (most do).
- Samples keep a byte per property, its bucket, not the i32 value. An image
  of at most 2^15 samples is sampled once with whole properties, which are
  then bucketed. A larger one is sampled twice over the same rows: first a
  random one pixel in `cap / 4096` with whole properties, to choose the
  thresholds from, then every sampled pixel straight into buckets. In a
  profile of a Kodak photo at default, sampling, both passes, took 10% of
  the time. A strided first
  pass, as the thresholds were taken before, made best 0.6% larger on the
  corpus: one pixel in 512 lands in the same column of a 256-wide group.
- Nodes are split breadth first, up to `max_leaves`. A node counts each
  token (hybrid-integer tokens, capped at 64) per property bucket and
  predictor. A scan over the buckets with running entropies finds the split
  that saves the most bits, when each side takes its best predictor. Counts
  are u16; the scan finds a row's nonzero entries with a vector compare
  and walks only those (stage 3 kept a mask per row, updated per sample,
  which cost more than it saved). Counting (`Count`) takes each
  sample's token columns once and walks only the properties with
  thresholds. A node clears the buckets it counted, so a small node costs
  as little as it holds.
- A split must save `split_cost` bits in the whole image's terms. It must
  also beat a noise penalty of one bit per token in use, in the samples'
  terms: splitting samples at random lowers their entropy by about that
  much. Without the penalty the tree overfit. Large nodes are judged on at
  most `split_samples` samples.
- `search_predictors`: default judges splits with each node's two cheapest
  predictors, not all four. On the corpus that saved about 10% of the time
  at no size cost. Best judges with all 14.

## Entropy coding

Hybrid integers (split 4, msb 2, lsb 0), the tree's leaves as contexts,
clustered into at most 256 histograms (farthest-first seeds, then nearest
assignment). ANS with 12-bit tables (the decoder's alias mapping, inverted).
Histograms are written with the shift that costs least. Context maps are
written simply or entropy-coded with move-to-front. Prefix codes (Brotli's
format) are implemented and tested but not chosen yet.

Tokens are counted in one pass and written in a second. When every
stream's tokens fit (2^22, packed as 11-bit context and 21-bit value), they
are kept between the passes; otherwise the second pass makes them again.

## Efforts

|                                   | fast     | default                       | best   |
| --------------------------------- | -------- | ----------------------------- | ------ |
| predictors                        | gradient | gradient, weighted, left, top | all 14 |
| weighted-predictor property       | no       | yes                           | yes    |
| reference channels                | 0        | 2                             | 3      |
| samples                           | 2^15     | 2^18 to 2^20, one in 16       | 2^19   |
| thresholds per property           | 16       | 32                            | 64     |
| leaves                            | 256      | 1024                          | 2048   |
| split cost (bits)                 | 64       | 48                            | 40     |
| split judged on                   | 4096     | 16384                         | 16384  |
| predictors a split is judged with | 1        | 2                             | 14     |
| palette colors                    | 256      | 1024                          | 1024   |
| RCT pixels                        | 2^10     | 2^15                          | 2^16   |

Against cjxl, on the 43-file corpus (sizes stage 3, speed stage 4): fast
is 3.1% smaller than e3 at 0.97 and 0.79 of its speed up to and above a
megapixel; default is 1.0% smaller than e7 (0.990 of its total) at 1.08
and 1.27 of its speed; best is 1.7% smaller than e8 (0.983) at 0.78 and
1.77 of its speed. Icons run at 0.58, 0.84, and 0.32 of those efforts'
speed. The results files have the per-class tables.

## Work memory

`workLen(options, w, h)` adds up fixed-size parts (`Sizes` in encode.zig)
for the worst source, 16-bit RGBA. The parts:

- the compressed sections, six bytes per sample, bounded below;
- one group's planes and tokens;
- the token store, 4 bytes per token up to 2^22 tokens;
- the samples and learning tables;
- the histograms and codes.

That comes to about 25 B/px for large images at every effort (50–80 B/px
at a megapixel, where the token store is not yet capped). Default's
samples grow with the image above a megapixel (stage 7): 8 MB more at
1448×1448, 25 MB more from 2048×2048 on, where they reach 2^20. Small
images pay
for tables sized by the image (stage 6):

- leaves: the effort's, the decoder's limit, and one per 64 samples, at
  least 16 (`maxLeaves`); the corpus's 16×16 icons grow 3 to 7, its
  64×64 ones 17 to 57;
- histograms: one per 1024 samples, from 16 to 256 (`maxClusters`); the
  corpus's icons use 2 to 6, kodim03 76, and each costs the
  code's tables 11 KiB;
- samples: four a pixel at most (`sampleRoom`), without the palette's
  room on top, which a palette never needs (its channel is one sample a
  pixel, its entries at most an eighth of the pixels in four);
- tree learning's counts: the effort's thresholds plus one buckets and
  the predictors a split is judged with, not 65 buckets and every
  predictor.

At 16×16 that is 0.5, 0.8, and 3.8 MiB for fast, default, and best (it
was 3.8, 5.6, and 8.1), and at 64×64 2.5, 3.4, and 6.8 MiB (5.4, 8.8, and
11.8). Most of it is never touched; the bench reports peak RSS. A bump
allocator (`encode_mem.zig`) hands it out, and running out returns
`error.WorkTooSmall`, which would be a bug in `Sizes`.

The output bound: a sample costs at most 45 bits. That is a prefix code's
15 bits (an ANS symbol's frequency is at least 1/4096, so 12) plus at most
30 extra bits for a residual, which wraps to 32 bits. Residuals wrap
because the weighted predictor's guesses are not bounded by the samples'
range. The decoder reconstructs modulo 2^32, and so do we.

## Shared with the decoder

The encoder uses the decoder's `Predictor`, `Neighbours` and `neighbours`,
`clampedGradient`, `predictOne`, and `Wp` from `modular.zig`, and `Alias`
and `initAlias` from `entropy.zig` (made `pub` by the JPEG XL orb in
638be00). `Wp.init` takes the decoder's `Arena`, so `encode_modular.zig`
hands it one over a slice of its `Bump`. Switching changed no file on the
corpus at any effort. Stage 5: properties 2 to 14 come from the decoder's
`pixelProps`; again no file changed. The decoder's `walk` was tried in
place of the encoder's `Flat` (over a copy of the tree in the decoder's
`Node`) and is slower here: it tests each child's leafness and loads the
children per step, where `Flat` has them precomputed. Fast lost 9%
above a megapixel and 27% on apple.com, so `Flat` stays.

## Checks

- Unit tests: entropy codes round-trip through the decoder's reader. Images
  in 12 formats × 3 sizes × 3 kinds, plus images of several groups,
  round-trip through our decoder.
- `test/fuzz/jxl_encode.zig`: checkEncoder at each effort and at 320×200,
  so several groups are covered.
- `test/oracle/jxl_encode.zig`: random images, encoded at a random effort,
  decoded by libjxl in RGBA16 (premultiplied when the file is). Only files
  as written count; mutated ones are the decoder's oracle's business.
  Encoding is serial in the harness, so sources are small: up to 24×24,
  and one in 32 a strip of 257 to 320 by up to 24 (two groups), mostly at
  fast. Efforts are weighted toward fast, and best only runs up to 16×16.
  At 20,000 inputs it takes 46–48 s (it took 192 s in oracle-ci with
  sources up to 64×64 and one in 16 up to 320×200).
- jxl-oxide has no oracle. A one-off check decoded 117 of our files with
  the bench arms: every format, each effort, one to many groups. libjxl and
  jxl-oxide agreed on all 117, and our decoder on all but the 12
  premultiplied ones, where the bench op un-premultiplies and libjxl does
  not.

## Next

- Photos: at default, 1–2% larger than cjxl e7 on Kodak (3–4% in stage
  1). Twice the samples (2^19) for every image makes default 1.2% smaller on the corpus,
  0.99× e7's total, for 28% more time; not taken (decision 70).
  Judging splits with all four predictors: 0.4% smaller on photos for 20%
  more time.
- Screenshots: apple.com is 1.9% larger than e7 at default, with samples
  scaled to the image (stage 7). It was 4.3%.
- Learning time: deriving a child's counts from its parent's and its
  sibling's could save half the counting, but a node's predictors and
  tokens in use differ from its parent's, and breadth-first order would
  keep a level's tables. Counting property by property instead of sample
  by sample was 12% slower.
- Prefix codes for small images were tried in stage 4: two 16×16 icons
  gained 0.5–2%, and the trial cost 6–10% of an icon's time.
- LZ77, if it comes back: it needs an exact cost guard (a second write
  pass) and pays only on synthetic images (`lz77.patch` in the stage 1
  results).
- Best's tree-learning counts are 3.1 MiB at any size (14 predictors,
  65 buckets, 28 properties).

# JPEG XL lossless encode

`src/jxl/encode.zig` and `src/jxl/encode_*.zig`: a lossless Modular encoder
written from ISO/IEC 18181-1. The rest of `src/jxl/` is the decoder, owned
by the JPEG XL orb; the encoder keeps private copies of what it needs from
it (below). Measurements: `results/jxl-encode-20261102.md`.

## Status

Stage 1 (this branch): a working encoder at three efforts, decoding bit for
bit in libjxl, jxl-oxide, and our decoder, at about cjxl's sizes for its
speed. LZ77 was written and measured, and is not kept: it saved nothing on
the corpus (results file, "LZ77").

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
  a 768-wide photo saw one row and picked badly (Kodak +20–50%).

## Tree learning

One tree codes every group. It is learned from samples: rows from every
stream, in a band whose offset moves from group to group, up to `samples`
pixels. Learning from a corner of the image, as the first version did, made
the tree fit only that corner.

- Properties: the specification's 16 (including the weighted predictor's
  error, property 15, at default and best), plus four for each of up to
  `refs` earlier channels (|v|, v, |v − pred|, v − pred), the properties
  that let a channel lean on the ones before it.
- Thresholds per property: every distinct value when there are few;
  otherwise half at quantiles of the samples and half spread over the
  distinct values, so that a long tail gets some. They are chosen from a
  sixteenth of the samples, between 1024 and 4096, and samples are bucketed
  with a vector compare.
- Nodes are split breadth first, up to `max_leaves`. A node counts each
  token (hybrid-integer tokens, capped at 64) per property bucket and
  predictor. A scan over the buckets with running entropies finds the split
  that saves the most bits, when each side takes its best predictor. Counts
  are u16. A node clears what it counted, so a small node costs as little as
  it holds.
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
| samples                           | 2^15     | 2^18                          | 2^19   |
| thresholds per property           | 16       | 32                            | 64     |
| leaves                            | 64       | 512                           | 2048   |
| split cost (bits)                 | 64       | 48                            | 40     |
| split judged on                   | 4096     | 16384                         | 16384  |
| predictors a split is judged with | 1        | 2                             | 14     |
| palette colors                    | 256      | 1024                          | 1024   |
| RCT pixels                        | 2^10     | 2^15                          | 2^16   |

Against cjxl, on the 43-file corpus: fast is about e3's size and speed,
default sits between e6 and e7, and best is about e8's size in less time.
The results file has the per-class tables. Recommended default: `default`
(the owner decides).

## Work memory

`workLen(options, w, h)` adds up fixed-size parts (`Sizes` in encode.zig)
for the worst source, 16-bit RGBA. The parts:

- the compressed sections, six bytes per sample, bounded below;
- one group's planes and tokens;
- the token store, 4 bytes per token up to 2^22 tokens;
- the samples and learning tables;
- the histograms and codes.

That comes to about 25 B/px for large images at every effort. Small images
pay for fixed tables: 1.3, 5.6, and 11 MiB at 16×16 for fast, default, and
best, and 3, 8, and 14 MiB at 64×64. Most of it is never touched; the bench
reports peak RSS. A bump allocator (`encode_mem.zig`) hands it out, and
running out returns `error.WorkTooSmall`, which would be a bug in `Sizes`.

The output bound: a sample costs at most 45 bits. That is a prefix code's
15 bits (an ANS symbol's frequency is at least 1/4096, so 12) plus at most
30 extra bits for a residual, which wraps to 32 bits. Residuals wrap
because the weighted predictor's guesses are not bounded by the samples'
range. The decoder reconstructs modulo 2^32, and so do we.

## Copies of decoder code

`encode_modular.zig` repeats the decoder's predictors, properties, and
weighted predictor (private in `modular.zig`), and `encode_entropy.zig`
inverts its alias-table slot assignment (private in `entropy.zig`). Both
must agree with the decoder bit for bit. The unit tests round-trip through
the decoder's `entropy.zig` and the whole decoder. Request to the JPEG XL
orb: make `Predictor`, the property and weighted-predictor computation, and
the alias-table builder `pub`, so the encoder can use them instead.

## Checks

- Unit tests: entropy codes round-trip through the decoder's reader. Images
  in 12 formats × 3 sizes × 3 kinds, plus images of several groups,
  round-trip through our decoder.
- `test/fuzz/jxl_encode.zig`: checkEncoder at each effort and at 320×200,
  so several groups are covered.
- `test/oracle/jxl_encode.zig`: random images, encoded at a random effort,
  decoded by libjxl in RGBA16 (premultiplied when the file is). Only files
  as written count; mutated ones are the decoder's oracle's business.
  Encoding is serial in the harness, so efforts are weighted toward fast,
  and best only runs up to 32×32. About 10 ms an input.
- jxl-oxide has no oracle. A one-off check decoded 117 of our files with
  the bench arms: every format, each effort, one to many groups. libjxl and
  jxl-oxide agreed on all 117, and our decoder on all but the 12
  premultiplied ones, where the bench op un-premultiplies and libjxl does
  not.

## Next

- Photos: 3–4% larger than cjxl e7 at `default`, and Kodak is the largest
  class of loss. A per-cluster hybrid-integer configuration is worth
  0.1–0.25% (one global configuration tried on kodim01 and kodim03), so
  the rest is in prediction and the tree.
- Memory up to a megapixel: the learning samples hold i32 properties (112
  bytes a sample at `best`). Choose thresholds from a subsample first and
  keep u8 bucket indices.
- Choose prefix codes when they cost less, as they may for small images:
  no ANS state per stream, cheaper histograms.
- LZ77, if it comes back: it needs an exact cost guard (a second write
  pass) and pays only on synthetic images (`lz77.patch` in the results).
- Small images: a 64×64 icon takes 5× (fast against e3), 3× (default
  against e7), and 6.5× (best against e8) cjxl's time. The time goes to tree
  learning: a scan per node over property buckets × predictors × tokens.
  Also the RCT search and the fixed tables; size the tables by the image,
  not the worst case.

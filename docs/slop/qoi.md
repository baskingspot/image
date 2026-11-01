# QOI

Notes and decisions for `image.qoi` (src/qoi/). Measurements are in
results/baseline-20261101.md (wave 0) and results/wbmp-qoi-20261101.md
(wave 1).

## Decoder

The specification puts every decoded pixel in the index, runs and index
chunks included, and the decoder is strict where it is silent: the 8-byte
end marker must follow the last pixel, and a run may not pass the last
pixel. test/oracle/qoi.zig lists where qoi.h and Wuffs disagree.

Wave 1 changes, each measured by an interleaved A/B on one core
(results/wbmp-qoi-20261101.md):

- **Whole-image spans.** When the caller's buffer is packed (stride equals
  the row length) and holds RGB or RGBA, the image decodes as one span
  rather than a span per row: no per-row setup, and runs cross rows freely.
  +6% over the corpus, +15–40% on 16×16 and 32×32 icons, nothing slower.
- **Block fills for runs.** A run stores 16 pixels at a time (one 64- or
  48-byte store) while 16 fit before the end of the span; the store may
  write past the run, and the pixels after it overwrite that. The
  run-heavy rows (the QOI logo, transparent pngimg files, plants) are 2–4
  times faster.
- **No branch per chunk kind on images of 64×64 and up.** Wave 0's notes
  blamed branch order for the photo gap to the `qoi` crate; it is
  mispredicts, since the chunk kind on a photo is close to random. Every
  chunk but a run now decodes through a 256-entry table on its first byte
  (bits of the base pixel to keep, bytes to add, whether the second byte
  holds LUMA's red and blue, length) with the base pixel chosen by a mask
  (the index entry for INDEX, else the last pixel) and bytewise SWAR adds.
  Runs keep their branch, which predicts well on photos. With the other
  changes, photos are 8–37% faster and screenshots 5–61% (two photo rows
  within noise).
- **The branchy loop below 64×64.** The table loop lost 7–29% on 16×16 and
  32×32 icons, so images of fewer than 64 × 64 pixels keep a branch per
  kind, tested in wave 0's order (RGB and RGBA first, then a switch on the
  tag; testing the tag first was 20% slower overall and 40% on icons). A
  likely reason, not verified: the benchmark decodes one small file over and
  over, and the branch predictor learns a few hundred chunks' kinds by
  heart, which a real decode of a new icon would not get. The threshold is
  `small` in Decoder.zig; at exactly 64×64 the table loop was 40% faster
  than the branchy one on the corpus's texture and 2–40% slower on its
  icons, and the texture decided it.
- **Hash by one multiply**: the four bytes spread 16 bits apart in a `u64`,
  times a constant holding the weights, sum into bits 48 to 63.
- Tried and dropped: testing the tag before RGB and RGBA (−20%); handling
  runs outside the inner loop (−8% on photos, from the reader's `fill` and
  `toss` on every run); the chunk length by arithmetic instead of a table
  (−9% against the table); a loop that writes 8 copies of every pixel so
  runs up to 8 need no branch (+40–50% on index-and-run screenshots, but
  slower on long runs and 64×64 icons, −5% overall against the shipped
  loop).
- Left: the `qoi` crate is still 1.4–2.7× faster on images where runs are
  20–30% of the chunks at random (game screenshots, the test card, 64×64
  icons), where the one remaining branch, on runs, mispredicts.

## Encoder

`image.qoi.encode` writes the bytes qoi.h writes for the same pixels:
checked on all 44 benchmark inputs (`bench-compare`'s checksums against the
qoih and zune arms) and by `just oracle` (test/oracle/qoi_encode.zig:
qoi.h's decode and encode of every corpus file and fuzzed stream against
ours). The rules that make it identical:

- A pixel enters the index only when it is written as DIFF, LUMA, RGB, or
  RGBA, not during a run and not on an index hit. Starting with
  (0, 0, 0, 255) as the previous pixel, a leading run of it therefore does
  not put it in the index.
- A run ends at 62 or at a different pixel; the last run is flushed before
  the end marker.
- DIFF before LUMA before RGB, and RGBA whenever alpha changes.

The `qoi` crate (the image-rs arm) writes different bytes of the same
length on every input: where qoi.h ends a one-pixel run with a run chunk it
sometimes writes an index chunk. Both decode to the same pixels;
`qoi-encode` is an `own` operation in bench/ops.tsv for that arm.

A source with alpha is stored as four channels and one without as three,
after `image.convert` to straight RGBA or RGB. `EncodeOptions.transfer`
sets the colorspace byte. No work memory: pixels are converted 256 at a time
on the stack when the source is not already RGB or RGBA, and chunks are
written straight into the writer's buffer while it has room for a pixel's
worst case (6 bytes), one pixel at a time through `writeAll` when it does
not, so a fixed writer of exactly the file's size works.

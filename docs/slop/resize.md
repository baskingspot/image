# Resizing

`image.resize` (`src/resize.zig`): put in scope by the owner on 2026-11-05
(plan.md, Scope). Its first user is rockorager/monstar's `src/Font.zig`,
which resizes FreeType glyph bitmaps (gray8 coverage and premultiplied
BGRA) with stb_image_resize 0.97's `stbir_resize_uint8`. Measurements are
in results/resize-20261105.md.

## Definitions

Implemented from the filter definitions, not from stb's source:

- Sample positions: destination pixel `j`'s center is at source position
  `(j + 0.5) · src / dst − 0.5` (pixel centers at half-integers, as stb
  places them).
- Shrinking stretches the kernel by `scale = src / dst`, so its argument is
  in destination pixels; growing evaluates it in source pixels. Weights are
  computed in `f64`, normalized to sum to 1, and stored as `f32`.
- Cubics: Mitchell and Netravali, "Reconstruction Filters in Computer
  Graphics" (SIGGRAPH 1988), the two-parameter family. B-spline is (1, 0),
  Catmull-Rom (0, 1/2), which is Keys's "Cubic Convolution Interpolation
  for Digital Image Processing" (1981) with a = −1/2, and Mitchell
  (1/3, 1/3).
- Lanczos-3: `sinc(x) sinc(x/3)` on |x| < 3.
- Triangle: `1 − |x|`.
- Box: exact area overlap, in integers (`[j·src, (j+1)·src)` against
  `[i·dst, (i+1)·dst)`), so halving is the mean of each 2×2 block at every
  size and no tie depends on floating point.
- Point: the pixel under the center, `floor((2j + 1) · src / (2 · dst))` in
  integers, copied as raw bytes (no unpack, no rounding).
- `default`: per axis, Catmull-Rom when `scale ≤ 1` and Mitchell when it
  shrinks. This is stb_image_resize2's choice, probed on 2.18. stb 0.97
  picks Mitchell when `scale ≥ 1`, so it blurs an axis that keeps its size
  (by up to 30 steps on 8-bit edges); the two agree everywhere else.
- Edges: clamp repeats the edge pixel; reflect is half-sample symmetric
  (`… 1 0 | 0 1 …`); wrap tiles; zero reads 0 and
  keeps the weights past the edge (edges darken, as stb's ZERO does on its
  horizontal pass).

## Pipeline

Separable, at `f32`. RGB is carried as four floats a pixel (the fourth 0),
so it runs RGBA's kernels: `floats_per_pixel` is 1, 2, or 4.

1. `unpack`: a source row to floats in 0 to 1 (floats as stored), sRGB
   decoded per the options (8-bit through a 256-entry table, 16-bit through
   the formula), straight alpha premultiplied. 8-bit rows without sRGB are
   vector conversions (RGB through one 48-to-64-byte shuffle per 16
   pixels); every other combination is a loop specialized at comptime on
   the sample type, channel count, and sRGB.
2. Horizontal (`filterRow`): each destination pixel's weights are padded to
   whole vectors and repeated for every float of a pixel, so that every
   channel count is the same run of vector multiply-adds over contiguous
   floats: 16 lanes, or 8 (4 when a window has at most 4 taps) for one
   float a pixel. A group of pixels (a vector's worth once folded) is
   summed side by side, so the sums do not wait on each other, and folded
   together with a shuffle tree into one vector of the group's pixels, one
   store. Up to 4 vectors a pixel the loop is unrolled. The tap count is
   the widest window's, not the closed-form bound `workLen` allocates.
   The source line is padded per the edge mode (clamp and zero by fill),
   and zeros follow as far as the last pixel's padded taps read.
3. Vertical (`filterColumn`): per destination row, its taps' source rows
   after the edge mode, with a run of the same row merged and zero weights
   dropped. Four vectors of output are summed side by side. A row with one
   tap of weight 1 is used as it is.
4. Order: horizontal first, so the ring holds destination-width rows.
   One float a pixel that shrinks vertically goes vertical first
   (`v_first`): there the horizontal filter fills its vectors worst, and
   running it on destination rows instead of source rows took gray8
   256→64 from 820 to 1309 MP/s in development. For four floats it was no
   faster and on thumbnails slower (4000×3000 RGB to 256: 315 against
   489 MP/s) with 6.5× the work memory (4.5 MB against 0.7), so it stays
   horizontal first.
5. The ring holds `min(taps, rows)` rows: windows move down with the
   destination row, so the rows still read form a sliding range. Wrap past
   an edge and reflection more than once (an image shorter than the reach)
   read rows from both ends, so they keep the whole height.
6. `packRow`: unpremultiply, sRGB encode (8-bit by binary search over the
   255 rounding thresholds in linear light, so it rounds exactly), round to
   nearest and clamp; vector paths for 8-bit samples, RGB (one shuffle per
   16 pixels), and straight 8-bit alpha. If the destination's channel
   layout matches the source's, this writes the destination format
   directly; otherwise it writes the source layout with the destination's
   premultiplication, and `convert.Converter` takes it from there.

Weights: computed in `f64` (`Axis.weights`, the cubics' coefficients over
6 folded at comptime so no division is left per tap), normalized, stored as
`f32`. A ratio `shift / period` in lowest terms repeats its windows and
weights every `period` destination pixels, `shift` source pixels on, so
only the first period is computed and the rest copied (a quarter downscale
computes one pixel, a doubling two); a vertical row is copied only when
its taps a period before were inside the image and still are. A square
resize takes the vertical weights from the horizontal table. On glyph
sizes the weights were a third of the call before this.

Sums go into partial sums of 16 vector steps before the total: one f32
accumulator over 1016 taps of 16-bit samples drifted a step past every
source value (fuzz finding, box 1016→1 on bgra16_premul). Up to 16 steps
the result is bit-identical to a plain sum.

Non-finite float samples: a padded tap multiplies a neighbor by a weight of
0, so an infinite or NaN source sample can turn neighbors NaN. Finite
inputs are unaffected.

Straight alpha: a pixel whose written alpha quantizes to 0 is transparent
black, since a color divided by an alpha that rounds away is noise. This is
our decision; stb_image_resize2 fills such pixels from neighbors unless
`non_pm_alpha_speed_over_quality` is set.

## Memory

`workLen` is O(1), closed form: the horizontal starts and weights
(`dst_width` rounded to a group, times the tap bound rounded to a vector,
times `floats_per_pixel`), the padded line, the vertical rows and weights
(`dst_height × v_taps`), the ring (`ring_rows` rows of destination width,
or source width with `v_first`, times `floats_per_pixel` floats), one
output row, and a pack row when a conversion follows. Every
product and sum is overflow-checked; null on overflow. Point keeps raw
source rows in the ring instead of floats.

`Resizer` uses the same work memory: `push` refuses a row while a
destination row is ready (it could overwrite a row that row reads), and
`take` hands rows out as soon as their source rows are in. `resize` is
`Resizer` driven over the buffer.

## Oracle

test/oracle/resize.zig against stb_image_resize2 2.18, and the defaults
against stb_image_resize 0.97 (flake: `stb-image-resize-097`, pinned).
stb2 problems found on the way, each confirmed against an exact `f64` sum:

- Its vertical pass misweights some rows on Catmull-Rom and Mitchell
  downscales: 85 of 20,000 one-column resizes differed by more than 1e-4,
  up to 0.033 (411→31 row 14: stb 0.8410, exact 0.8177). Its horizontal
  pass is right on the same data, so the oracle runs stb's horizontal pass
  on both axes with a transpose between, through a float intermediate.
- Its vertical ZERO edge on downscales weighs rows past the top edge unlike
  its horizontal pass (flat 53→5: 1.0543 against 1.0130).
- Its REFLECT mirrors about the edge pixel on the left and about the edge
  on the right; its WRAP goes round once. The oracle pads the source itself
  for every edge mode but clamp, by whole periods of the ratio, and crops
  the padded result.
- An input subrectangle (`stbir_set_input_subrect`) on a padded 4-channel
  row read past its input: the last pixel's last two samples came back 255
  and results varied between runs. With box it asserts.
- The RGBA → RGBA_PM layout conversion does not premultiply, and negative
  filtered alpha is left undivided.

Tolerances (test/oracle/resize.zig has the reasoning): 1 step at 8 bits; 8
steps at 16 bits and in floats, from stb computing positions and kernels in
`f32` (6.5e-5 of a pixel near 1000, against our 3e-7); 16 for straight
alpha at 16 bits and in floats, compared on alpha from half to opaque. The
0.97 oracle compares within 1, leaving out requests where an axis keeps its
size (the default-filter difference above).

## Orient

`resize.orient(dst, src, orientation)` applies an `image.Orientation` into
another buffer of the same format: the first four orientations copy rows
(mirrored per pixel for `top_right` and `bottom_right`, in reverse row
order for the bottom ones), the last four transpose with source rows and
columns counted from the far end as the orientation says, in 32-pixel
tiles. Same format only (`FormatMismatch`); a conversion is `image.convert`
before or after. The unit test checks all eight on a 3×2 image against
EXIF's definitions (row 0 goes where the first word says, column 0 where
the second says), and the fuzz target checks the corner the first pixel
lands in and that the inverse orientation restores the source.

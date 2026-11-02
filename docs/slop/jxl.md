# JPEG XL decode: notes and decisions

`src/jxl/` is a streaming JPEG XL decoder written from ISO/IEC 18181-1 (the
codestream) and 18181-2 (the container). libjxl 0.12.0 is the oracle
(`test/oracle/jxl.c`); jxl-oxide and libjxl are the speed and memory bars.
This file records the stages, the work-memory bound, and what the decoder
does where the specification leaves room.

## Stages

1. **Container, headers, entropy decoding** (landed with stage 2). Boxes,
   the image and frame headers, the TOC with its permutation, ANS and prefix
   codes with context clustering, LZ77, hybrid integers, and the ICC
   profile's encoding.
2. **Modular** (this branch). Lossless and lossy Modular frames end to end:
   meta-adaptive trees, every predictor including the weighted one, RCT,
   palette (delta palettes, implicit cubes), squeeze, the global and group
   streams, LF and pass groups, extra channels, animation, blending,
   reference frames, and cropped layers larger than the canvas.
3. **VarDCT and the restoration filters.** XYB and YCbCr, LF frames, the
   transforms, dequantization, chroma from luma, Gaborish, EPF, upsampling,
   patches, splines, and noise, then progressive passes.
4. **JPEG reconstruction** from `jbrd` (plan.md decision 5).

Until a stage lands, files that need it fail with `error.Unsupported`, and
the oracle leaves them out (`test/oracle/jxl.zig`).

## Shape

- `container.zig`: `Source` hands the codestream to the bit reader, bare or
  in `jxlc` or `jxlp` boxes, and sends `Exif` and `xml ` boxes (raw, or
  Brotli in `brob` with `Blob.encoding = .brotli`) to the blob sink as it
  passes them. `jbrd` is noted and skipped.
- `BitReader.zig`: a 64-bit LSB-first bit buffer over `Source`, with the
  specification's U32, U64, F16, and enum field codings.
- `headers.zig`: SizeHeader, ImageMetadata (bit depth, extra channels,
  color encoding, tone mapping, animation, preview), the custom upsampling
  weights (`upsample_weights.zig`), and FrameHeader with its passes, crop,
  blending, and restoration filter fields.
- `entropy.zig`: `Code.read` reads the clustered distributions, either
  prefix codes (lookup tables with a second level) or ANS (alias tables),
  and the LZ77 parameters; `Reader` keeps the ANS state and the LZ77 window.
  A code whose cluster has one symbol is read without touching the stream
  (`Reader.singleValue`).
- `modular.zig`: channels and transforms, the tree (16-byte nodes, the
  right child beside the left), and the channel decoder. Each channel picks
  a path: a single leaf with a fixed predictor, or the general loop that
  evaluates the tree with the properties the tree reads. `plan()` resolves
  each channel's static properties (channel and stream index) once instead
  of per pixel. The weighted predictor runs in wrapping 64-bit arithmetic,
  so hostile residuals cannot trap.
- `frame.zig`: the TOC, then each section in file order: LfGlobal (the
  global tree and the GlobalModular channels), LF groups, and pass groups,
  each group copied into the frame's channels.
- `icc.zig`: the encoded ICC profile's prediction, written straight into
  work memory and sent to the blob sink as kind `.icc`.
- `Decoder.zig`: frames converted to floats at their bit depth, composited
  onto the canvas with the frame's blend mode, saved to reference slots, and
  written to the caller's buffer through `image.convert`.
- `Arena.zig`: a bump allocator over the caller's work memory that aligns
  by address and tracks its peak, for the measurements below.

## Work memory

`Config.work_len` is a bound computed from the headers before any pixel is
read; a file that would need more fails with `TooComplex` rather than
writing past it. Its terms, in `Decoder.workBound`:

- The canvas and four reference slots, as float planes, when frames may
  need them. A single last frame without a crop in a still image needs
  neither, which `decodeConfig` learns by reading the first frame header
  when there is no ICC profile or preview before it.
- One Modular frame of up to twice the canvas's pixels, three times over
  for undoing squeezes, plus a delta palette's indices and the largest
  palette.
- A group's channels with their transforms, at the first frame's group
  size when it is known.
- Two trees and three live entropy codes, each code's tables within a 1 MiB
  budget plus its LZ77 window.
- Reference-property rows and the weighted predictor's rows.

The bound is conservative: on the conformance files the arena's peak is
7–39% of it (alpha_nonpremultiplied, 1024×1024 RGBA at 12 bits: 16.8 MB used
of a 220 MB bound). Memory the decoder never touches costs a caller nothing
when it comes from `mmap`, but a caller that fills it, as Zig's safe
allocators do, pays for all of it. Tightening it is stage-3 work: the
squeeze term can drop to one extra channel by undoing squeezes row by row,
and the frame term can use the first frame's size when it is known.

## Decisions

- **Coalesced frames.** `decodeFrame` returns displayed frames as libjxl
  does by default: zero-duration frames are blended into the canvas and the
  next displayed frame is returned composited. `Frame.blend` is `src_over`
  when the frame went through the canvas and `src` when it replaced it.
- **Blending in floats.** Frames are held as f32 at the image's bit depth,
  as the specification blends, and written out through a 16-bit or f32
  pivot that rounds as libjxl does: `f32(v) * f32(1 / max)`, then ×65535
  rounded to nearest even. Native formats: f32 for float samples or more
  than 16 bits, 8-bit when every channel's maximum divides 255 (1, 2, 4,
  or 8 bits), otherwise 16-bit.
- **Frame size.** A frame (a cropped layer) may have up to twice the
  canvas's pixels; more is `TooComplex`. The specification allows any size;
  the cap keeps the bound finite, and the conformance files stay within it
  (sunset_logo's layers are the largest).
- **The ICC profile** is decoded in the first `decodeFrame`, since
  `decodeConfig` has no work memory, and reported to the blob sink at
  offset 0 with its decoded length. `Config.metadata.icc` names it only
  after that call. Profiles are not applied: pixels stay in the encoded
  color space, as libjxl returns them without a CMS.
- **Spot colors** are extra channels and are not rendered into the color
  channels, as libjxl does with `JxlDecoderSetRenderSpotcolors(false)`; the
  shared pixel formats have nowhere to put extra channels yet.
- **Orientation** is reported, not applied, as for every other format.
- **Preview frames** are skipped.
- **Errors.** `BadBox`, `BadEntropy`, `BadImage`, `BadIcc`, and
  `TooComplex` beside the shared ones; `Unsupported` for what a later stage
  adds.

## Testing

- Oracle: libjxl decodes the first displayed frame in RGBA16 (straight or
  premultiplied as the image stores alpha) and float RGBA; ours must match
  bit for bit. 16-bit answers count for integer images and float answers for
  float ones (`test/oracle/jxl.zig` has why). libjxl's 8-bit output is
  dithered, so it is not compared.
- Fuzz: `test/fuzz/jxl.zig` writes valid one-group Modular files (gray or
  RGB, optional alpha, 8 to 12 bits, a random predictor, an optional RCT)
  with a small bit writer, and random bodies an eighth of the time.
- Conformance: the `jxl-conformance` suite. Stage 2 decodes 12 of its 43
  files bit for bit against libjxl, every frame (all 36 of
  animation_newtons_cradle, checked by hand with a libjxl program that
  hashes each frame): alpha_nonpremultiplied, alpha_triangles,
  animation_newtons_cradle, blendmodes, blendmodes_5, cmyk_layers,
  delta_palette, lossless_pfm, lz77_flower, mul_no_extra_channels, spot,
  and sunset_logo. The rest need stage 3: VarDCT or XYB (most), patches
  (patches_lossless), and Gaborish and EPF on a Modular frame
  (grayscale_public_university).

## Measurements

One thread, ReleaseSafe, against `djxl --num_threads=0`: about 2× slower on
the 1024×1024 lossless files (0.24 s against 0.13 s for
alpha_nonpremultiplied). The bench arms (libjxl in C, jxl-oxide in Rust)
and the write-up in `results/` come with stage 3.

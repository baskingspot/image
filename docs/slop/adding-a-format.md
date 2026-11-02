# Adding a format

How a format joins the package, so that formats can land in parallel without
touching each other's files. A format owns its own files outright and adds at
most one line to each shared registry. Nothing else in the repository should
need to change; if it does, ask the owner of that file in your report rather
than editing it. QOI (`src/qoi/`, `test/fuzz/qoi.zig`, `test/oracle/qoi.*`,
`bench/*/qoi*`) is the worked example of every piece.

## The files a format owns

| File                                                   | What it holds                                                                                                                                                                        |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/<fmt>/root.zig`                                   | The namespace `image.<fmt>`: `Decoder`, and once it encodes, `encode`, `workLen`, `EncodeOptions`, `EncodeError` (src/encode.zig).                                                   |
| `src/<fmt>/*.zig`                                      | Everything else the format needs. Tests live beside the code.                                                                                                                        |
| `test/fuzz/<fmt>.zig`                                  | The decoder's fuzz target: `name`, `corpus`, `extensions`, `check`, `generate`, `seeds`, and a test calling `harness.zigFuzz`.                                                       |
| `test/fuzz/<fmt>_encode.zig`                           | The encoder's target, the same shape, with `check` calling `harness.checkEncoder`.                                                                                                   |
| `test/oracle/<fmt>.c`                                  | The C side of each oracle: an `<fmt>_ops` table of `struct op` (test/oracle/oracle.h). Wuffs formats call `wuffs_decode` (test/oracle/wuffs.c).                                      |
| `test/oracle/<fmt>.zig`                                | The Zig side: the oracles' op names, the pixel formats to compare, `comparable` and `adapt`, and the documented reasons the references disagree; `<fmt>_encode.zig` for the encoder. |
| `corpus/gen/<fmt>.sh`                                  | Generated conformance cases, when the public suites leave cases out; output in `corpus/vendor/generated/<fmt>/` with checksums in `.../<fmt>.sha256`.                                |
| `corpus/vendor/<suite>/`, `<suite>.sha256`             | A small suite vendored unmodified, with its checksums beside it.                                                                                                                     |
| `bench/zig/<fmt>.zig`                                  | The Zig arm's operations: `ops`, pairs of an operation name and a function from input bytes to output bytes.                                                                         |
| `bench/c/<arm>-<fmt>.c`                                | Each C arm's operations, registered with `BENCH_OP`; a new arm (libpng, libspng, libjpeg-turbo, ...) is new files plus its line in `bench/c/arms.tsv`.                               |
| `bench/rust/src/<crate>_<fmt>.rs`, `bench/go/<fmt>.go` | The Rust and Go arms' operations, where those libraries read the format.                                                                                                             |
| `bench/corpus/<fmt>.sh`, `<fmt>.sha256`                | The benchmark inputs: the shared sources (`$src/<category>/<name>.png`) converted to the format into `$dst`, every name ending in `-WxH`, and their checksums.                       |

## The registries: one line each

| Registry                  | The line                                                                                                          |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `src/root.zig`            | `pub const <fmt> = @import("<fmt>/root.zig");` `image.Decoder` and `image.Decoder.supports` pick it up from here. |
| `test/fuzz/targets.zig`   | `pub const <fmt> = @import("<fmt>.zig");`, and one for `<fmt>_encode`. `just fuzz` and `fuzz-zig` find it here.   |
| `test/oracle/formats.zig` | `pub const <fmt> = @import("<fmt>.zig");`                                                                         |
| `test/oracle/formats.def` | `FORMAT(<fmt>) // link: <pkg-config packages or -l flags, or ->`.                                                 |
| `bench/zig/root.zig`      | `pub const <fmt> = @import("<fmt>.zig");`                                                                         |
| `bench/ops.tsv`           | One line per operation (`png-decode`, `png-encode`, ...): its row name, input directory, output bytes per pixel.  |
| `bench/c/arms.tsv`        | One line per new C arm.                                                                                           |
| `bench/rust/src/lib.rs`   | A `mod` line and an entry in `tables`; `Cargo.toml` gains the crate under the arm's feature.                      |
| `corpus/sources.tsv`      | One line per fetched suite. Every phase-1 suite is already there.                                                 |
| `THIRD_PARTY.md`          | A row per new vendored or fetched source. Every phase-1 source is already there.                                  |
| `CHANGELOG.md`            | A bullet under Unreleased, Added.                                                                                 |

`src/detect.zig` already detects every phase-1 format, and `build.zig`, the
justfile, and CI iterate the registries, so a format adds nothing to them. The
flake already has every phase-1 oracle and comparison library.

## The decoder contract

`image.<fmt>.Decoder` is a struct with:

- `pub const Options`: `image.DecodeOptions`, or a struct with the same
  fields (every field defaulted) followed by the format's own.
  `image.Decoder.init` copies the shared fields across.
- `pub const Error = image.DecodeError || error{...}`: the shared causes plus
  the format's own, each with a doc comment.
- `pub fn init(reader: *std.Io.Reader, options: Options) Decoder`: reads
  nothing. The reader's buffer holds at least `image.min_buffer_len` bytes, so
  peeks and takes of up to 64 bytes are safe; read larger structures through
  your own state.
- `pub fn decodeConfig(d: *Decoder) Error!image.Config`: reads the header.
  Check `options.limits.checkSize` (and `checkFrames`, `checkWork`) before any
  other work. Report `native`, the format that holds the pixels without loss
  and is cheapest to write, and `work_len`. Calling it again returns the same
  config.
- `pub fn decodeFrame(d: *Decoder, dst: image.PixelBuffer, work: []u8) Error!?image.Frame`:
  writes the next frame into `dst`, in any `PixelFormat`, using `work[0..work_len]`;
  null once there are no more frames. Call `dst.check()` and compare its size
  with the canvas before writing. Write native rows straight into `dst` when
  the formats match, and otherwise decode a span into a small stack buffer and
  convert it with `image.convert.Converter`, as `src/qoi/Decoder.zig` does.
- `pub fn decodeFrameConfig(d: *Decoder) Error!?image.Frame` (plan.md
  decision 11): reads up to the next frame's pixels and returns the `Frame`
  the next `decodeFrame` returns, without drawing, or null where it returns
  null; calling it again returns the same frame. A caller saves the region a
  `previous` disposal restores from it, as with Wuffs's
  `decode_frame_config`. Every format whose `Config.frame_count` can be
  other than 0 or 1, or is null, has it (`src/gif/` and `src/ico/` do). A
  format with at most one frame may leave it out: `image.Decoder` then
  reports its frame as the whole canvas, index 0, with `Config.is_opaque`,
  so its `decodeFrame` must return exactly that; it is `Unsupported` there
  for a format with more frames and no `decodeFrameConfig`.
- After any error, every later call returns the same error.

Rules every decoder keeps (AGENTS.md has the reasons):

- No allocation and no `@setRuntimeSafety(false)`. Input is read forward,
  skipping gaps with `discard`. A format that stores offsets (ICO's
  directory, TIFF's IFDs) moves back only through `options.seeker`, the
  caller's `image.Seeker` (plan.md decision 8): call `seek(offset)` with an
  offset from the input's first byte for data behind the reader, track the
  position yourself afterwards, and fail with a format error (ICO's
  `EntryBehind`) when the seeker is null. Never seek for data ahead, so a
  file laid out in order decodes from any stream. A format with its own
  `Options` adds a `seeker` field only if it moves back, and
  `image.Decoder` passes on the shared fields a format's `Options` has; `src/ico/Decoder.zig`'s `goTo` is the example, and its
  fuzz target checks that a seeker changes nothing but what was behind.
  `harness.checkDecoder` checks a decoder whose own `Options` has a
  `seeker` twice, forward only and with a seeker over each of its readers,
  so a fuzz target need not wrap one.
- A float destination is written from the native pixels by
  `image.convert`, unless the decoder sets `float_direct` to true (a
  `pub const`; plan.md decision 24). Then, when its native format has no
  float samples, it writes float formats from its own floats;
  `checkDecoder` skips comparing those with the converted native pixels,
  and the format's fuzz target checks them itself.
- Metadata is reported in `Config.metadata` and `Frame`, and ICC, EXIF, and
  XMP bytes go to `options.blob_sink` as the decoder passes them (a blob
  whose length is known only at its end passes `len` null until its last
  piece; plan.md decision 13, and `image.Blob` for one split into pieces).
  Frame
  durations are in flicks (`image.flicks_per_second`). Metadata that follows
  the frames (TGA's footer, a PNG's chunks after IDAT) is read by the
  `decodeFrame` call that returns null, and a format that has some declares
  `pub fn applyTrailer(d: *const Decoder, config: *image.Config) void`,
  which sets only the `Config` fields it found there; `image.Decoder`'s
  `finalConfig` calls it on the config `decodeConfig` returns.
- Strict by default, as Wuffs is: a truncated stream is `Truncated`, a bad
  checksum or a structure the specification forbids is an error. When the
  references are lax about something, say so in `test/oracle/<fmt>.zig`.

## The encoder contract

src/encode.zig has it in full: `encode(writer, src, options, work)` takes
pixels in any `PixelFormat`, converts them with `image.convert` to what the
file stores, and writes the whole file; `workLen(options, width, height)`
says how much work memory to pass. `harness.checkEncoder` checks that every
pixel format encodes, that work memory one byte short is refused with
`WorkTooSmall`, that a writer draining a few bytes at a time sees the same
bytes, and that our decoder reads back the source converted to the file's
native format. A quantizing or lossy encoder calls
`harness.checkEncoderWith(F, .{ .expect = ... }, input, choice)` instead,
whose `expect` turns that converted source into what the file must decode to
(test/fuzz/wbmp_encode.zig thresholds it). It also gets the round trip,
`harness.RoundTrip`: the source, what our decoder read, and the file, so a
bounded encoder accepts a decode by copying `trip.got` into `want`
(test/fuzz/gif_encode.zig); `max_width` and `max_height`
make larger images than the default 48 by 48. `harness.Drip` is the
few-bytes-at-a-time writer, for a target's own checks.

## The harnesses

- **Fuzz.** `check(input, choice)` calls `harness.checkDecoder(image.<fmt>.Decoder, input, choice)`
  and adds format-specific properties if there are any; it checks
  `decodeFrameConfig` against every `decodeFrame` where a decoder has one
  (`harness.announced`, which a format's own decode loops can call too;
  so can `harness.Trickle`, the reader that hands over a few bytes at a time).
  `generate` makes
  structurally valid files most of the time and slightly broken ones
  otherwise; it is where most bugs are found, so make it reach every chunk,
  marker, or box type. `corpus` names the seed directories (`corpus/fetched`,
  `corpus/vendor`, and `bench/corpus-gen/<fmt>`; files of 64 MiB or more
  are left out), `extensions` the file endings to take. `seeds` are plain
  files; `harness.zigFuzz` encodes them for Zig's fuzzer. `just fuzz 600 ""
<fmt>` runs one target, and `just fuzz 60/target` gives every target 60
  seconds. Avoid `threadlocal` in a fuzz target: a target runs on one
  thread, so a plain global serves, and in Zig 0.16 Debug on the
  x86 backend a `threadlocal` made png's zig-fuzz test fail with
  `LaxDiffers`.
- **Oracle.** Each oracle op decodes the input into the requested pixel format
  or rejects it. Ours must agree with every oracle that the others agree with;
  where the references disagree, `test/oracle/<fmt>.zig` documents why, and
  `comparable` or `adapt` keep one library's quirk from hiding another's.
  An encoder's oracle is `test/oracle/<fmt>_encode.zig` with `encode` (ours)
  and a `Decoder` that reads its sources from the inputs, against C ops
  declared `{"name", .encode = fn}`, which encode raw pixels. The protocol's
  pixel formats (`enum pixel_format` in oracle.h) are `image.PixelFormat`'s,
  `cmyk8` and `cmyk16` included, so an op can answer CMYK natively; the files must
  be the same bytes (test/oracle/qoi_encode.zig). Batches run on every
  core, so an oracle module, both its Zig and its C side, must be
  thread-safe: keep per-input state in locals or `threadlocal`, never in a
  shared global or static (a cached decode or a saved canvas). compare.zig
  gives our decoder its work memory per input and frees it, so a module need
  not manage work memory itself. Fuzzed inputs mutate corpus files of at most
  2^18 pixels, and one time in 16 any corpus file, so large files in
  `corpus` cost the corpus pass, not every mutation. Corpus files are read
  from disk as batches need them, and `adapt` is called once per input and
  op, so an `adapt` that copies its input costs one copy per op, not one
  per pixel format; return the input itself when it needs no change.
  Answers agree when their lengths and XXH64s match. A lossy format whose
  specification leaves arithmetic open can declare a tolerance in its
  module instead: `pub const tolerance: u16` for every input, or per input
  a `pub fn toleranceFor` that takes the input, a `[]const u8`, and
  returns a `?Oracle.Tolerance` (test/oracle/Oracle.zig), null for an exact comparison. For an input with
  a tolerance the oracles return pixels, and two answers agree when every
  sample differs by at most `peak` (`tolerance` is a `peak` alone) and, if
  `rms` is set, the root mean square of the differences over all samples
  is at most `rms`. Both are in the compared format's units, for floats
  16-bit steps (a unit is 1/65535); a fraction of full scale is that
  fraction times 255 or 65535. `toleranceFor` must take any input,
  including an empty or broken one, and stay cheap: it runs as each batch
  is taken, one worker at a time. Only inputs with a tolerance cost their
  pixels' memory. The run prints how many agreed only within it. `just oracle
100000` runs every format, and `just oracle 20000 1 <fmt>` one; the gate is
  0 mismatches.
- **MagickWand.** An oracle that reads through ImageMagick calls
  `magick_decode` (test/oracle/magick.c, declared in oracle.h) with the
  format to read as and whether warnings reject.
- **Bench.** Every arm's output for a `same` operation must checksum
  identically; mark an operation `own` in `bench/ops.tsv` when the arms may
  round or composite differently. An encode operation's input is raw pixels
  with no header, and the harness gives its size: `input.pixels(in, format)`
  in `bench/zig/input.zig`, `bench_width` and `bench_height` in C,
  `crate::input_size()` in Rust, and `inWidth` and `inHeight` in Go
  (bench/README.md, "Arm contract"). A row whose inputs are tiny can add a
  rotating twin (`rotate=<op>`) over many distinct files, as
  `png-decode-icons` does. `just bench-compare 10 png-decode` runs one
  operation; write the result up in `docs/slop/results/`.

## Checklist before pushing

`just ci` passes; `just fuzz 600` finds nothing; `just oracle` reports 0
mismatches; `just bench-compare` against the format's bar library is written
up with megapixels per second and peak RSS; the CHANGELOG bullet names the new
namespace.

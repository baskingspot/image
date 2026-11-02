# JPEG XL JPEG reconstruction: design notes

`src/jxl/jbrd.zig` parses the `jbrd` box and writes the JPEG it describes;
`src/jxl/JpegReconstructor.zig` finds the boxes, sizes the work memory, and
drives the writer with the codestream's quantized coefficients (owner
decision 28). This file records where the syntax comes from, why the API
needs a seeker, what is verified, and what is still open.

## Status

- Done: the box (every field, with libjxl's constraints), the Brotli
  payload, the JPEG writer (markers, DQT, DHT, SOF, DRI, APP, COM,
  inter-marker bytes, tail, and every scan type: sequential, progressive DC
  first and refinement, AC first with EOB runs, AC refinement), the box
  walk and work plan, the fuzz target, and the corpus.
- Waiting: the coefficients. `run` returns `error.Unsupported` until the
  JPEG XL orb's coefficient pass in vardct.zig lands (`wave4-jxl-coeffs`).
  Then: the oracle against `djxl`, the bench, and a CHANGELOG bullet.

## Where the syntax comes from

ISO/IEC 18181-2's `jbrd` clause is not public, and the iTeh previews stop
before it. The 2019 committee draft (arXiv 1908.03565, Annex M) gives the
data model and the reconstruction semantics (M.5: padding bits, extra
zero runs, reset points, how each segment is laid out), but its stream
syntax is the older Brunsli one that the standard replaced. The field
order, field encodings (U32 distributions), and constraints of the final
syntax are therefore read from libjxl 0.12's `JPEGData::VisitFields` as a
syntax table, with no code taken from it. The owner should know that this
one table is not from the published text.

Semantics the draft leaves loose, read from what libjxl's JPEG parser
records (the encoder side, which defines the fields' meaning) and confirmed
on the corpus:

- `extra_zero_runs` counts the ZRL symbols written after a block's last
  nonzero coefficient before its EOB; a ZRL left at the end of a band with
  fewer than 16 zeros is invalid.
- `reset_points` are blocks where the original ended one EOB run and began
  another straight away, instead of extending it.
- Refinement scans have no zero runs.
- Padding bits are taken in order for every byte-aligned end of an
  entropy-coded segment (before RST and at each scan's end); without the
  list, every padding bit is 1.
- In SOF, a component's Tq is its table's `index` field (every corpus file
  agrees, though none puts tables out of slot order).
- A DQT table that no component uses repeats the previous table's values:
  the codestream keeps one table per component, so an unused table cannot
  be recovered. No corpus file has one; the oracle will show whether djxl
  agrees.

## Design

- **A seeker is required** (`error.NeedsSeeker`). The box is read twice:
  once to count the parsed size and the payload length, then into work
  memory. The payload length is only known after the bundle is parsed, and
  a valid box can declare up to about 24,000 times its own size (16-bit
  APP and COM sizes, tail lengths up to 4.26 MB), so a bound from the box
  length alone would refuse legitimate files under `max_work`. The `Exif`
  and `xml ` boxes, which hold APP markers' contents, can come before or
  after `jbrd`, and the codestream after both.
- **The work layout**, each part 16-byte aligned: the raw box, the parsed
  bundle (counted with each allocation's worst-case alignment, so the
  count holds at any base address), the Brotli payload, the Exif and XMP
  contents, the ICC profile, the AC refinement scratch (258 KiB, only when
  a scan refines AC coefficients), and the coefficients, whose bytes take
  the compressed `brob` contents first.
- **Brotli in one shot.** `compress`'s streaming Reader needs a 4 to 16 MiB
  window; the one-shot `decompress` into the exactly sized payload needs
  none. It ignores bytes after the stream's end, which libjxl rejects, so
  `decompressExact` checks that the stream without its last byte fails,
  at the cost of decoding twice. A consumed-bytes result from `compress`
  would remove that (requested).
- **Errors.** `BadJbrd` for any broken constraint, `Unsupported` for more
  than one Exif or XMP marker or a second `jbrd` box (as libjxl), `NoJbrd`
  for a file with no box, and the codestream decoder's errors for its
  headers.

## Verification so far

A scratch driver fed the writer libjpeg-turbo's coefficients for each JPEG
and compared the output with the original: all 67 files of
`corpus/vendor/generated/jxl_jbrd/` rebuild byte-identical. They cover
baseline and progressive coding, every sampling, restarts in rows and
MCUs, scan scripts down to the last bit of successive approximation,
16-bit DQT, ICC profiles split over several markers, Exif and XMP in raw
and Brotli boxes, unknown APP markers, comments, fill bytes, and trailing
data. cjxl refuses the JPEG corpus's arithmetic, 12-bit, lossless, and
CMYK files, so those have no transcode.

## Corpus

`corpus/gen/jxl_jbrd.sh` transcodes (`cjxl --lossless_jpeg=1`, one
thread) every fetched JPEG up to 128 KiB that cjxl takes, and cjpeg JPEGs
for the layouts the suites leave out. The largest file (384 KB) is the
ICC split case: djxl fails on a padded profile, so it carries
libjpeg-turbo's real 557 KB `test1.icc`.

## Fuzzing

`test/fuzz/jxl_jbrd.zig` checks the whole reconstructor through a fixed
and a trickling seekable reader, and the box alone: counting against real
parses, trickled against fixed, and the writer through a fixed and a
dripping writer with coefficients made from the choice. Its generator
builds plausible boxes (complete Huffman tables, scan scripts, restarts,
padding bits, zero runs, metadata markers, an uncompressed Brotli stream)
in a container, usually with a generated codestream.

## Requests for files this work does not own

- `src/decode.zig`: a `Metadata` flag for a `jbrd` box, which the JPEG XL
  decoder's container walk already notices (`saw_jbrd`).
- `src/jxl/vardct.zig` (the JPEG XL orb): per JPEG component, the
  quantized coefficients as i16 in natural order, with chroma-from-luma
  undone and blocks padded to whole MCUs; the raw quantization tables; the
  `jpeg_upsampling` factors as JPEG h and v; and a work bound for the
  coefficient pass.
- `test/fuzz/harness.zig`: export `Trickle`, which jxl_jbrd.zig copies.
- `compress`: a consumed-bytes result or a trailing-data check from the
  one-shot Brotli decoder.

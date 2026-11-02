# JPEG XL JPEG reconstruction: design notes

`src/jxl/jbrd.zig` parses the `jbrd` box and writes the JPEG it describes;
`src/jxl/JpegReconstructor.zig` finds the boxes, sizes the work memory, and
drives the writer with the codestream's quantized coefficients (owner
decision 28). This file records where the syntax comes from, why the API
needs a seeker, what is verified, and what is still open.

## Status

Complete for what cjxl transcodes: the box (every field, with libjxl's
constraints), the Brotli payload, the JPEG writer (markers, DQT, DHT, SOF,
DRI, APP, COM, inter-marker bytes, tail, and every scan type: sequential,
progressive DC first and refinement, AC first with EOB runs, AC
refinement), and the coefficients and tables from
`Decoder.decodeJpeg` (the JPEG XL orb's coefficient pass). A codestream
that cannot hold a JPEG is `error.NotJpeg`, which includes RGB-stored
JPEGs for now. Measurements: `results/jxl-jbrd-20261102.md`.

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
  nonzero coefficient before its EOB. A ZRL left at the end of a band with
  fewer than 16 zeros is `BadJbrd` here. libjxl writes it anyway, and so
  any count of them: one field would expand to 2³² symbols, so we refuse
  rather than match it. No oracle input has reached this split.
- `reset_points` are blocks where the original ended one EOB run and began
  another straight away, instead of extending it.
- Refinement scans have no zero runs.
- Padding bits are taken in order for every byte-aligned end of an
  entropy-coded segment (before RST and at each scan's end); without the
  list, every padding bit is 1.
- In SOF, a component's Tq is its table's `index` field (every corpus file
  agrees, though none puts tables out of slot order).
- A DQT table holds the last component's values that uses it (libjxl
  does the same), and a table no component uses repeats the previous
  table's values: the codestream keeps one table per component, so an
  unused table cannot be recovered.

What a box may say beyond any JPEG cjxl writes, matched to libjxl's
reconstruction, which the oracle found by mutating transcodes:

- The scans of a sequential frame code the whole block whatever band and
  approximation they store, and the stored bytes are written as they are.
  A progressive scan of band 0 to 63 at full precision is coded as a
  sequential one. A first or refining scan whose band starts at 0 and runs
  on codes the DC and then the rest of the band, without EOB runs; a band
  that ends before it starts codes nothing. A scan needs its DC table when
  its band starts at 0 and its AC table when the band is more than the DC,
  whatever its approximation. An EOB run is written with the AC table of
  the block that began it.
- SOF markers 0xc9 and 0xca (arithmetic coding) are written as stored, with
  Huffman-coded scans, and do not change whether the scans are
  progressive. An SOI marker in the list is `BadJbrd`. A scan before any
  SOF is written. Scans restart only after the DRI marker has been
  written.
- APP markers are written as stored, whatever type the marker list gives,
  and an AC symbol may have a magnitude up to 15 if the code has it.

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
  a scan refines AC coefficients), the coefficients (`Jpeg.maxCoefs` i16
  plus a byte, so they align at any base address), whose bytes take the
  compressed `brob` contents first, and the codestream decoder's
  `jpegWorkLen`, whose bytes hold the Brotli decoder's state
  (`brotli.decode.Buffer`, 2.7 MB, mostly never touched) first: every
  Brotli stream is read before the coefficient pass. The box's components
  must lie on the codestream's blocks (`BadJbrd` otherwise), and an ICC
  profile the box's markers carry must be exactly the codestream's.
- **Brotli in one shot.** `compress`'s streaming Reader needs a 4 to 16 MiB
  window; the one-shot decode into the exactly sized payload needs none.
  `decompressCounted` (compress 6953f33) reports the stream's length, so
  bytes after the stream, which libjxl rejects, are refused in the same
  pass. It holds the format's 256 trees per category (brotli 1.2.0 writes
  more than 64 at q4 to q9 on 1 MiB inputs), with its state in the work
  memory rather than on the stack.
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

## Open

- libjxl also refuses a colour factor other than 84
  (`ColorCorrelation::IsJPEGCompatible`), which `decodeJpeg` does not
  check; no fuzzed input has hit it, at seed 1 with 100,000 inputs on the
  full corpus and on CI's and at seeds 2 to 10 with 20,000 on CI's.

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

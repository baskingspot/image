# Decision 1: the streaming model, 2026-11-01

**Verdict: decoders pull from `std.Io.Reader`.** A Wuffs-style resumable
push decoder is no faster per call on icons (within ±1.3% on 16×16 to 64×64)
and 3–4% slower on images over a megapixel, needs twice the code for QOI and
far more for nested formats, and does not compose with `std.Io` or
`compress`. plan.md's API section records the decision.

## What was measured

`streaming-20261101/ab.zig` decodes every file of the benchmark corpus
(`bench/corpus-gen/qoi/`, 44 files from 16×16 icons to a 50-megapixel photo
mosaic) four ways, each a whole decode per call (decoder setup, header,
pixels, end marker) into a caller-owned RGBA or RGB buffer:

| Arm          | Decoder                                                    | Input                                                                                                      |
| ------------ | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `pull_fixed` | the shipped `image.qoi.Decoder`                            | `std.Io.Reader.fixed` over the whole file                                                                  |
| `pull_4k`    | the shipped decoder                                        | a reader whose vtable hands over at most 4 KiB a call into a 4 KiB buffer, as a file or socket reader does |
| `push_whole` | a resumable push decoder written for this A/B, Wuffs style | the whole file in one call                                                                                 |
| `push_4k`    | the push decoder                                           | 4 KiB a call                                                                                               |

The push decoder decodes the same chunks with the same row loop and the same
run handling as the shipped one, so what differs is the I/O model: a reader's
buffer, `fill`, and `toss` against a slice handed in, with a carry buffer for
a chunk split across calls and resumable header and end-marker state. `ab
verify` checked that all four arms write identical pixels on every corpus
file, that the push decoder gives the same pixels fed 1 to 16 bytes at a
time, and that it rejects truncations; 64 files passed (the benchmark corpus,
`corpus/vendor/generated/qoi`, and qoi_test_images, edgecase.qoi included).

`run.sh` builds ab.zig with `-OReleaseFast` for the host CPU and times the
arms on one core (`taskset -c 3`): 10 rounds after a sizing round, each row's
four arms back to back in an order rotating by row and round, about 20 ms a
sample. benchstat compares the throughput in megapixels per second.

CPU: Intel Xeon Processor @ 2.60GHz (`cpu.txt`; 4 vCPUs, AVX-512, a shared
cloud host, so single samples vary by ±10–30%), Zig 0.16.0, Linux 6.1.

## Results

Each arm's throughput against `pull_fixed`, the geometric mean over rows of
each row's median paired ratio (above 1 is faster than `pull_fixed`):

| Arm          | icons ≤ 64×64 (13 rows) | to 1 MP (23 rows) | over 1 MP (8 rows) | all (44) |
| ------------ | ----------------------- | ----------------- | ------------------ | -------- |
| `pull_4k`    | 0.989                   | 0.985             | 0.985              | 0.986    |
| `push_whole` | 1.013                   | 0.971             | 0.956              | 0.980    |
| `push_4k`    | 1.007                   | 0.965             | 0.960              | 0.977    |

benchstat's geomeans over all rows: `pull_fixed` 268.0 MP/s, `pull_4k`
265.1 (−1.07%), `push_whole` 263.8 (−1.59%), `push_4k` 262.3 (−2.11%).
Per row, the push decoder wins on the 16×16 icons (+12% to +19%,
p < 0.05 on three of four) and on one 320×240 screenshot, and loses 8–12% on
the 64×64 and 512×512 icons and most photos; `benchstat.txt` has every row.

On a 16×16 icon a decode takes about 0.9 µs, of which the I/O model's share
is within the noise; the cost there is per-call setup common to both, which
is now a known target for the QOI decoder (see baseline-20261101.md).

Memory: the pull decoder is 80 bytes plus a 40-byte `Io.Reader` and the
caller's reader buffer (none for an in-memory file, 64 bytes minimum,
`image.min_buffer_len`); the 256-byte index lives on the stack during
`decodeFrame`. The push decoder is 304 bytes, since its index, run, position,
and carry must survive between calls. Peak RSS is the same for every arm:
the input and pixel buffers.

## Why pull

- **Speed**: equal on icons, ahead on large images, and the 4 KiB-chunked
  reader costs 1.5%, so streaming from a file or socket is nearly free.
- **Composition**: a `std.Io.Reader` is what `std.Io` files and sockets
  give, and what `compress`'s decompressors take and give, so PNG's IDAT
  inflate, TIFF's strips, and JPEG XL's Brotli boxes chain without glue. A
  push decoder would need every one of those to be resumable too.
- **Code**: the push decoder's resumption (carry buffer, split header and end
  marker, re-entry mid-row) is as long as the decoding itself, for the
  simplest format there is. For formats with nested structures (PNG chunks
  over zlib over filters; JPEG's markers and entropy segments) every level
  needs it, and every level is a place for a resumption bug that only some
  chunk boundary triggers.
- **Asynchrony**: in Zig 0.16 a reader that would block suspends through the
  `std.Io` implementation (threaded or evented), so pulling does not tie a
  thread to a slow socket. A caller whose bytes arrive by callback can feed
  them through an `Io.Reader` over its own buffer.

What pull costs: a decoder cannot return "need more input" to a caller with
no `std.Io`, and the reader's buffer must be at least
`image.min_buffer_len` (64) bytes so decoders can peek whole small
structures. Both are stated in the API.

## Raw output

- `streaming-20261101/ab-<arm>.txt`: every sample, Go benchmark format.
- `streaming-20261101/benchstat.txt`: benchstat over the four arms.
- `streaming-20261101/cpu.txt`: `lscpu` of the machine.
- `streaming-20261101/ab.zig` and `run.sh`: the program and how it ran
  (`ROUNDS=10 MS=20 docs/slop/results/streaming-20261101/run.sh` from the
  repository root after `just bench-corpus`).

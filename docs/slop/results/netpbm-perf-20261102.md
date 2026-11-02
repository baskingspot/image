# Netpbm decode: plain samples in 64-byte blocks and buffered headers, 2026-11-02

After `netpbm-20261101.md`, plain (ASCII) PPM decoded at 0.90–0.96× Rust's
`image`, and 16×16 raw PGM and PPM at 0.79–0.92× `image` and `zune-ppm`.

- Plain samples. `readPlain` found each sample's digits a byte or 8 bytes
  at a time, so where a sample starts waited on where the one before
  ended: a dependency chain through every sample. `plainBlock` loads 64
  bytes as a vector and builds two masks, the digits and the whitespace.
  A run of digits starts where a digit follows a non-digit and ends where
  one precedes one, so every sample's first and last byte comes from the
  masks at once; the loop takes the runs in order (`@ctz` of each mask,
  then clears the lowest bit) and parses each through the existing
  8-byte `digitValue`. A run counts only when the byte after it is in the
  block and before the first byte that is neither digit nor whitespace,
  so it is followed by whitespace. A comment, a sample of more than 5
  digits, or a run the block splits returns to the existing path, which
  takes one sample and then the block scan resumes. The test "plain samples
  read in blocks" decodes 400 random plain files (every whitespace
  character, comments, leading zeros, maxvals 9 to 65535, and a stray bad
  byte in one file in five) through a fixed reader, which takes the block
  path, and through a 3-byte trickle reader, which never does, and
  requires the same pixels or the same error; with the trailing-whitespace
  condition removed, it fails.
- Headers. A 16×16 raw file spends most of its decode in its header. The
  signature took two `take` calls and the end of the header a `peek` and
  a `take`, and the width, height, and maxval went through `dimension` and
  `maxvalue`, all returning small error unions, which LLVM builds and
  reads back through the stack (a store-forwarding stall each, as
  `netpbm-20261101.md` found for the header's other bytes). The signature
  now reads from the buffer after one `fill(2)`, the end-of-header byte
  is checked in the buffer that `number` left non-empty, and the range
  checks are inline, in the same order, so every error stays the same
  (the tests of truncated and bad headers pass unchanged).

`zig build test` passes (67 tests). `just oracle 100000` and `just fuzz`
cover netpbm (see the report's gates).

## Method

`ab.sh` from `convert-tails-20261102/`: every netpbm decode operation (raw
PPM to RGB8 and RGBA8, PGM, 16-bit PPM, PAM, PBM, and plain PPM) over the
corpus of `netpbm-20261101.md`, arms interleaved, 10 rounds pinned to core
3 with `taskset`, 50 ms a sample, with benchstat and peak RSS. `image` is
this change, `before` is the build before it (the conversion change of
`convert-tails-20261102.md` on 8e7e4c8), then Wuffs, Rust's `image`, and
`zune-ppm`. Every arm's checksums match on every row they share.

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0 ReleaseFast for this
CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`. An oracle
run and an inflate benchmark ran on other cores.

## Results

Geometric means by size class (`ab/summary.txt`; ratios are this change's
throughput over the arm's):

| rows        | class | image MP/s | vs before | vs Wuffs | vs image | vs zune |
| ----------- | ----- | ---------- | --------- | -------- | -------- | ------- |
| PPM         | icons | 9334       | 1.32      | 3.99     | 1.57     | 1.36    |
| PPM         | ≤ 1MP | 7273       | 1.00      | 1.12     | 2.12     | 1.48    |
| PPM         | large | 3824       | 1.00      | 1.14     | 2.56     | 1.89    |
| PPM to RGBA | icons | 4700       | 1.18      | 2.78     | 3.46     | -       |
| PGM         | icons | 11416      | 1.38      | 4.35     | 1.42     | 1.26    |
| PGM         | ≤ 1MP | 36434      | 1.02      | 1.67     | 2.15     | 1.60    |
| PGM         | large | 14598      | 1.00      | 1.13     | 2.12     | 1.87    |
| 16-bit PPM  | icons | 3602       | 1.15      | -        | 1.44     | 81.9    |
| plain PPM   | icons | 82.1       | 1.74      | -        | 1.57     | -       |
| plain PPM   | ≤ 1MP | 90.7       | 1.79      | -        | 1.61     | -       |
| plain PPM   | large | 91.2       | 1.75      | -        | 1.67     | -       |
| all (298)   |       | 2818       | 1.14      | 1.73     | 2.55     | 3.63    |

Plain PPM goes from 0.90–0.96× `image` (`summary-before.txt`) to
1.57–1.67×. The 16×16 files (`ab/rows.txt`): PGM from 122 ns to 87 ns a
decode (1.39–1.42× before; 1.25–1.27× `image` and 1.14–1.17× `zune-ppm`,
from 0.79–0.92×), PPM from 133 ns to 91 ns (1.41–1.46×; 1.33–1.38×
`image`, 1.16–1.25× `zune-ppm`). The other operations' rows larger than
icons are unchanged (most `~` in benchstat, no row slower beyond noise).

Peak RSS is unchanged, the same as `before` on every operation
(`ab/rss.txt`): the decoder takes no work memory, and the block scan reads
the reader's buffer in place.

## Raw output

`netpbm-perf-20261102/ab/`: `config.txt`, `checksums.txt`, `rss.txt`,
`benchstat.txt`, `summary.txt` (this change against every arm),
`summary-before.txt` (the build before against the others), `rows.txt`,
and each arm's benchstat input (`<arm>.txt`) and raw lines (`raw-*.txt`).

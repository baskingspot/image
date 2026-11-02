# QOI encode: packed rows as one span, 2026-11-02

A full `just bench-compare 5` over the rows the performance pass owns
(convert, `qoi-decode`, `qoi-encode`) on main eabc1ac put QOI encode on
icons at 0.88× Rust's `qoi` crate (0.83–0.89 per row), the only encode
class below 1. The encoder ran its chunk loop once per row, and each call
sets up the writer's room, loads and stores the state (previous pixel,
run), and leaves its loop on a row's last pixel: 16 times for a 16×16 icon.
The decoder already treats packed rows as one span
(`qoi-perf-20261102.md`).

The change: when the source is in the encoder's own format (`rgba8` or
`rgb8`) and its rows are packed (`stride` equal to a row's bytes), the
whole image is one call to `State.pixels`. Strided and converted sources
are unchanged. The output is the same bytes: every row's checksum matches
main, and a test encodes the same rows packed and a pixel apart and
compares the files.

## Method

`docs/slop/results/qoi-icons-20261102/ab.sh`: `just bench-compare`'s
method with arms given as binaries, checksums, peak RSS, then 8
interleaved rounds where each row's arms run back to back in an order that
rotates, pinned to core 3 with `taskset`, 50 ms a sample, benchstat and
`bench/summary.awk`. Arms: `e1` (this change), `before` (main eabc1ac),
`image-rs` (the `qoi` crate, which writes its own bytes: it codes a run of
one as an INDEX chunk where qoi.h writes a run, so its checksums differ by
design).

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0 ReleaseFast for this
CPU, Rust `target-cpu=native`.

## Results

Geometric means by size class (`summary.txt`; main against the crate in
`summary-before.txt`):

| rows   | image MP/s | vs main | vs `qoi` crate |
| ------ | ---------: | ------: | -------------- |
| icons  |      379.5 |    1.15 | 0.88 → 1.01    |
| ≤ 1 MP |      269.2 |    1.02 | 1.01 → 1.02    |
| > 1 MP |      210.1 |    1.01 | 1.02 → 1.03    |
| all 44 |      284.8 |    1.05 | 0.97 → 1.02    |

Per row (`rows.txt`): the 16×16 icons 1.17–1.22× main, the 32×32 icons
1.11–1.18×, the 64×64 icons 1.05–1.15×; against the crate the icons are now
0.97–1.03 and the 64×64 button texture 1.20. One row is below main,
kodim02 at 0.99 (interval [0.73, 1.00], a noisy row; the code it runs is
the same apart from one call instead of 512). Peak RSS is unchanged
(`rss.txt`, 386.1 MiB, the harness's buffers).

## Raw output

`qoi-encode-20261102/`: `config.txt`, `checksums.txt`, `rss.txt`,
`benchstat.txt`, `summary.txt`, `summary-before.txt`, `rows.txt`, and
each arm's samples and checksums.

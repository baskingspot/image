# QOI decode: the chunk loop bounded by one count, 2026-11-02

`qoi-encode-20261102.md` found 1.14× on QOI encode at ≤ 1 MP by having the
encoder's loop check one count where it checked two bounds. The decoder's
chunk loop checked two as well, every chunk: pixels left (`i < n`) and five
bytes buffered (`buf.len - p >= 5`). After the one-loop change the rows
still below Rust's `qoi` crate were the index- and run-heavy screenshots
(3dbrick2 0.88×, 3dcursedlabyrinth 0.85×) and the 64×64 button texture
(0.87×), where chunks are short and the loop overhead is a larger share.

The change: every chunk takes at most 5 bytes and gives at least one
pixel, so `min(buffered / 5, pixels left)` chunks surely fit; the loop runs
that many checking only the count, and the outer loop refills and counts
again. A run gives up to 62 pixels, so after one the count is cut to the
pixels left. No bound is dropped: the count is the smaller of the two that
were checked before.

## Method

`qoi-icons-20261102/ab.sh`: `just bench-compare`'s method with arms given
as binaries, checksums, peak RSS, then 10 interleaved rounds where each
row's arms run back to back in an order that rotates, pinned to core 3
with `taskset`, 50 ms a sample, benchstat and `bench/summary.awk`. Arms:
`vd` (this change), `before` (main eabc1ac's decoder), `image-rs` (the
`qoi` crate), and Wuffs. Every checksum matches on every row.

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0 ReleaseFast for this
CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`.

## Results

Geometric means by size class (`summary.txt`):

| rows           | image MP/s | vs main | vs `qoi` crate | vs Wuffs |
| -------------- | ---------: | ------: | -------------: | -------: |
| rotating icons |      369.5 |    1.00 |           1.43 |     2.16 |
| icons          |      463.7 |    1.03 |           1.01 |     1.74 |
| ≤ 1 MP         |      544.8 |    1.03 |           1.22 |     1.94 |
| > 1 MP         |      340.7 |    1.02 |           1.20 |     1.68 |
| BGRA, icons    |      381.4 |    1.02 |              - |     1.42 |
| BGRA, ≤ 1 MP   |      470.6 |    1.03 |              - |     1.66 |
| BGRA, > 1 MP   |      313.9 |    1.01 |              - |     1.54 |
| all 91 rows    |      440.1 |    1.03 |           1.16 |     1.71 |

Per row (`rows.txt`): 3dbrick2 1.07× main (crate 0.87), the button
texture 1.04× (0.90), 3dcursedlabyrinth 1.02× (0.88), qoi_logo to BGRA
1.16×, pkf_water1 1.10×. Six rows are below main, at 0.980–0.988:
apple_com to BGRA, rotating 32×32, academy_awards to RGBA and BGRA,
cnn_com, and the button texture to BGRA. Peak RSS is unchanged
(`rss.txt`).

The screenshots stay behind the crate: the loop's bounds were a few
percent of their time, not the gap.

## Raw output

`qoi-decode-bound-20261102/`: `config.txt`, `checksums.txt`, `rss.txt`,
`benchstat.txt`, `summary.txt`, `summary-before.txt`, `rows.txt`, and
each arm's samples and checksums.

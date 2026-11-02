# QOI decode: the index and run carry as locals (negative), 2026-11-02

After `qoi-decode-bound-20261102.md`, the screenshots made mostly of INDEX
chunks and runs were still behind Rust's `qoi` crate (3dbrick2 0.87×,
3dcursedlabyrinth 0.88×). The decoder's `span` reads and writes the 64-entry
index and the run carried to the next span through its `*Stream`, and it
stores pixels through `out`, a `[]u8`, which as far as the compiler knows
may alias those fields; the crate's `&mut` slices tell its compiler they do
not. The experiment (`qoi-decode-locals-20261102/variant-locals.diff`):
copy `s.index` and `s.run` into locals at the start of `span`, use them in
the loop, and write them back with `defer`.

## Method

`qoi-icons-20261102/ab.sh`: `just bench-compare`'s method with arms given
as binaries, checksums, peak RSS, then 10 interleaved rounds where each
row's arms run back to back in an order that rotates, pinned to core 3
with `taskset`, 50 ms a sample, benchstat and `bench/summary.awk`, on all
91 QOI decode rows. Arms: `ve` (the variant), `vd` (main d7b5f8a's
decoder), the `qoi` crate (`image-rs`), and Wuffs. Every checksum matches.

CPU: Intel Xeon Processor @ 2.60GHz (3.3 GHz under load), 4 vCPUs,
AVX-512, a shared cloud host; Linux 6.1, Zig 0.16.0 ReleaseFast for this
CPU, C arms `cc -O3 -march=native`, Rust `target-cpu=native`.

## Results

Geometric means by size class, the variant against main (`summary.txt`):

| rows           | variant MP/s | vs main |
| -------------- | -----------: | ------: |
| rotating icons |        350.9 |    0.95 |
| icons          |        462.5 |    1.00 |
| ≤ 1 MP         |        555.5 |    1.02 |
| > 1 MP         |        344.4 |    1.01 |
| BGRA, icons    |        356.2 |    0.93 |
| BGRA, ≤ 1 MP   |        466.5 |    0.99 |
| BGRA, > 1 MP   |        308.8 |    0.98 |
| all 91 rows    |        435.9 |    0.99 |

It helps the rows it was aimed at (`rows.txt`): 3dcursedlabyrinth 1.09×
(1.06× to BGRA), 3dbrick2 1.05× (1.02×). It costs the small ones:
rotating 16×16 icons 0.87×, BGRA icons down to 0.86× (16×16). A BGRA
decode converts through a 256-pixel buffer and calls `span` once per 256
pixels, and every call now copies the 256-byte index in and out; a
16×16 icon is one call that copies it for 256 pixels. 27 of 91 rows are
slower, and peak RSS is unchanged.

Not taken. A version that copies only once per image would need the
index to live outside `span` for the whole decode, and the gain it would
keep is on two screenshot rows, while QOI decode is already 1.69–1.71×
Wuffs overall.

## Raw output

`qoi-decode-locals-20261102/`: `variant-locals.diff`, `config.txt`,
`checksums.txt`, `rss.txt`, `benchstat.txt`, `summary.txt`,
`summary-before.txt`, `rows.txt`, and each arm's samples and checksums.

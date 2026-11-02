# PNG with the HDR chunks: does reading them slow small decodes?, 2026-11-02

Branch `wave6-hdr-meta` (plan.md decision 51) teaches `image.png.Decoder`
cICP, mDCV, and cLLI: three more cases in the switch over ancillary chunk
types, a check for a cICP once the header is read, and 64 more bytes of
`Metadata` (192 to 256; `Config` 232 to 296, `png.Decoder` 1536 to 1600,
`jpeg.Decoder` 4296 to 4408 with the gain map state), all on the stack, so
peak RSS does not move. None of the benchmark's files has an HDR chunk, so
this measures the cost of the larger structs and the dispatch on files that
do not use them, where per-call setup on an icon would show it.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, an Amp orb), Linux 6.1,
Zig 0.16.0, `zig build bench` (ReleaseFast for this CPU). Two `bench-image`
builds: `base` from origin/main d8dab0a and `hdr` from this branch's tree.
`png-decode-icons` (64 rotating icons at 16, 32, and 64 pixels) and
`png-decode` (the 52 files of `bench/corpus-gen/png/`), whole file into
RGBA8, 20 interleaved rounds pinned to core 3 (`taskset -c 3`), the order
alternating each round, `BENCHTIME_MS=40` (`run.sh`). An A/A control ran the
`base` binary under two names for 10 rounds.

## Results

Each row's ratio is the median over rounds of the paired ratio, `hdr` time
over `base` time within a round (`paired.py`); classes are geometric means
of rows.

| rows (count)                  | `hdr` / `base` time | A/A control |
| ----------------------------- | ------------------: | ----------: |
| rotating icons (3)            |              1.0021 |      1.0044 |
| `png-decode` icons ≤ 64² (17) |              0.9981 |      1.0014 |
| to 1 MP (27)                  |              0.9946 |      1.0031 |
| over 1 MP (8)                 |              0.9966 |      0.9964 |
| all (55)                      |              0.9964 |      1.0016 |

The rotating rows, the honest icon numbers (results/icon-rotation-20261102.md):

| row            | `hdr` / `base` (range) | A/A (range)            | `hdr` MP/s | `base` MP/s |
| -------------- | ---------------------- | ---------------------- | ---------: | ----------: |
| rotate64-16x16 | 1.0055 (0.9889–1.0532) | 1.0076 (0.9250–1.0342) |      34.83 |       35.09 |
| rotate64-32x32 | 1.0051 (0.9860–1.0395) | 1.0054 (0.9864–1.0327) |      72.04 |       72.33 |
| rotate64-64x64 | 0.9957 (0.9529–1.0330) | 1.0002 (0.9632–1.0517) |      116.1 |       115.6 |

benchstat (`ab/benchstat.txt`) gives −0.33% time geomean over all rows, and
+0.76% (p = 0.014) on the 16×16 rotating row; the A/A control gives +0.21%
geomean and +0.63% on that row (p = 0.19 at 10 rounds). The A/B ratios are
the size of the A/A's: identical binaries differ as much as these two. So
reading the HDR chunks costs nothing measurable on icons or larger files.

Raw output: `png-hdr-chunks-20261102/ab/` (`base.txt`, `hdr.txt`,
`benchstat.txt`, `paired.txt`) and `png-hdr-chunks-20261102/aa/`.

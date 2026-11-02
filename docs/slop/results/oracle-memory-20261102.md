# The gates on an 8 GB orb: where the oracle's memory went, and the cap

2026-11-02, Intel Xeon @ 2.60GHz (4 threads, an Amp orb with 7956 MiB, whose
workload cgroup `amp-workload.slice` has `memory.max` 6 GiB), main at
b08d00f. The full corpus: every source in `corpus/sources.tsv` fetched
(`just corpus`, 202 MiB) and `bench/corpus-gen` generated (6.3 GiB). Each
command ran alone as a supervised service, sampled every 0.25 s for its
cgroup's anonymous memory (`memory.stat` `anon`, the part the OOM killer
cannot reclaim; page cache from reading the corpus is left out) and the three
largest processes. Raw output is in `oracle-memory-20261102/`, and
`sampler.sh` there is the sampler. "Peak" below is anon memory outside Zig and
C compiles unless it says otherwise.

## Before

| Run (main b08d00f)           | Result                                                    | Peak     | Wall                 |
| ---------------------------- | --------------------------------------------------------- | -------- | -------------------- |
| `just oracle 100000`         | OOM-killed at netpbm, after tga                           | 5611 MiB | 704 s until the kill |
| `just ci`                    | OOM-killed at netpbm in oracle-ci's `just oracle 20000 1` | 5141 MiB | 375 s until the kill |
| `just oracle 20000 1 netpbm` | passed, 9958 agree                                        | 5251 MiB | 23.4 s in compare    |

At the kill, `oracle-compare` held 4281 MiB and each of four `image-oracle`
children about 400 MiB. Netpbm alone reaches the peak, so it is per format,
not accumulation across formats; over the run the anon curve swings between
1.5 and 5.2 GiB batch by batch (`netpbm-main.txt`).

## Where it came from

Per worker batch, three things multiplied the 64 MiB of inputs a batch may
hold:

1. **Requests repeated their input.** A request whose input is the previous
   request's sends no copy, but compare.zig built requests format by format
   and op by op, and called `adapt` per format. Netpbm's `adapt` copies a PFM
   for `netpbm-magick`, so the order wuffs (input), stb (input), magick (copy)
   alternated pointers and every PFM crossed the pipe twice per pixel format:
   18 times, with 9 formats. The batch cap counts inputs once.
2. **Doubling buffers on both sides.** Oracle.zig built the whole batch in an
   `ArrayList` before writing it, and oracle.c read stdin into a buffer it
   doubled with `realloc`: up to twice the batch on each side, and three times
   during a copy.
3. **The corpus in memory.** `loadCorpus` read every corpus file for the
   format into memory, and compare.zig never freed it: tiff's 351 MiB, png's
   143, jpeg's 129 and qoi's 93 MiB stayed resident through the formats after
   them. This is smaller than 1 and 2, but it is held for the whole run.

ImageMagick is not the cause: magick.c already sets its limits (one thread, 1
GiB memory and map, 16 Mpx area), and the children stay at 130–570 MiB, most
of it the batch.

## Changes

- Oracle.zig streams the batch to the oracle through a 64 KiB buffer, after
  its u64 length (counted first with a discarding writer), and oracle.c
  allocates that length once. Neither side keeps a doubling copy.
- A decoder's requests go op by op, each op's `adapt` called once per input,
  so an input crosses once per op that rewrites it, not once per pixel
  format. Responses are indexed to match. Encoders keep their order, since
  their sources differ per format anyway.
- compare.zig lists the corpus (`harness.listCorpus`, the same paths in the
  same order as `loadCorpus`) and reads each file into the batch that
  compares or mutates it. Only the mutation bases, files of at most 2^18
  pixels, stay in memory, and they are freed after their format.

Seeds give the same inputs as before: the paths come in the same sorted order
and the PRNG draws are unchanged. Every agree count and split is identical to
main's for the formats main finished (bmp, ico, gif, png, jpeg, qoi,
qoi_encode, tiff, tga at 100 000 and at 20 000), and the wbmp mismatch below
has the same id on main.

## After

| Run (branch)                  | Result                                   | Peak     | Wall              |
| ----------------------------- | ---------------------------------------- | -------- | ----------------- |
| `just oracle 100000`          | completes; 1 wbmp mismatch, also on main | 1850 MiB | 979 s             |
| `just ci` (cold `.zig-cache`) | exit 0, 0 mismatches                     | 4401 MiB | 442 s             |
| `just oracle 20000 1 netpbm`  | 9958 agree                               | 1140 MiB | 15.8 s in compare |

`just ci`'s peak is now its test phase: the ReleaseSafe test binaries and
the ReleaseFast unit tests compile at once, three Zig processes of about 1.5
GiB each (4401 MiB; main's run peaked the same, 4400 MiB). Its oracle-ci
phase peaks at 1618 MiB, against main's 5141 MiB and a kill.

Netpbm 20 000, change by change (anon peak in the compare phase):

| Code                               | Peak     |
| ---------------------------------- | -------- |
| main                               | 5251 MiB |
| + requests op by op                | 1351 MiB |
| + batch streamed behind its length | 1122 MiB |
| + corpus read from disk            | 1140 MiB |

Netpbm's corpus is 5.6 MiB, so the last change shows nowhere here; it is the
corpus-heavy formats' few hundred MiB, held for the run on main.

Per-format time at 100 000 (compare's own timer), where both finished:

| Format     |    main |  branch |
| ---------- | ------: | ------: |
| bmp        |  12.3 s |  12.0 s |
| ico        |  18.6 s |  16.4 s |
| gif        |  50.4 s |  42.6 s |
| png        |  45.8 s |  39.4 s |
| jpeg       |  95.4 s |  86.6 s |
| qoi        | 130.8 s |  89.6 s |
| qoi_encode |  97.0 s |  80.7 s |
| tiff       | 167.4 s | 153.6 s |
| tga        |  20.8 s |  16.0 s |
| total      | 638.5 s | 536.9 s |

Less copying makes it 16% faster. The branch adds netpbm 71.7 s, wbmp 64.4 s
and webp 303.0 s. Webp is now the longest format at 100 000, which is a time
cost, not a memory one (918 MiB peak).

## After, rebased on JPEG XL

The same gates on the branch rebased onto main 102c9ba, which adds JPEG XL
(its oracle, its `bench/corpus-gen/jxl`, and its decoder in every test
binary) and the WBMP size fix (`final-oracle.txt`, `final-ci.txt`):

| Run                  | Result                           | Peak                              | Wall   |
| -------------------- | -------------------------------- | --------------------------------- | ------ |
| `just oracle 100000` | exit 0, 13 formats, 0 mismatches | 1909 MiB                          | 1450 s |
| `just ci`            | exit 0, 13 formats, 0 mismatches | 4654 MiB (tests), oracle 1528 MiB | 483 s  |

JPEG XL takes 358 s and webp 302 s of the 100 000 run; JPEG XL's oracle
phase peaks under the run's maximum. The three test compiles now take about
1.6 GiB each.

## Not changed

- Workers stay one per core, up to 8. At 4 workers the oracle peaks at 1.6–1.9
  GiB, so an 8-core 8 GB machine would be near 3.5 GiB, still under the cap.
  A memory budget for batches is not needed at these numbers.
- `just test`'s concurrent ReleaseFast build. Making it run after ReleaseSafe
  would bring the test phase to two compilers (about 3.2 GiB) for about 60 s
  more wall time. At 4.65 GiB it fits, and the JPEG XL orb's kills were all
  in the oracle, none in a compile. It is the next thing to cut if the
  formats still to land grow the compiles by another 1.3 GiB.
- The fuzz driver (`just fuzz`) still loads each target's corpus into memory.
  It is not part of `just ci`.

## Found on the way

`just oracle 100000` has one wbmp mismatch on main and on the branch,
`mismatch-243578`: a 71-byte file whose height is a multi-byte integer with
seven zero continuation bytes (`80 80 80 80 80 80 80 0c`, height 12). Wuffs and
ImageMagick agree, and ours differs.

# The oracle pass: where its time went, and the cut

2026-11-02, Intel Xeon @ 2.60GHz (4 threads, an Amp orb), main at 747f7e9,
`zig-out/bin/oracle-compare 20000 1` (`just oracle-ci`'s run) under GNU time.
Raw output is in `oracle-pass-20261102/`.

## Profile

Timers in compare.zig's batches and per oracle op in oracle.c (removed after),
summed over the four workers (`profile.txt`):

| Format | oracle process |  its ops' decoding | ours and stats | Mpx decoded per oracle |
| ------ | -------------: | -----------------: | -------------: | ---------------------: |
| wbmp   |          210 s | 165 s (magick 124) |           37 s |                   5260 |
| qoi    |          155 s |               76 s |           61 s |           5381 (qoi.h) |
| jpeg   |          162 s |              123 s |          138 s |           5052 (turbo) |

Two costs, both from volume:

1. **Pixels through the pipe.** Each oracle wrote every decoded image back
   (about 14 GB for wbmp and 20 GB for qoi.h), and compare.zig read and kept
   them, only to ask whether two were equal: the oracle process's time beyond
   its decoding (45 s on wbmp, 79 s on qoi).
2. **Mutations of large corpus files.** Half the fuzzed inputs mutate a
   random corpus file, and the corpora include bench/corpus-gen's photos and
   screenshots. A mutation of a 1.4-megapixel file lands almost always in its
   pixel data, so the decoder still reads every row: 20 000 inputs averaged a
   quarter megapixel per format per decider.

## Changes

- The oracle answers with the pixels' length and XXH64 (seed 0; Zig's
  `std.hash.XxHash64`) instead of the pixels; ours are hashed the same way and
  freed at once. Two answers agree exactly when they did (a 64-bit collision
  aside): every agree count and split was identical in the four formats run
  with only this change (jpeg, qoi, qoi_encode, wbmp), and a wrong hash on either side would have made every
  accepted answer a mismatch.
- Our decoder's work memory comes from the allocator per input and is freed,
  not from the batch arena (which kept every input's worst-case work bound
  until the batch ended, and its capacity across batches).
- Fuzzed inputs mutate a corpus file of at most 2^18 pixels (or one our
  decoder's header rejects); one time in 16, any corpus file. Every corpus
  file is still compared whole.
- Batches are capped at 64 MiB of inputs rather than 256 MiB of answers.

## Results

`before.txt`, `after.txt`: 0 mismatches in every format both times.

| Format     |      before |       after |
| ---------- | ----------: | ----------: |
| bmp        |       2.1 s |       1.7 s |
| ico        |       5.0 s |       4.8 s |
| gif        |      33.6 s |      16.8 s |
| png        |      17.1 s |       8.2 s |
| jpeg       |      79.2 s |      21.6 s |
| qoi        |      59.8 s |      23.6 s |
| qoi_encode |      24.0 s |      16.9 s |
| tga        |       2.9 s |       2.8 s |
| netpbm     |       5.5 s |       5.2 s |
| wbmp       |      64.5 s |      16.5 s |
| webp       |       4.9 s |       4.8 s |
| **total**  | **298.6 s** | **123.1 s** |

The hash alone took jpeg to 66 s, qoi to 43 s, and wbmp to 47 s; the base
cap did the rest. Peak RSS of oracle-compare: 1.81 GB before, 1.84 GB after.

## Does the base cap weaken the gate?

The class it could miss is a bug that needs a large image and a damaged
stream. Mutants (`mutants.txt`, src/ edits since reverted): each decoder
accepts a `Truncated` error as success when the image has at least 700, or
at least 300, rows, leaving the unread pixels as they were. A run counts
mismatches with mutations from every corpus file (`all`, the old inputs),
only from files of at most 2^18 pixels (`cap`), and the committed mix
(`mix`):

| Mutant           |  all | cap |  mix |
| ---------------- | ---: | --: | ---: |
| wbmp, ≥ 700 rows | 1009 | 224 |  307 |
| wbmp, ≥ 300 rows | 2036 | 932 | 1014 |
| qoi, ≥ 700 rows  |  972 | 159 |  224 |
| qoi, ≥ 300 rows  | 1947 | 718 |  838 |
| jpeg, ≥ 700 rows |  728 |  88 |  137 |
| jpeg, ≥ 300 rows | 1382 | 514 |  557 |

Every mutant fails the gate in every arm: mutations of small files reach
large sizes through their headers. Fewer inputs witness it, so the mix keeps
one mutation in 16 on any file, for the damage only a large file's own
stream can carry, at about 3 s a format. A mutant gated on the byte
position of the truncation (past 300 000 bytes, jpeg) failed none of the
three arms, the old inputs included, so it measures nothing either way.

## WebP's work memory

`webp-arena-work.txt`, `webp-per-input-work.txt`: test/oracle/webp.zig's
threadlocal buffer turned off, and bench/corpus-gen/webp/lossless added to
its corpus. With work from the batch arena, the oracle passed 5 GiB of
resident memory in 10 s and was killed; with work per input it finished,
0 mismatches, at 1.25 GB peak for the process tree, in 71 s.

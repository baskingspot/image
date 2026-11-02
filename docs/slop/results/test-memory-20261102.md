# `just test` on an 8 GB orb: ReleaseFast after ReleaseSafe

2026-11-02, Intel Xeon @ 2.60GHz (4 threads, an Amp orb with 7956 MiB, whose
workload cgroup has `memory.max` 6 GiB), main at 47dc0a3. Each run was
`just test` alone in a fresh worktree (an empty `.zig-cache`), sampled every
0.25 s for its cgroup's anonymous memory, as in
`oracle-memory-20261102.md`. Raw output is in `test-memory-20261102/`.

`just test` runs three builds: Debug `test`, ReleaseSafe `test`, and the
ReleaseFast unit tests (`test-unit`). Each of the two `test` builds compiles
the unit tests, the fuzz targets, and oracle-compare's tests at once. Until
now, the ReleaseFast build ran beside the ReleaseSafe one, so three large
Zig compiles ran together, about 1.6 GiB each.

| `just test`                    |     Peak |  Wall |
| ------------------------------ | -------: | ----: |
| ReleaseFast beside ReleaseSafe | 4948 MiB | 113 s |
| ReleaseFast after ReleaseSafe  | 3304 MiB | 203 s |

Phases of the new order: Debug 18 s (peak 2436 MiB), ReleaseSafe 92 s (3304
MiB), ReleaseFast 93 s (1747 MiB). The peak was growing with each format
(4401 MiB at harness pass 4, 4654 with JPEG XL, 4949 at pass 5), and now has
2.7 GiB of headroom under the cgroup's 6 GiB instead of 1.1 GiB.

The cost is 90 s of wall time, more than the 60 s estimated: the
ReleaseFast compile takes as long alone as it did beside ReleaseSafe's two.
Starting it beside the Debug build instead would save only Debug's 18 s and
bring back a 4.2 GiB phase. On GitHub, `test` is its own job beside
`oracle-ci` (2 min and 3 min 20 s in run 41403827568), so the run's wall
time grows only if `test` becomes the longer job.

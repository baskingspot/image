# PNG `ignore_checksums`: what skipping the checksums saves, 2026-11-01

`image.png.Decoder.Options.ignore_checksums` (decision 9) skips the CRC-32
of critical chunks and accepts a wrong Adler-32. The CRCs are then not
computed at all. The Adler-32 still is, since `compress`'s `zlib.Reader`
has no way to skip it (png.md), so this measures the CRC alone.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host), Linux 6.1, Zig 0.16.0, `zig build bench` (ReleaseFast for this CPU),
on origin/main 3cfc482 with this change. Two `bench-image` builds that
differ only in `bench/zig/png.zig` passing `.ignore_checksums = true`:
`strict` (the default) and `lax`. `png-decode` on the 52 files of
`bench/corpus-gen/png/` (results/png-20261101.md lists them), whole file
into RGBA8, 20 interleaved rounds pinned to core 3 (`taskset -c 3`), the
order alternating each round, `BENCHTIME_MS=40`. An A/A control ran the
same `strict` binary under two names for 10 rounds.

## Results

| rows (count)     | `lax` time / `strict` time |
| ---------------- | -------------------------- |
| icons ≤ 64² (17) | 0.949                      |
| to 1 MP (27)     | 0.963                      |
| over 1 MP (8)    | 0.946                      |
| all (52)         | 0.956                      |

Each row's ratio is the median over rounds of the paired ratio, `lax`
over `strict` within a round; the classes are geometric means of rows.
50 of the 52 rows are faster. benchstat (`ab/benchstat.txt`) agrees:
−4.72% time and +4.95% megapixels per second geomean, about 30 rows at
p < 0.05. The A/A control (`aa/`) gives a paired ratio of 0.9945 and no row
at p < 0.05, though its unpaired benchstat geomean moved 2.1%: this host
drifts between passes, so the paired ratios are the steady number.

So skipping the CRCs saves about 4.5% of a decode at every size. A faster
CRC would narrow the gap for strict decodes too. Skipping the Adler-32
too would save more; `compress` would need a `zlib.Reader` option that
leaves flate's checksum hook unset and reads the trailer without
comparing it.

Raw output: `png-ignore-checksums-20261101/ab/` (`strict.txt`, `lax.txt`,
`benchstat.txt`, `paired.txt` with each row's median ratio and its range)
and `png-ignore-checksums-20261101/aa/`. Absolute times on this host swing
by 10–30% between passes; read the ratios, not the times.

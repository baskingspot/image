# GIF decode: `ignore_too_much_data` and the LZW bad-code exit, 2026-11-02

Decision 12 adds `gif.Decoder.Options.ignore_too_much_data`. To keep the
pixels decoded before a bad code, which the option needs once a frame is
whole, `lzw.Decoder.decode` now ends with a `bad_code` status and the
output position instead of returning `error.BadLzw`, and `Out.emit` notes
whether any index came. Both touch the hot loop's exits, not its body, so
this checks that nothing got slower.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512, shared cloud
host), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU, pinned to core 3.
A is bench-image at origin/main aafcf23, B the same with this change, on
the 52 rows of `gif-decode` and `gif-decode-anim`.

## Interleaved A/B

Both binaries serve the same row back to back, alternating which goes
first, 5 rounds of about 40 ms each per row; a ratio is B's throughput over
A's, the geometric mean over rows of each row's median (`ab.txt`; this
script's classes split at 1,000,000 pixels):

| rows        | count | B / A |
| ----------- | ----- | ----- |
| still icon  | 14    | 1.028 |
| still 1mp   | 22    | 1.021 |
| still large | 10    | 1.008 |
| anim icon   | 2     | 1.093 |
| anim 1mp    | 3     | 1.046 |
| anim large  | 1     | 0.986 |
| all         | 52    | 1.024 |

No row class is slower beyond noise. The anim large row is one file.

## Throughput

One `bench` pass of each binary (`BENCHTIME_MS=100`, sequential, so only
indicative; `bench-A.txt`, `bench-B.txt`), geometric mean MP/s by class:

| class       | A     | B     |
| ----------- | ----- | ----- |
| still icon  | 397.9 | 434.7 |
| still 1mp   | 843.1 | 864.8 |
| still large | 740.2 | 766.6 |
| anim icon   | 100.9 | 113.4 |
| anim 1mp    | 261.1 | 278.6 |
| anim large  | 571.9 | 580.2 |

Memory is unchanged: the work memory is the same, and the option adds a
`bool` to the decoder's state.

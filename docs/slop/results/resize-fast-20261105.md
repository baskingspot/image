# image.resize's fixed-point 8-bit path, 2026-11-05

Plan.md decision 82: a fixed-point vertical pass for 8-bit formats, as
libvips and Pillow filter 8-bit samples, against libvips on large 8-bit
downscales and stb_image_resize2 on icons. The design is in
docs/slop/resize.md (Fixed point); the error bound and tolerance in
test/oracle/resize.zig.

Method: `just bench-compare 10` over the nine resize rows, on one core of
an Intel Xeon @ 2.60GHz (4 threads, AVX-512 with VNNI), image in
ReleaseFast for the native CPU, the C arms at `cc -O3 -march=native`, 50
ms a sample, 10 rounds. The A/B is a fifth arm, `base`: origin/main
(cf11e9f) built the same way (`zig build bench` in a worktree, copied to
zig-out/bin/bench-base, and added to the arm list for this run only), so
every row is timed by base, image, stb, and libvips back to back on the
same pinned core, in an order that rotates from row to row and round to
round. MP/s are source megapixels a second. Raw output:
resize-fast-20261105/ (summary.txt, benchstat.txt of every arm against
image, ab-benchstat.txt of image against base, rss.txt, config.txt). The
arms are as in resize-20261105.md.

## Result

| Row, size class               | rows | image MP/s | vs base | stb MP/s | image/stb | libvips MP/s | image/libvips |
| ----------------------------- | ---: | ---------: | ------: | -------: | --------: | -----------: | ------------: |
| ResizeGray8Quarter/icon       |   12 |      486.1 |    1.02 |    496.0 |      0.98 |          1.8 |           265 |
| ResizeGray8Quarter/1mp        |    8 |     2315.3 |    1.25 |   1653.8 |      1.40 |         51.1 |          45.3 |
| ResizeGray8Double/icon        |   12 |      155.2 |    1.00 |    176.4 |      0.88 |          1.7 |          92.8 |
| ResizeGray8Double/1mp         |    8 |      308.5 |    1.01 |    263.7 |      1.17 |          9.4 |          32.7 |
| ResizeBGRA8PremulQuarter/icon |   12 |      321.2 |    1.14 |    324.4 |      0.99 |          1.6 |           206 |
| ResizeBGRA8PremulQuarter/1mp  |    8 |      924.0 |    1.43 |    611.9 |      1.51 |         41.5 |          22.3 |
| ResizeBGRA8PremulDouble/icon  |   12 |       91.5 |    1.00 |     91.5 |      1.00 |          1.3 |          68.8 |
| ResizeBGRA8PremulDouble/1mp   |    8 |      121.8 |    0.99 |    101.5 |      1.20 |          4.6 |          26.4 |
| ResizeRGB8Thumb256/large      |    2 |     1116.4 |    2.28 |    649.1 |      1.72 |       1094.5 |          1.02 |
| ResizeRGB8Thumb1024/large     |    2 |      765.6 |    1.56 |    677.5 |      1.13 |        781.2 |          0.98 |
| ResizeRGB8Double/1mp          |    4 |      108.3 |    1.00 |    120.3 |      0.90 |          5.9 |          18.3 |
| ResizeRGBA8Half/icon          |    2 |      185.0 |    1.00 |    186.9 |      0.99 |          1.4 |           128 |
| ResizeRGBA8Half/1mp           |    2 |      288.2 |    1.00 |    257.3 |      1.12 |         32.6 |          8.84 |
| ResizeRGBA8Half/large         |    1 |      249.1 |    1.00 |    228.5 |      1.09 |         40.0 |          6.23 |
| ResizeRGB8SrgbThumb256/large  |    2 |      340.9 |    1.00 |    410.7 |      0.83 |            - |             - |
| all (geomean)                 |   95 |      307.2 |    1.10 |          |      1.08 |              |          55.1 |

"vs base" is the geomean over the class's inputs of image's median over
base's, from the same run. benchstat (ab-benchstat.txt) puts every
thumbnail, every premultiplied BGRA quarter from 32 pixels, and every gray
quarter from 64 pixels above base at p ≤ 0.002: thumbnails +127% (256)
and +55–57% (1024), BGRA quarters +14% (32), +28–30% (64), +38–39% (128),
and +46–49% (256), gray quarters +6–10% (64), +18–20% (128), and +31–32%
(256). Rows the fixed path does not take (doubling, straight alpha, sRGB,
gray quarters from 16 and 32 pixels) are within ±1% but three inputs: gray
16→4 and 32→8 at −1.1% to −3.1% (p ≤ 0.023), which run the same float
code as base; callgrind counts about 10% more instructions per 16→4 call,
from inlining that moved when `take` and `Layout.init` grew, not from new
work on that path.

Against the bars: libvips's reduce on the 4000×3000 thumbnails is matched
(1.02 at 256, 0.98 at 1024; it was 0.45 and 0.62), and stb_image_resize2
on icons is 0.98 for gray quarters and 0.99 for BGRA quarters (they were
0.96 and 0.85). Over all 95 rows image is 1.08× stb (was 0.97). What
stays behind stb: gray doubling of 16 and 32 pixel icons (0.74–0.88),
RGB doubling (0.90), and the sRGB thumbnail (0.83), none of which the
fixed path takes.

## Where fixed point pays

Microbenchmark (one call including `workLen`, pinned, µs a call, the two
paths forced in turn on the same build) before the 64-byte threshold:

| Case               | fixed | float |
| ------------------ | ----: | ----: |
| gray8 16→4         |  1.45 |  1.22 |
| gray8 32→8         |  2.34 |  2.01 |
| gray8 64→16        |   4.0 |   4.5 |
| gray8 128→32       |   9.0 |  10.9 |
| gray8 64→48        |   8.1 |   7.1 |
| gray8 256→192      |    70 |    82 |
| bgra8_premul 16→4  |  1.52 |  1.54 |
| bgra8_premul 24→6  |  2.83 |  3.22 |
| bgra8_premul 32→8  |  3.16 |  3.85 |
| bgra8_premul 64→16 |   7.0 |   9.1 |
| bgra8_premul 32→24 |  5.40 |  5.94 |
| rgb8 32→8          |  3.61 |  4.03 |

The integer kernel is faster per row at every length (3.9 against 5.7 ns
for 16 bytes and 4 taps, 15 against 20 ns for 64 bytes and 8), but each
distinct destination row's weights cost about 100 ns to plan (rows a
period apart with equal weights copy them). Below a 64-byte source row
that loses, so the fixed path takes rows of 64 bytes and up. The
exception left is gray 64→48 (64 bytes, 7 taps), 14% slower in fixed
point here; a rule on bytes times taps did not separate the cases better.

Planning cuts that did not show: taking the scale's exponent from the
float's bits instead of `@log2` (a compiler_rt call), and two fewer
divisions a row. A ring row index by multiplication (Lemire, Kaser, and
Kurz) instead of `%` took gray 16→4 from about 1.23 to 1.17 µs; it is in
the measured build.

## Memory

| Case                  | base work | fixed work | peak RSS base | peak RSS image |
| --------------------- | --------: | ---------: | ------------: | -------------: |
| rgb8 4000×3000 → 256  |   680 KiB |   1201 KiB |      71.6 MiB |       72.2 MiB |
| rgb8 4000×3000 → 1024 |   786 KiB |    744 KiB |      71.7 MiB |       71.7 MiB |
| gray8 64 → 16         |   9.0 KiB |    6.4 KiB |             - |              - |
| bgra8_premul 64 → 16  |  13.7 KiB |   14.4 KiB |             - |              - |

The fixed path runs the vertical pass first, so its ring holds raw source
rows (63 of 12,000 bytes for the 256 thumbnail) where base held rows
already filtered to the destination's width (63 of 256 × 4 floats). The
trade on the 256 thumbnail is 2.28× the speed for 521 KiB more work
memory; peak RSS, which the 36 MB input dominates, rises 0.6 MiB. At 1024
and on icons the work memory is about the same or smaller.

## Agreement

Against our float path, on 12,000 random 8-bit requests (gray8, rgb8,
bgra8_premul, cmyk8; every filter and edge; noise, stripes, ramps), 0.13%
of 828 million samples differ by 1 and none by more. Against
stb_image_resize2 the tolerance stays 1 step; on the oracle's 5,000
requests with seed 1, 2,318 need the step (2,195 before), and 1,252 of
the 0.97 module's (953 before).

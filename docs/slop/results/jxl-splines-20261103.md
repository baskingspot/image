# JPEG XL decode: splines streamed, and reference slots left alone, 2026-11-03

## Reference slots: peak RSS does not move

`jxl-noiseup-20261103.md` proposed sizing the four reference slots by the
frames saved in them: they take most of the arena peak (the allocation
high-water mark) of a cjxl `--resampling` file, which saves a strip of
patches in one of them. Peak RSS says the slots cost nothing more than
what is saved in them: `saveFrame` writes a smaller frame compactly at
the start of its slot, and a slot no frame is saved to is never written,
so the rest of their pages are never touched. Peak RSS of one decode
each, the bench's Zig arm (`bench-image serve`, main 438fa5c, ReleaseFast,
work memory allocated without touching it), against libjxl decoding to
RGBA16 on one thread (`rss.txt`):

| file                                   | arena peak MB | RSS MiB | output MiB | libjxl MiB |
| -------------------------------------- | ------------- | ------- | ---------- | ---------- |
| 4000×2667 photo, `-d 4 --resampling=2` | 693.1         | 127.9   | 81.4       | 102.4      |
| the same with alpha                    | 923.5         | 143.5   | 81.4       | 105.5      |
| 1313×6097 screenshot, `--resampling=2` | 668.0         | 84.5    | 61.1       | 82.7       |
| 1200×1200 photo, `--resampling=2`      | 22.0          | 35.0    | 11.0       | 22.4       |

What is touched beyond the output is the streamed band, mostly its
upsampled planes (512 rows of three 4000-sample planes, 24.6 MB on the
4000×2667 file), not the slots. Sizing the slots would lower the arena
peak but not RSS, and `work_len` is a bound fixed before the frames are
known, so the item is dropped. Upsampling a band in parts would cut the
24.6 MB.

## Splines streamed

`image.jxl.Decoder` on `wave4-jxl-splines` streams VarDCT frames with
splines; only extra channels upsampled by another factor than the colors
now keep a frame whole. `splines.prepare` makes the reference's checks
once and keeps each spline's control points and dequantized curves, with
the rows its dots cover (one walk of its dots, done only for a streamed
frame); each band then walks the splines that reach its window's rows
and adds their dots there, after the patches and before upsampling. A
pixel takes its dots in the same order as on the whole frame, so the
pixels are the same bit for bit. An error the checks find is held and
returned after the last group, where the whole frame meets it. The
readied splines take at most what the read ones do
(`splines.workBytes`, about twice the read budget in `work_len`).

cjxl writes no splines, so the test files are cjxl VarDCT files with the
splines of the conformance file animation_spline's second frame put in
their LF global section by hand (`jxl-splines-20261103/splice.py`: sets
the frame header's splines flag, prepends the spline bits to the LF
global section, and rewrites the TOC). libjxl decodes them too. Streamed
and whole hash the same, and against libjxl they are within the splines'
conformance bound (peak 262, RMS 6.55 16-bit steps):

| file                                       | peak before MB | after | libjxl peak, RMS |
| ------------------------------------------ | -------------- | ----- | ---------------- |
| 400×1100, `-d 2 --epf=1 --gaborish=1`      | 10.5           | 9.0   | 52, 0.27         |
| 800×2200 with alpha, `-d 2 --resampling=2` | 40.1           | 15.3  | 54, 0.28         |
| 800×2200 with alpha, noise, `--epf=2`      | 58.2           | 25.3  | 48, 0.16         |
| 32×1030 (the unit test's file)             | 2.90           | 2.81  | 42, 0.26         |

All 303 corpus files hash as before. Speed: no bench row has splines;
ten decodes of each file on one core, `jxltool` (ReleaseSafe), before and
after, twice, interleaved: animation_spline (61 whole frames) 516 and 533
ms against 519 and 531, unchanged once `prepare` skips the rows walk for
whole frames (with it, 5% slower); the 800×2200 upsampled file, which now
streams, 241 and 239 ms against 226 and 208.

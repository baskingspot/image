# PNG encode against libpng and libspng, 2026-11-02

`image.png.encode` (wave 5) against libpng and libspng, the bars for speed
and size. Every arm encodes RGB or RGBA8 pixels from memory into a PNG in
memory per call (`png-encode` and `png-encode-fast`, bench/ops.tsv, both
`own`: the encoders choose differently, so outputs are compared by size,
not checksum). Throughput is megapixels per second; a ratio is this
package's throughput over the arm's (above 1, ours is faster), the
geometric mean over a size class's rows of each row's median paired ratio
over 10 rounds. docs/slop/png.md has the encoder's design.

Machine: Intel Xeon Processor @ 2.60GHz (4 vCPUs, AVX-512; a shared cloud
host), Linux 6.1, Zig 0.16.0 ReleaseFast for this CPU; C arms `cc -O3
-march=native`. Each arm runs pinned to the last core. Inputs: the 44
sources of `bench/corpus-gen/tga/rgba` (16×16 icons to the 50-megapixel
photo mosaic), RGB or RGBA8 as their TGA files hold them. Size classes:
icons (at most 4096 pixels, 13 rows), up to a megapixel (23), larger (8).

The arms: libpng 1.6.59 and libspng 0.7.4 (zlib 1.3.2) at their defaults (zlib level 6,
libpng's adaptive filters, libspng's) for `png-encode`, and at zlib level 1
for `png-encode-fast`, writing the pixels' own color type. Ours writes the
reduced color type (reduce.zig) at `Effort.default` and `Effort.fast`.

## Results

### As merged

The encoder as it lands, on image main a26c7ed with `compress` pinned to
6319823 (compress main: the lazy levels, the filtered strategy, cheaper
stream setup, and a block's token list and output scratch in the writer's
caller-provided buffer rather than on the stack, the owner's decision 16):
`just bench-compare 10 png-encode png-encode-fast`, exit 0
(`png-encode-20261102/final/`). The full `just bench-compare` cannot finish
on this orb: `bench-go serve` reaches 4.6 GB in round 1 and the memory
cgroup kills the run.

| operation, class | image MP/s | vs libpng | vs libspng | size vs libpng | size geomean |
| ---------------- | ---------- | --------- | ---------- | -------------- | ------------ |
| default, icons   | 13.4       | 2.31      | 2.04       | 0.964          | 0.984        |
| default, ≤1 MP   | 21.5       | 3.52      | 4.00       | 0.993          | 0.881        |
| default, >1 MP   | 15.6       | 3.41      | 3.77       | 0.987          | 0.957        |
| fast, icons      | 15.8       | 1.62      | 1.41       | 0.885          | 0.918        |
| fast, ≤1 MP      | 42.7       | 2.05      | 2.76       | 0.941          | 0.797        |
| fast, >1 MP      | 36.0       | 1.96      | 2.58       | 0.887          | 0.899        |

The bytes are the same as in the run below, and the ratios to libpng and
libspng are within 3% of it; absolute MP/s are 4–11% lower for every arm,
the shared host being slower that afternoon. Slowest rows against libpng:
default 1.42× (a 16×16 icon), 2.62× (kodim01), 2.94× (a 1024×1316 RGBA
texture); fast 1.24×, 1.15×, 1.43×. Peak RSS (MiB, image / libpng /
libspng): default icons 2.7 / 3.0 / 2.9, ≤1 MP 11.2 / 10.9 / 13.1, >1 MP
387.0 / 387.0 / 432.5; fast icons 2.9 / 3.0 / 2.8, ≤1 MP 11.3 / 10.9 /
13.0, >1 MP 386.9 / 387.0 / 440.0. Work memory is now 850,439 bytes plus 72
per pixel of width (868,871 bytes for 256 px, 1,440,263 for the 8192-px
mosaic), 328,328 bytes more than before because the block scratch moved
from the stack into it; the peak a process uses is unchanged.

### Before the scratch moved

Two runs, the same code but for `compress`. With baskingspot/compress's
lazy levels 7 and 9, the filtered strategy, and cheaper stream setup (then
branch `image-png-deflate` at `61916a7`; rebased, the same change is
`ba7790a` on compress main)
(`png-encode-20261102/compress-branch/`):

| operation, class | image MP/s | vs libpng | vs libspng | size vs libpng | size geomean |
| ---------------- | ---------- | --------- | ---------- | -------------- | ------------ |
| default, icons   | 14.0       | 2.24      | 1.95       | 0.964          | 0.984        |
| default, ≤1 MP   | 24.0       | 3.51      | 3.99       | 0.993          | 0.881        |
| default, >1 MP   | 17.6       | 3.45      | 3.80       | 0.987          | 0.957        |
| fast, icons      | 17.5       | 1.59      | 1.39       | 0.885          | 0.918        |
| fast, ≤1 MP      | 46.3       | 1.99      | 2.70       | 0.941          | 0.797        |
| fast, >1 MP      | 40.0       | 1.92      | 2.53       | 0.887          | 0.899        |

Size is the class's total bytes over libpng's (libspng's are the same to
the byte at both levels), and the geometric mean of the per-file ratios.
Over all 44 files the default writes 71,233,246 bytes against libpng's and
libspng's 72,140,636 (−1.3%), and `fast` 73,324,737 against their level 1's
82,059,004 (−10.6%). Each class's slowest row: default 1.43× libpng (a
16×16 icon), 2.63× (kodim01), 3.10× (a 1024×1316 RGBA texture); fast 1.21×
(a 16×16 icon), 1.10× (a 1260×806 photo), 1.39× (a 1276×850 photo). Against
libspng, the 16×16 icons are the only rows near or behind: 0.91–1.15× at
the default and 0.75–0.81× at `fast`, where libspng at level 1 takes about
23 µs and we take 30. The 50 MP mosaic encodes in 6.2 s at the default
(libpng 21.9 s) and 1.5 s at `fast` (libpng 3.1 s).

Peak RSS (MiB), one pass over each class's inputs through
`bench-<arm> serve`, so the input and output buffers plus each library's
own memory (`rss-by-class.txt`, made by `rss-by-class.sh`):

| operation | class | image | libpng | libspng |
| --------- | ----- | ----- | ------ | ------- |
| default   | icons | 2.6   | 2.9    | 2.9     |
| default   | ≤1 MP | 11.0  | 10.9   | 13.0    |
| default   | >1 MP | 386.8 | 386.9  | 432.5   |
| fast      | icons | 2.8   | 2.9    | 2.8     |
| fast      | ≤1 MP | 11.1  | 10.9   | 13.0    |
| fast      | >1 MP | 386.8 | 387.0  | 440.0   |

Our work memory was then about 511 KiB plus 72 bytes per pixel of width
(1.1 MB for the mosaic), with another 320 KiB of stack per block, nothing
per row; libspng holds the whole filtered image.

With `compress` as it was pinned before the lazy levels (`fd03d72`), every effort is level 6 and each
stream pays the old setup (`png-encode-20261102/compress-0.2.0/`, 5
rounds), so `png-encode` and `png-encode-fast` run the same code and only
the arm they are compared with differs:

| class | image MP/s | vs libpng default | vs libspng default | vs libpng level 1 | vs libspng level 1 | size vs libpng default |
| ----- | ---------- | ----------------- | ------------------ | ----------------- | ------------------ | ---------------------- |
| icons | 14.4       | 2.14              | 1.91               | 1.29              | 1.12               | 0.972                  |
| ≤1 MP | 46.8       | 6.68              | 7.60               | 1.94              | 2.62               | 1.025                  |
| >1 MP | 40.0       | 7.64              | 8.40               | 1.90              | 2.53               | 1.015                  |

That is the branch as pushed: 1.6% larger than libpng's default over all
files (73,324,737 bytes) at 2.1–7.6× its speed. The 16×16 icons are
behind libspng (0.62–0.76× its default, 0.54–0.57× its level 1) and three
of them behind libpng at level 1 (0.90–0.95×): about 45 µs each, most of
it the stream setup the `compress` branch removes (30 µs with it).

## Effort levels

Measured with `/tmp/scratch/effab` (not committed): every file of the set
but the mosaic, through `image.png.encode` at each effort, best of 200
calls for icons and of one for the rest. Bytes are exact; times come from
one unpinned run while other work shared the machine, so only their ratios
are indicative.

| effort, filter      | icons bytes | ≤1 MP bytes | >1 MP bytes (7) | ≤1 MP time | >1 MP time |
| ------------------- | ----------- | ----------- | --------------- | ---------- | ---------- |
| fast (level 6)      | 33,929      | 9,574,907   | 14,246,432      | 323 ms     | 518 ms     |
| fast, Paeth only    | 34,593      | 9,708,633   | 14,549,217      | 347 ms     | 546 ms     |
| default (level 7 f) | 33,661      | 9,276,152   | 13,703,223      | 964 ms     | 1,132 ms   |
| best (level 9 f)    | 33,076      | 9,163,624   | 13,489,669      | 2,237 ms   | 3,849 ms   |

The default is level 7 with the filtered strategy: 3.1–3.8% smaller than
level 6 on photographs and screenshots, which takes it from 1.6% larger
than libpng to 1.3% smaller, while still encoding 2.2–3.5× faster than libpng.
`best` takes another 1.2–1.6% off at 2.3–3.4× the default's time. Choosing
each row's filter by the minimum sum of absolute differences rather than
always using Paeth saves 1.4–2.1% for no time beyond the noise. Level 1,
whose blocks are fixed Huffman only, made files 28% larger than libpng's
default and was rejected for `fast`.

The deflate side, levels 7 and 9 and the setup costs that dominated icons
(a 392-KiB memset and copy per stream, a 256-KiB memset per block), is
written up in baskingspot/compress's
docs/slop/results/flate-lazy-png-20261101.md on the same branch.

## Against oxipng

oxipng is not in the dev shell; this one-off used oxipng 10.2.1 from
nixpkgs (`/tmp/scratch/oxi.sh`, not committed). It recompressed our
default files, all but the mosaic, at its default preset (`-o 2`) and at
`-o 6`, one thread each. Bytes per class, with libpng's default for scale:

| encoder        | icons  | ≤1 MP     | >1 MP (7)  | all (43)   | vs oxipng -o 2 |
| -------------- | ------ | --------- | ---------- | ---------- | -------------- |
| libpng default | 34,909 | 9,343,390 | 14,696,423 | 24,074,722 | 1.123          |
| image, default | 33,661 | 9,276,152 | 13,703,223 | 23,013,036 | 1.073          |
| image, best    | 33,076 | 9,163,624 | 13,489,669 | 22,686,369 | 1.058          |
| oxipng -o 2    | 31,044 | 8,767,584 | 12,647,944 | 21,446,572 | 1.000          |
| oxipng -o 6    | 30,799 | 8,680,160 | 12,493,145 | 21,204,104 | 0.989          |

oxipng is an optimizer that tries several filter strategies per image with
libdeflate's near-optimal parsing, at many times an encoder's cost; the
5.8–7.3% between it and us is the room left for a slower effort (a better
deflate parse, and trying more than one filter heuristic).

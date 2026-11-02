# Benchmarks

`just bench-compare` measures this package against each format's best
library and the comparison arms on the machine it runs on: megapixels per
second and peak RSS, per operation and image size. Its numbers describe that
machine on that day; they are not claims.

```sh
just bench-compare 10                 # every operation, 10 rounds
just bench-compare 10 qoi-decode      # one operation
just bench-summary                    # the last run's summary again
```

The results land in `zig-out/bench-compare/`: `config.txt` (CPU and builds),
`rss.txt`, `benchstat.txt`, `summary.txt`, and `rows.txt` with every row's
ratio and interval.

## Arms

| Arm             | What it runs                             | Built from                                          |
| --------------- | ---------------------------------------- | --------------------------------------------------- |
| `image`         | this package, ReleaseFast                | `bench/zig/` and `bench/c/arm.c`, `zig build bench` |
| `wuffs`         | Wuffs's decoders and pixel swizzler      | `bench/c/wuffs-*.c`                                 |
| `qoih`          | qoi.h, the reference QOI codec           | `bench/c/qoih-*.c`                                  |
| `stb`           | stb_image                                | `bench/c/stb-*.c`                                   |
| `libpng`        | libpng                                   | `bench/c/libpng-*.c`                                |
| `spng`          | libspng                                  | `bench/c/spng-*.c`                                  |
| `libwebp`       | libwebp, and its demux animation decoder | `bench/c/libwebp-*.c`                               |
| `giflib`        | giflib                                   | `bench/c/giflib-*.c`                                |
| `libjpeg-turbo` | libjpeg-turbo                            | `bench/c/libjpeg-turbo-*.c`                         |
| `magick`        | ImageMagick's MagickWand                 | `bench/c/magick-*.c`                                |
| `libtiff`       | libtiff                                  | `bench/c/libtiff-*.c`                               |
| `libjxl`        | libjxl                                   | `bench/c/libjxl-*.c`                                |
| `image-rs`      | Rust's `image` crate                     | `bench/rust`, feature `image-rs`                    |
| `zune`          | the zune crates                          | `bench/rust`, feature `zune`                        |
| `jxl-oxide`     | the jxl-oxide crate                      | `bench/rust`, feature `jxl-oxide`                   |
| `go`            | Go's `image` packages                    | `bench/go`                                          |

Every arm but Go's is `bench/c/arm.c` with a set of operations linked in, so
they share one harness: the same timing loop, and every buffer an anonymous
mapping of its own with the input `BENCH_IN_OFFSET` bytes (default 0) and the
output `BENCH_OUT_OFFSET` bytes (default 2048) past a page boundary, every
page touched before timing. The Zig and Rust arms register their operations
from `bench_init`; the C arms with `BENCH_OP`. Go's arm implements the same
contract natively, since a cgo call per operation costs more than decoding an
icon. A C arm is a line in `bench/c/arms.tsv`; a Rust arm is a feature in
`bench/rust` and a word in the justfile's `rust_arms`.

## Arm contract

```
bench-<arm> check [OP...]   one call per input: `<Row>/<input>\tlen=N fnv=H`
bench-<arm> bench [OP...]   each input timed for BENCHTIME_MS
bench-<arm> serve           `OP INPUT N` lines on stdin, a row each
```

An operation writes its output into the caller's buffer and returns its
length, or 0 when it fails the input. An arm skips the inputs it fails,
`# SKIP <Row>/<input>: failed` in place of their lines, and those rows drop
out of its comparisons; `just bench-compare` lists them, and fails only when
this package fails one. Its inputs are the files in its directory of `bench/corpus-gen/`, as
`bench/ops.tsv` says, and every input's name ends in `-WxH`, its size, so
throughput is in megapixels per second for every operation.

An encode or conversion row's input is raw pixels, tightly packed, with no
header; the harness sets `bench_width` and `bench_height` (`bench/c/arm.h`)
to the size in its name before any call, and the input's bytes per pixel are
its length over that. The Zig arm reads them through `bench/zig/input.zig`,
the Rust arms through `input_size()` in `lib.rs`, and the Go arm as
`inWidth` and `inHeight`.

A rotating operation (`rotate=<op>` in the sixth column of `bench/ops.tsv`)
times `<op>`'s function on many distinct files, so that a tiny input's
branches cannot be learned: it has one row per input size,
`rotate<N>-<W>x<H>`, whose calls take that size's N files in turn, and its
`check` line sums their lengths and their FNV-1a hashes. `png-decode-icons`
and `qoi-decode-icons` rotate through 64 icons at 16, 32, and 64 pixels
(`bench/corpus/icons.sh`).

## Method

1. **Checksums.** Every arm decodes or converts every input once, and its
   output must hash the same as this package's, unless the operation is
   marked `own` (the arms may round or composite differently; the differences
   are listed, not failed).
2. **Peak RSS** of one pass over each operation's inputs, by GNU time: the
   inputs and outputs every arm holds alike, plus the library's own memory.
   Under each operation, a row per size class (icon, up to a megapixel,
   larger) gives the peak of that class's inputs alone, through `serve`.
3. **Rounds.** Each arm runs as a server pinned to the last core. Each row is
   timed by every arm that has it back to back, in an order that rotates from
   row to row and round to round, so all arms' samples of a row see the same
   machine. Round 0 sizes each row's loop to `BENCHTIME_MS` (default 50) and
   is not counted.
4. **Summary.** A row's ratio is the median over rounds of this package's
   throughput over the arm's in the same round, with a 95% interval from the
   order statistics; an operation's ratio is the geometric mean of its rows',
   split into icons (at most 64 by 64), up to a megapixel, and larger.
   `bench/summary.awk` has the details.

## Corpus

`just bench-corpus` builds `bench/corpus-gen/` and checks it against the
checksums in `bench/corpus/`. The sources are the
[QOI benchmark suite](https://qoiformat.org/benchmark/) (1.1 GB, fetched once
and pinned by its SHA-256) and the QOI test images: the first few photos,
screenshots, icons, and textures of each category, 16 and 32 pixel icons
scaled from its 64 pixel ones, and a 50-megapixel mosaic of its photos. Each
format's inputs are a script, `bench/corpus/<format>.sh`, that converts those
sources with the reference encoder or ImageMagick.

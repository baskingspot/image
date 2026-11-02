#!/usr/bin/env bash
# The A/Bs of jxl-encode2-20261102.md, from the repository root in the dev
# shell after `just bench-build`, with each stage's bench-image (`zig build
# bench`) saved in $B: s0 the stage 1 encoder (main dab14b0), s1 speed, s2
# buckets, s3 leaves, s4 shared, each on the one before. ab.sh is
# convert-tails-20261102's. speed and buckets ran one after the other on
# core 3; leaves and shared ran at the same time on cores 2 and 1.
set -euo pipefail
ab=docs/slop/results/convert-tails-20261102/ab.sh
B=/tmp/jxlab
R=/tmp/jxlab/results
lib=libjxl=zig-out/bin/bench-libjxl
mkdir -p $R
OPS="jxl-encode-e3 jxl-encode-e7 jxl-encode-e8" CORE=3 bash $ab $R/speed 5 image=$B/s1 before=$B/s0 $lib
OPS="jxl-encode-e3 jxl-encode-e7 jxl-encode-e8" CORE=3 bash $ab $R/buckets 5 image=$B/s2 before=$B/s1 $lib
OPS="jxl-encode-e3 jxl-encode-e7" CORE=2 bash $ab $R/leaves 5 image=$B/s3 before=$B/s2 $lib &
OPS="jxl-encode-e3 jxl-encode-e7" CORE=1 bash $ab $R/shared 5 image=$B/s4 before=$B/s3 $lib
wait

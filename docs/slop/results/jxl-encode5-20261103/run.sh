#!/usr/bin/env bash
# The A/Bs of jxl-encode5-20261103.md, from the repository root in the dev
# shell after `just bench-build`: u0 is main bc15364's bench-image, u1
# with the decoder's pixelProps and walk (walk/walk.patch), u2 with
# pixelProps only (the commit). They ran one after the other on core 3.
set -euo pipefail
B=/tmp/jxlab
ab=docs/slop/results/convert-tails-20261102/ab.sh
lib=libjxl=zig-out/bin/bench-libjxl
OPS="jxl-encode-e3 jxl-encode-e7" CORE=3 bash $ab $B/results/walk 5 image=$B/u1 before=$B/u0 $lib
OPS="jxl-encode-e3 jxl-encode-e7" CORE=3 bash $ab $B/results/props 5 image=$B/u2 before=$B/u0 $lib

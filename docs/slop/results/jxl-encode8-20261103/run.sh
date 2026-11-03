#!/usr/bin/env bash
# The A/B of jxl-encode8-20261103.md, from the repository root in the dev
# shell after `just bench-build`: x0 is main 2f4b5ab's bench-image, x2
# this branch's.
set -euo pipefail
B=/tmp/jxlab
ab=docs/slop/results/convert-tails-20261102/ab.sh
OPS="jxl-encode-e3 jxl-encode-e7 jxl-encode-e8" CORE=3 bash $ab $B/results/rows2 3 \
  image=$B/x2 before=$B/x0 libjxl=zig-out/bin/bench-libjxl

#!/usr/bin/env bash
# The A/B of jxl-encode7-20261103.md, from the repository root in the dev
# shell after `just bench-build`: w0 is main 7d8a824's bench-image, w1
# this branch's. Only default (the e7 rows) changes.
set -euo pipefail
B=/tmp/jxlab
ab=docs/slop/results/convert-tails-20261102/ab.sh
OPS="jxl-encode-e7" CORE=3 bash $ab $B/results/samples 5 \
  image=$B/w1 before=$B/w0 libjxl=zig-out/bin/bench-libjxl

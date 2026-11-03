#!/usr/bin/env bash
# The A/B of jxl-encode6-20261103.md, from the repository root in the dev
# shell after `just bench-build`: v0 is main c4554ce's bench-image, v1
# this branch's. Peak RSS is ab.sh's (one process an op, every row).
set -euo pipefail
B=/tmp/jxlab
ab=docs/slop/results/convert-tails-20261102/ab.sh
OPS="jxl-encode-e3 jxl-encode-e7 jxl-encode-e8" CORE=3 bash $ab $B/results/mem 3 \
  image=$B/v1 before=$B/v0 libjxl=zig-out/bin/bench-libjxl

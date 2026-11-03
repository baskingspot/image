#!/usr/bin/env bash
# The count A/B of jxl-encode4-20261103.md, from the repository root in
# the dev shell after `just bench-build`: t1 is this change's bench-image,
# t0 main 82dc16a's.
set -euo pipefail
B=/tmp/jxlab
OPS="jxl-encode-e3 jxl-encode-e7 jxl-encode-e8" CORE=3 bash docs/slop/results/convert-tails-20261102/ab.sh \
  $B/results/count 5 image=$B/t1 before=$B/t0 libjxl=zig-out/bin/bench-libjxl

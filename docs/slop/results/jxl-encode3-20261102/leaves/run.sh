#!/usr/bin/env bash
# The leaves measurement of jxl-encode3-20261102.md, from the repository
# root in the dev shell after `just bench-build`. m0 is main dd6b669's
# bench-image and corpus encoder (2048 leaves at default), m1 the same with
# 1024; enc-* is stage 2's scratch corpus encoder built against each, and
# all.sh and corpus.sh are jxl-encode2-20261102/corpus's.
set -euo pipefail
B=/tmp/jxlab
for i in 1 2; do
  for v in m0 m1; do ENC=$B/enc-$v CORE=3 bash /tmp/bc/all.sh $v-$i default; done
done
OPS="jxl-encode-e7" CORE=3 bash docs/slop/results/convert-tails-20261102/ab.sh \
  $B/results/l1024 5 image=$B/m1 before=$B/m0 libjxl=zig-out/bin/bench-libjxl

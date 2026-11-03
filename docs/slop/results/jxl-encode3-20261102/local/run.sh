#!/usr/bin/env bash
# The local-transforms A/B of jxl-encode3-20261102.md, from the repository
# root in the dev shell after `just bench-build`: m2 is this change's
# bench-image, m1 the one before (main 9ab4efa's encoder). Corpus runs
# went through jxl-encode2-20261102/corpus's all.sh and corpus.sh with
# the scratch encoder built against each variant of encode.zig.
set -euo pipefail
B=/tmp/jxlab
OPS="jxl-encode-e3 jxl-encode-e7 jxl-encode-e8" CORE=3 bash docs/slop/results/convert-tails-20261102/ab.sh \
  $B/results/local 5 image=$B/m2 before=$B/m1 libjxl=zig-out/bin/bench-libjxl

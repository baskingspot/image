#!/usr/bin/env bash
# The A/B of tiff-deflate-20261102.md, from the repository root: bench-image
# with the compress pin before (/tmp/dfl/before, 6319823) and after
# (/tmp/dfl/after, the new compress) beside libtiff, the tiff crate, and Go
# for TIFF Deflate, and Wuffs, libspng, libpng, and stb for PNG decode.
# ab.sh is convert-tails-20261102's.
set -euo pipefail
cd /home/user/workspace/repo
source /tmp/devenv.sh
ab=docs/slop/results/convert-tails-20261102/ab.sh
R=/tmp/dfl/res
export CORE=3
OPS="tiff-decode-deflate" bash $ab $R/tiff 8 image=/tmp/dfl/after before=/tmp/dfl/before \
  libtiff=zig-out/bin/bench-libtiff image-rs=zig-out/bin/bench-image-rs go=zig-out/bin/bench-go
OPS="png-decode png-decode-icons" bash $ab $R/png 8 image=/tmp/dfl/after before=/tmp/dfl/before \
  wuffs=zig-out/bin/bench-wuffs spng=zig-out/bin/bench-spng libpng=zig-out/bin/bench-libpng
echo ALLDONE

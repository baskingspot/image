#!/usr/bin/env bash
# The A/B of flate-encode-clears (compress) in image: bench-image with the
# compress pin before (/tmp/dfl2/before, e383aa8) and after (/tmp/dfl2/after)
# beside libtiff, the tiff crate, and Go for TIFF Deflate encode, and libpng and
# libspng for fast PNG encode. ab.sh is convert-tails-20261102's.
set -euo pipefail
cd /home/user/workspace/repo
ab=docs/slop/results/convert-tails-20261102/ab.sh
R=/tmp/dfl2/res-enc
export CORE=3
nix develop -c env OPS="tiff-encode-deflate" bash $ab $R/tiff 8 image=/tmp/dfl2/after before=/tmp/dfl2/before \
  libtiff=zig-out/bin/bench-libtiff image-rs=zig-out/bin/bench-image-rs go=zig-out/bin/bench-go
nix develop -c env OPS="png-encode-fast png-encode" bash $ab $R/png 8 image=/tmp/dfl2/after before=/tmp/dfl2/before \
  libpng=zig-out/bin/bench-libpng spng=zig-out/bin/bench-spng
echo ALLDONE

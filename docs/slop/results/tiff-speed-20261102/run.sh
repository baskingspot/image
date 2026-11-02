#!/usr/bin/env bash
# Every A/B of tiff-speed-20261102.md, from the repository root, with each
# stage's bench-image saved in $B (s0 main 8a97cbc; s1 to s5 each change on
# top of the one before; s3b the PackBits change as it landed, on s2; s7
# every change). ab.sh is convert-tails-20261102's.
set -euo pipefail
cd /home/user/workspace/repo
source /tmp/devenv.sh
ab=docs/slop/results/convert-tails-20261102/ab.sh
B=/tmp/speed/stage
R=/tmp/speed/results
mkdir -p $R
arms() { echo "image=$B/$1 before=$B/$2 libtiff=zig-out/bin/bench-libtiff image-rs=zig-out/bin/bench-image-rs go=zig-out/bin/bench-go"; }
export CORE=3
OPS="tiff-decode-lzw tiff-decode-deflate" bash $ab $R/predictor 8 $(arms s1 s0)
OPS="tiff-decode-lzw" bash $ab $R/lzw 8 $(arms s2 s1)
OPS="tiff-decode-packbits" bash $ab $R/packbits 8 $(arms s3b s2)
OPS="tiff-decode-g4" bash $ab $R/gray1 8 $(arms s4 s3)
OPS="tiff-decode-none tiff-decode-packbits" ROWS='[-](16x16|32x32|64x64)[.]tif' bash $ab $R/ycc 8 $(arms s5 s4)
OPS="tiff-decode-none tiff-decode-lzw tiff-decode-deflate tiff-decode-packbits tiff-decode-jpeg tiff-decode-g4" bash $ab $R/final 8 $(arms s7 s0)
echo ALLDONE

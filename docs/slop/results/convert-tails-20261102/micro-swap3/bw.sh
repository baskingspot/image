#!/bin/bash
# bw.sh DIR OUT W
d=$(mktemp -d /tmp/cb/w.XXXX); echo "pub const w = $3; pub const h = $4;" > $d/cfg.zig
cd /tmp/cb && zig build-exe -OReleaseFast -mcpu=native --dep conv --dep cfg -Mroot=/tmp/cb/bigw.zig -Mconv=$1/convert.zig -Mcfg=$d/cfg.zig -femit-bin=$2

#!/bin/bash
# build.sh FILTER_ZIG OUT
d=$(mktemp -d /tmp/fb/b.XXXX); cp /tmp/fb/main.zig $d/; cp $1 $d/filter.zig
cd $d && zig build-exe -OReleaseFast -mcpu=native main.zig -femit-bin=$2 2>&1 | head -20

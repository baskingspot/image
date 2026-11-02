#!/usr/bin/env bash
# Builds /tmp/encdev/encdev against the repo's image module.
set -e
repo=/home/user/workspace/repo
c=$repo/zig-pkg/compress-0.2.0-VxR1WhDlOwCFN2gb5dNKLZGgdE3ZwUyPxtoStui6e0iF/src
f=$repo/zig-pkg/fastmem-0.2.0-W3bwd4b0BgAzDPkV0NbYrRbzchboxxPvL6UVP5uhUS7X/src
opt=$(ls $repo/.zig-cache/c/*/options.zig | head -1)
mkdir -p /tmp/encdev && cp "$(dirname "$(readlink -f "$0")")/encdev.zig" /tmp/encdev/main.zig && cd /tmp/encdev
zig build-exe -O${OPT:-ReleaseFast} --dep image -Mmain=/tmp/encdev/main.zig \
  -O${OPT:-ReleaseFast} --dep compress -Mimage=$repo/src/root.zig \
  -O${OPT:-ReleaseFast} --dep fastmem -Mcompress=$c/root.zig \
  -O${OPT:-ReleaseFast} --dep fastmem_options -Mfastmem=$f/root.zig \
  -Mfastmem_options=$opt --name encdev -femit-bin=/tmp/encdev/encdev${SUFFIX:-}

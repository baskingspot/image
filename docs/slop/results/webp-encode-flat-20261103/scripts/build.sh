#!/bin/bash
# build.sh MAIN OUT: a scratch exe against the repo's image module.
source ~/.nix-profile/etc/profile.d/nix.sh
cd /home/user/workspace/repo
C=zig-pkg/compress-0.2.0-VxR1WhDlOwCFN2gb5dNKLZGgdE3ZwUyPxtoStui6e0iF
F=zig-pkg/fastmem-0.2.0-W3bwd4b0BgAzDPkV0NbYrRbzchboxxPvL6UVP5uhUS7X
nix develop --command zig build-exe -O ReleaseFast --dep image -Mroot=$1 --dep compress -Mimage=${IMG:-src}/root.zig --dep fastmem --dep fixtures -Mcompress=$C/src/root.zig --dep fastmem_options -Mfastmem=$F/src/root.zig -Mfixtures=.zig-cache/o/92f2d851aab94b34cf0c18ae2f49e53c/root.zig -Mfastmem_options=.zig-cache/c/a05a56704749d5dd3284ae76eff03ca8/options.zig --cache-dir .zig-cache --name x -femit-bin=$2 2>&1 | grep -v "^warning: Git\|evaluation warning"

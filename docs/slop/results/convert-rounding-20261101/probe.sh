#!/usr/bin/env bash
# Builds wuffs-probe against REPO's src/convert.zig (default this checkout)
# and Wuffs from the dev shell's nixpkgs, then runs it and the Go
# comparison, writing wuffs.txt and go.txt to OUT. Run in the dev shell.
#
#   probe.sh OUT [REPO]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$(mkdir -p "$1" && cd "$1" && pwd)
repo=$(cd "${2:-$here/../../../..}" && pwd)
wuffs=$(dirname "$(find /nix/store -maxdepth 4 -path '*wuffs-c-0.4*' -name wuffs-v0.4.c | head -1)")
zig build-exe -OReleaseSafe --dep convert -I"$wuffs" -cflags -O2 -- "$here/wuffs-probe.c" \
  -Mroot="$here/wuffs-probe.zig" -Mconvert="$repo/src/convert.zig" -lc --name wuffs-probe \
  -femit-bin="$out/wuffs-probe"
"$out/wuffs-probe" > "$out/wuffs.txt" 2>&1
mkdir -p "$out/go"
go -C "$here/go-probe" run . "$out/go"
"$out/wuffs-probe" go $(ls "$out"/go/*.in | sed 's/\.in$//') > "$out/go.txt" 2>&1
rm -rf "$out/go"

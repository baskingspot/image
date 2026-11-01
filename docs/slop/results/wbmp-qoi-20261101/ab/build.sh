#!/usr/bin/env bash
# build.sh NAME: builds the current tree's bench-image into /tmp/ab/NAME.
set -euo pipefail
cd /home/user/workspace/repo
zig build bench -p /tmp/ab/$1 >/dev/null
echo built $1

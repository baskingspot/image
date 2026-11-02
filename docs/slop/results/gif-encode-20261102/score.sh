#!/usr/bin/env bash
# Scores one encoded file against its source: PSNR, PSNR after a σ=1 blur, and
# 1 - SSIM, normalized as ImageMagick 7 prints them (PSNR dB = value × 120),
# and the file size. Run from a directory with src/<image>.png and
# out/<image>__<config>.gif.
g=$1; b=$(basename $g .gif); n=${b%%__*}; c=${b#*__}; p=src/$n.png
psnr=$(magick $p "$g[0]" -metric PSNR -compare -format '%[distortion]' info: 2>/dev/null)
bpsnr=$(magick $p "$g[0]" -blur 0x1 -metric PSNR -compare -format '%[distortion]' info: 2>/dev/null)
ssim=$(magick $p "$g[0]" -metric SSIM -compare -format '%[distortion]' info: 2>/dev/null)
sz=$(stat -c %s $g)
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$c" "$psnr" "$bpsnr" "$ssim" "$sz"

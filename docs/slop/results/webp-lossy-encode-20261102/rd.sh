#!/usr/bin/env bash
# rd.sh LABEL CMD... : for each image in $IMAGES and quality in $QS, encode
# with "cwebp:M" (cwebp -q Q -m M) or "ours:EFFORT", and print
# label image q bytes psnr ssim, measured by encdev cmp.
set -euo pipefail
label=$1
out=${OUT:-/tmp/rd/out}
mkdir -p "$out"
job() {
  label=$1 img=$2 q=$3 out=$4
  name=$(basename "$img" .png)
  f="$out/$label-$name-$q.webp"
  case $label in
    cwebp*) m=${label#cwebp}; cwebp -quiet -q "$q" -m "$m" "$img" -o "$f" ;;
    ours*) e=${label#ours-}; e=${e%%-*}; ${ENCDEV:-/tmp/encdev/encdev} enc "$img" "$q" "$e" "$f" > /dev/null ;;
  esac
  echo "$label $name $q $(${ENCDEV:-/tmp/encdev/encdev} cmp "$img" "$f")"
}
export -f job
for img in $IMAGES; do for q in $QS; do echo "$label $img $q $out"; done; done | xargs -P 4 -L 1 bash -c 'job "$@"' _

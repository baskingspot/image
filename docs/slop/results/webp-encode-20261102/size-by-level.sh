#!/usr/bin/env bash
# Output size per effort level and size class from `bench-<arm> check`
# files: this package's total bytes over libwebp's at the same level, over
# libwebp's -z 9, and the geometric mean of the per-file ratios at the same
# level. Classes as bench-compare's: icons (at most 4096 pixels), up to
# 1 MP, larger.
# Usage: size-by-level.sh DIR (a bench-compare output directory)
set -euo pipefail
dir=$1
len() { grep "^$2/" "$dir/check-$1.txt" | sed "s|^$2/||; s/\tlen=\([0-9]*\).*/\t\1/" | sort; }
printf '%-6s %-6s %5s %11s %11s %11s %9s %9s %9s\n' level class files image libwebp libwebp-z9 total geomean vs-z9
for k in 0 1 2 3 4 5 6 7 8 9; do
  join -t $'\t' <(len image WebpEncodeZ$k) <(len libwebp WebpEncodeZ$k) |
    join -t $'\t' - <(len libwebp WebpEncodeZ9) | awk -F'\t' -v k=$k '
    function cls(name,   d, px) { match(name, /-([0-9]+)x([0-9]+)\./, d); px = d[1] * d[2]; return px <= 4096 ? "icon" : px <= 1048576 ? "1mp" : "large" }
    { c = cls($1); n[c]++; l[c] += log($2 / $3); si[c] += $2; sa[c] += $3; s9[c] += $4
      N++; L += log($2 / $3); SI += $2; SA += $3; S9 += $4 }
    END {
      split("icon 1mp large", order, " ")
      for (j = 1; j <= 3; j++) { c = order[j]
        printf "z%-5d %-6s %5d %11d %11d %11d %9.4f %9.4f %9.4f\n", k, c, n[c], si[c], sa[c], s9[c], si[c] / sa[c], exp(l[c] / n[c]), si[c] / s9[c] }
      printf "z%-5d %-6s %5d %11d %11d %11d %9.4f %9.4f %9.4f\n", k, "all", N, SI, SA, S9, SI / SA, exp(L / N), SI / S9
    }'
done

#!/usr/bin/env bash
# Output size by size class from `bench-<arm> check` files: total bytes per
# class and arm, the ratio of this package's total to the arm's, and the
# geometric mean of the per-file ratios. Classes as bench-compare's: icons
# (at most 4096 pixels), up to 1 MP, larger.
# Usage: size-by-class.sh DIR ROW ARM... (e.g. bench-compare PngEncode libpng spng)
set -euo pipefail
dir=$1 row=$2
shift 2
len() { grep "^$row/" "$dir/check-$1.txt" | sed 's/\tlen=\([0-9]*\).*/\t\1/' | sort; }
for arm in "$@"; do
  join -t $'\t' <(len image) <(len "$arm") | awk -F'\t' -v arm="$arm" -v row="$row" '
    function cls(name,   d, px) { match(name, /-([0-9]+)x([0-9]+)\./, d); px = d[1] * d[2]; return px <= 4096 ? "icon" : px <= 1048576 ? "1mp" : "large" }
    { c = cls($1); n[c]++; l[c] += log($2 / $3); si[c] += $2; sa[c] += $3
      N++; L += log($2 / $3); SI += $2; SA += $3 }
    END {
      split("icon 1mp large", order, " ")
      for (k = 1; k <= 3; k++) { c = order[k]
        printf "%-14s %-6s %-6s rows %3d  image %11d  %s %11d  total %.3f  geomean %.3f\n", row, arm, c, n[c], si[c], arm, sa[c], si[c] / sa[c], exp(l[c] / n[c]) }
      printf "%-14s %-6s %-6s rows %3d  image %11d  %s %11d  total %.3f  geomean %.3f\n", row, arm, "all", N, SI, arm, SA, SI / SA, exp(L / N)
    }'
done

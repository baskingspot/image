# Peak RSS (MiB) of one pass over each size class of an operation's inputs,
# through `bench-<arm> serve`: icons (at most 64x64), up to 1 MP, larger.
cd /home/user/workspace/repo
arms="image wuffs stb image-rs"
printf '%-16s %-7s' op class; for a in $arms; do printf '%9s' $a; done; echo
while IFS=$'\t' read -r op row dir _; do
  case "$op" in tga-*) ;; *) continue ;; esac
  for class in icon mid large; do
    lines=$(for f in bench/corpus-gen/$dir/*; do
      n=$(basename "$f"); wh=${n##*-}; wh=${wh%.*}; w=${wh%x*}; h=${wh#*x}; px=$((w*h))
      c=large; [ $px -le 1048576 ] && c=mid; [ $px -le 4096 ] && c=icon
      [ $c = $class ] && echo "$op $n 1"
    done)
    printf '%-16s %-7s' "$op" "$class"
    for a in $arms; do
      echo "$lines" | command time -f %M -o /tmp/rss-run.txt zig-out/bin/bench-$a serve > /tmp/rss-out.txt 2>/dev/null
      if grep -q '^# SKIP' /tmp/rss-out.txt; then printf '%9s' -; else awk '{ printf "%9.1f", $1 / 1024 }' /tmp/rss-run.txt; fi
    done
    echo
  done
done < <(grep -v '^#' bench/ops.tsv)

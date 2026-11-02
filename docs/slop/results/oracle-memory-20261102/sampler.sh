#!/usr/bin/env bash
# run.sh NAME CMD...: runs CMD in the repo, sampling this cgroup's memory every 0.25 s.
run_name=$1; shift
source /tmp/devenv.sh
cd ${RUN_DIR:-/home/user/workspace/repo}
cg=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
res=/tmp/mem/$run_name
mkdir -p $res
# A restart after an OOM kill must not run again.
if [ -e $res/started ]; then echo "restarted after a kill" >> $res/result; sleep infinity; fi
touch $res/started
: > $res/samples
(
  while :; do
    a=$(awk '$1=="anon"{print $2}' $cg/memory.stat); c=$(cat $cg/memory.current)
    top=$(ps -e -o rss=,comm= --sort=-rss | head -3 | awk '{printf "%s:%d ", $2, $1/1024}')
    echo "$(date +%s.%N | cut -c1-14) $((a>>20)) $((c>>20)) $top" >> $res/samples
    sleep 0.25
  done
) &
sampler=$!
start=$(date +%s.%N)
"$@" 2>&1 | while IFS= read -r line; do echo "$(date +%s.%N | cut -c1-14) $line"; done > $res/log
rc=${PIPESTATUS[0]}
end=$(date +%s.%N)
kill $sampler
echo "rc=$rc wall=$(echo "$end - $start" | bc) peak_anon_mib=$(sort -k2 -n $res/samples | tail -1 | cut -d' ' -f2) memory.peak_mib=$(( $(cat $cg/memory.peak 2>/dev/null || echo 0) >> 20 ))" > $res/result
echo DONE >> $res/result
sleep infinity

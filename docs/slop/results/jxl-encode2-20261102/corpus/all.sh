#!/bin/bash
# all.sh tag [efforts...]: corpus totals per effort, pinned to core 3
tag=$1; shift
for e in ${@:-fast default best}; do taskset -c ${CORE:-0} bash /tmp/bc/corpus.sh $e $tag; done

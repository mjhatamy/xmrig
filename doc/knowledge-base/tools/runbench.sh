#!/bin/bash
# usage: runbench.sh <binary> <logfile> [xmrig args...]
BIN="$1"; LOG="$2"; shift 2
rm -f "$LOG"
"$BIN" --no-color --log-file="$LOG" "$@" > /dev/null 2>&1 &
PID=$!
for i in $(seq 1 1800); do
  sleep 2
  if grep -q "benchmark finished" "$LOG" 2>/dev/null; then break; fi
  if ! kill -0 $PID 2>/dev/null; then echo "xmrig exited early"; break; fi
done
kill -INT $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
grep -E "HUGE PAGES|CPU |MEMORY|randomx|dataset|threads|benchmark|ASSEMBLY|JIT|msr|init" "$LOG" | sed 's/^\[[^]]*\] //' | head -40

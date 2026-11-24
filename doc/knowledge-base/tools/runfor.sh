#!/bin/bash
# usage: runfor.sh <binary> <logfile> <seconds> [xmrig args...]
BIN="$1"; LOG="$2"; SECS="$3"; shift 3
rm -f "$LOG"
"$BIN" --no-color --log-file="$LOG" --bench=10M --print-time=30 "$@" > /dev/null 2>&1 &
PID=$!
sleep "$SECS"
kill -INT $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
echo "=== $LOG ($*)"
grep -E "allocated|dataset ready|READY" "$LOG" | sed 's/^\[[^]]*\] //'
# last speed line and last profiler averages block
grep -E " speed " "$LOG" | tail -1 | sed 's/^\[[^]]*\] //'
grep -E " profile  RandomX_" "$LOG" | tail -7 | sed 's/^\[[^]]*\] //'

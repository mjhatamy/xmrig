# Experiment helpers

Used to produce the measurements in `../07-performance-analysis.md`. They work on Linux and
macOS (bash + grep + sed); `nothp.c` is Linux-only.

| File | Purpose |
|---|---|
| `runbench.sh BIN LOG [args…]` | Runs `BIN --log-file=LOG args…` (e.g. `--bench=1M`), waits for `benchmark finished`, stops xmrig (it otherwise waits for Ctrl+C) and prints the key lines. |
| `runfor.sh BIN LOG SECONDS [args…]` | Runs `BIN --bench=10M --print-time=30 args…` for SECONDS, then prints the last 10 s hashrate and the last profiler averages (needs a `-DWITH_PROFILING=ON` build for the `profile` lines). |
| `nothp.c` | `LD_PRELOAD` shim that makes `madvise(MADV_HUGEPAGE)` / `madvise(MADV_COLLAPSE)` fail, so that together with `--no-huge-pages` all memory stays on 4 KiB pages (simulates "no huge pages"). Build: `gcc -O2 -shared -fPIC -o nothp.so nothp.c -ldl`. |

Examples:

```bash
./runbench.sh ./xmrig bench_rx0.log --bench=1M
./runbench.sh ./xmrig bench_rx2.log --bench=1M --algo=rx/2
for t in 4 6 8 10; do ./runbench.sh ./xmrig bench_t$t.log --bench=1M -t $t; done
LD_PRELOAD=$PWD/nothp.so ./runfor.sh ./xmrig small_pages.log 75 --no-huge-pages   # Linux
```

Measurement-only builds (dataset/scratchpad windows, CFROUND→NOP) produce invalid hashes;
never point them at a pool.

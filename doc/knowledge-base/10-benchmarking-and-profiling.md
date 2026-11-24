# 10 — Benchmarking and profiling recipes

## Built-in benchmark (offline, deterministic)

```bash
./xmrig --bench=1M                 # rx/0, all auto threads
./xmrig --bench=1M --algo=rx/2     # RandomX v2 (post-FCMP++ Monero)
./xmrig --bench=1M -t 8            # thread-count sweep: repeat for several N
./xmrig --bench=250K --no-huge-pages
```

* Sizes: `250K`, `500K`, `1M` … `10M` (`BenchConfig::getSize`).
* `--bench` also forces `cpu.yield=false`, `cpu.huge-pages-jit=true`, `cpu.priority=2`
  (`ConfigTransform::transformBenchmark`), so it is slightly more optimistic than a
  default mining run.
* The final line prints time, H/s and a **hash sum**; for `rx/0` it is checked against
  `src/backend/common/benchmark/BenchState_test.h` (green = correct). 250K rx/0 sum =
  `7D6054757BB08A63`. A wrong sum means unstable hardware or a broken code change.
* When finished it waits for Ctrl+C. Console output is only written to a TTY or pipe
  (`ConsoleLog::isSupported`); use `--log-file=bench.log` when scripting.
* `--stress` mines a real stress pool job forever (network needed).

Noise: use ≥ 1M hashes, run each configuration 2–3×, same thermal state, on AC power.
On laptops, the first minute is faster than steady state.

## Live numbers

* Key `h` prints per-thread hashrate (10 s/60 s/15 min) — shows P- vs E-core threads.
* HTTP API: `--http-host=127.0.0.1 --http-port=8080` then
  `curl -s localhost:8080/2/summary` (hashrate, results, connection) and
  `curl -s localhost:8080/2/backends` (per-thread).

## Built-in stage profiler (`-DWITH_PROFILING=ON`)

Instrumented scopes (`PROFILE_SCOPE`): `RandomX_hash` (whole hash), `RandomX_run`
(per program), `RandomX_JIT_execute`, `RandomX_JIT_compile` (x86 JIT only),
`RandomX_generate_program`, `RandomX_AES` (scratchpad hash+fill), `RandomX_Blake2b`.
Results are printed with every hashrate report (`--print-time=30`), per thread and averaged.

```bash
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_PROFILING=ON && make -j
./xmrig --bench=10M --print-time=30 --log-file=prof.log   # read "profile" lines
```

**It does not build on arm64 as written**: `ReadTSC()` in `src/crypto/rx/Profiler.h` uses
x86 `rdtsc`. Port for Apple Silicon (generic timer, 24 MHz on Apple ⇒ ~42 ns resolution,
fine for µs-scale scopes):

```cpp
// src/crypto/rx/Profiler.h
static FORCE_INLINE uint64_t ReadTSC()
{
#if defined(__aarch64__)
    uint64_t t;
    __asm__ __volatile__("isb; mrs %0, cntvct_el0" : "=r"(t));
    return t;
#elif defined(_MSC_VER)
    return __rdtsc();
#else
    /* existing rdtsc code */
#endif
}
```

`ProfileScopeData::Init()` (`src/crypto/rx/Profiler.cpp`) calibrates the counter against
`std::chrono::high_resolution_clock` for 1 s, so no other change is needed (it will log
`TSC speed = 0.024 GHz`). Also add `PROFILE_SCOPE(RandomX_JIT_compile)` at the top of
`JitCompilerA64::generateProgram` to see JIT + I-cache-flush cost on the Mac.

## Sampling profilers

* Linux: `perf record -g -p $(pgrep xmrig) -- sleep 20`. JIT code appears as unknown
  addresses in an anonymous executable mapping; that bucket *is* the RandomX loop.
* macOS: Instruments → Time Profiler or CPU Counters, or
  `xctrace record --template 'Time Profiler' --attach <pid> --time-limit 20s`;
  `sample <pid> 10` for a quick text call tree. `sudo powermetrics --samplers
  cpu_power,thermal -i 1000` for cluster frequency/power and throttling.

## Controlled experiments used in this knowledge base (reproducible)

All "measurement-only" builds below produce **invalid hashes** — never mine with them.

| Question | How |
|---|---|
| Cost of small pages (Apple-like) | Linux: `LD_PRELOAD` shim that makes `madvise(MADV_HUGEPAGE=14 / MADV_COLLAPSE=25)` fail, plus `--no-huge-pages`; check `AnonHugePages: 0` in `/proc/meminfo` |
| How much time is DRAM latency for dataset reads | x86: change `RANDOMX_DATASET_BASE_MASK` in `jit_compiler_x86_static.S` (e.g. `0x1FFFFC0` = 32 MiB, `0x3FFC0` = 256 KiB). arm64: the mask is emitted in `JitCompilerA64::generateProgram` from `Log2_DatasetBaseSize` (`randomx_program_aarch64_cacheline_align_mask1/2`); use a smaller log2 there |
| Cost of scratchpad cache misses | In `RandomX_ConfigurationBase` (`randomx.cpp`) set `ScratchpadL3_Size(262144)` or `(1048576)`; compare **JIT execute** only (the AES fill/hash shrinks too) |
| Pure compute floor of the loop | Both of the above (small dataset window + small scratchpad) — measured 75 ns/iteration (v1) vs 121 ns stock |
| Cost of CFROUND (rounding-mode writes) | In `RandomX_ConfigurationBase` (`randomx.cpp`) set `RANDOMX_FREQ_CFROUND(0)` and `RANDOMX_FREQ_NOP(1)` (keeps the 256-entry opcode table size) |
| v1 vs v2 behaviour | `--bench=… --algo=rx/0` vs `--algo=rx/2` |
| Thread scaling / contention | `-t 1`, `-t N`; compare per-thread µs/hash from the profiler |

Helper scripts used here are in [`tools/`](tools/README.md): `runbench.sh` (full benchmark,
auto-stop), `runfor.sh` (timed run + profiler summary) and `nothp.c` (small-pages shim).

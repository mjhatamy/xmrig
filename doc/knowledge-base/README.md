# XMRig knowledge base (v6.27.0)

Deep-dive notes on how this repository works end to end, where the time goes, and what
can (and cannot) make Monero mining faster — with emphasis on running the `xmrig` CMake
target on **Apple Silicon macOS** with:

```
xmrig -o xmr-us-west1.nanopool.org:14433 -u <WALLET> --tls --coin monero
```

Written from a full read of the code paths involved plus measurements taken by building
and benchmarking this exact tree (see `07-performance-analysis.md` for the test machine and
caveats — it was an x86-64 Linux VM, not a Mac).

## Contents

| File | What's in it |
|---|---|
| [01-architecture.md](01-architecture.md) | Threads, module map, ownership graph, interfaces, performance-relevant build options |
| [02-startup-and-config-flow.md](02-startup-and-config-flow.md) | Your command line decoded into config, defaults, config precedence, startup sequence, runtime controls |
| [03-network-stratum-flow.md](03-network-stratum-flow.md) | Stratum login/job/submit, TLS, timeouts, failover, donation, result path |
| [04-mining-pipeline.md](04-mining-pipeline.md) | Job → dataset build → threads → the hash loop → shares; nonce handling; hashrate accounting |
| [05-randomx-internals.md](05-randomx-internals.md) | RandomX as implemented here: memory objects, per-hash algorithm, VM, JIT compilers, xmrig-specific optimisations, **RandomX v2** |
| [06-apple-silicon.md](06-apple-silicon.md) | Everything macOS/arm64-specific: build flags, threads/affinity/priority, no huge pages, W^X JIT, practical knobs |
| [07-performance-analysis.md](07-performance-analysis.md) | Measured stage breakdown and controlled experiments (page size, dataset latency, CFROUND, v1 vs v2, scaling) |
| [08-optimization-opportunities.md](08-optimization-opportunities.md) | Ranked list of things to try (config, code, platform, hardware) with file pointers, plus what not to bother with |
| [09-fpga-asic-gpu.md](09-fpga-asic-gpu.md) | Why FPGA won't help, what the RandomX ASIC changes, GPU numbers |
| [10-benchmarking-and-profiling.md](10-benchmarking-and-profiling.md) | How to measure: `--bench`, API, built-in profiler (and its arm64 port), perf/Instruments, experiment recipes |

## TL;DR

1. **Flow**: `main` → `App` → `Controller` (config from CLI) → `Network` connects
   (DNS → TCP → TLS → stratum `login`) → pool `job` → `Miner::setJob` → `RxQueue` builds
   the 256 MiB cache + 2080 MiB dataset for the job's `seed_hash` → one `CpuWorker` thread
   per core runs `randomx_calculate_hash_next` in a loop → hashes below target go through
   `JobResults` → `Client::submit`.
2. **Where time goes**: ~95 % executing JIT-compiled RandomX programs (8 per hash × 2048
   iterations), ~2 % JIT compile, ~2.6 % AES scratchpad hash/fill, ~0.2 % Blake2b. Network
   and everything else are noise.
3. **What limits it**: memory-system latency chains inside each loop iteration (page-table
   walks on the 2 GiB dataset, the dependent dataset/scratchpad loads). Measured: a v1
   iteration is 75 ns of compute + 45 ns of stall (37 %); small pages cost −20 % hashrate;
   RandomX v2 does 1.5× the work per hash yet ran ~6 % faster than v1 because its 2-ahead
   dataset prefetch removes most of the stall.
4. **On a Mac**: no huge pages, no affinity, no MSR mod, no SMT — and xmrig starts one
   thread per core including E-cores. The free wins are thread-count tuning, thermals,
   no sleep, no memory pressure. Code-level, start by porting the profiler to arm64 and
   try the targeted JIT/QoS experiments in `08`.
5. **FPGA**: not viable (per-hash 2 MiB scratchpad SRAM, FP64 with rounding modes, random
   programs, dependent DRAM reads) — expect far below a CPU. **GPU**: 5–20× worse H/J than
   CPUs. **ASIC**: exists (Antminer X5, ~212 kH/s @ 1.35 kW); check RandomX v2 support.
6. **Monero's FCMP++ fork** switches to RandomX v2 (`rx/2`) automatically when the blob
   version reaches 17 — already implemented in this tree.

## Glossary

| Term | Meaning |
|---|---|
| Seed / key | `seed_hash` from the pool; changes every 2048 blocks; defines cache + dataset |
| Cache | 256 MiB Argon2d output used to build the dataset (and by light mode) |
| Dataset | 2080 MiB read-only table, random 64 B reads during hashing (fast mode) |
| Scratchpad | 2 MiB per-thread read/write memory (L1 16 KiB / L2 256 KiB / L3 2 MiB windows) |
| Program | 256 (v1) / 384 (v2) random VM instructions, regenerated 8× per hash |
| Iteration | one pass over the program; 2048 per program, 16,384 per hash |
| Superscalar hash | small random integer programs used to compute dataset items |
| Fast / light mode | dataset in RAM / computed on the fly from the cache |
| MSR mod | x86 model-specific register tweaks (prefetchers) for +~15 % |
| P / E cores | Apple performance / efficiency cores |
| Nicehash mode | pool fixes the top nonce byte; miner iterates the low 24 bits |

Key source entry points: `src/xmrig.cpp`, `src/core/Miner.cpp`, `src/net/Network.cpp`,
`src/base/net/stratum/Client.cpp`, `src/backend/cpu/CpuWorker.cpp`,
`src/crypto/rx/Rx.cpp`, `src/crypto/randomx/randomx.cpp`,
`src/crypto/randomx/jit_compiler_a64.cpp` + `jit_compiler_a64_static.S` (Apple path).

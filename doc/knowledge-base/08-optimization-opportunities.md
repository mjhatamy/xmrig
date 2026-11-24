# 08 — Optimization opportunities (ranked)

Ground rules from the measurements (`07-performance-analysis.md`):
* ≥ 95 % of every hash is the JIT-compiled RandomX loop. Work outside it (Blake2b,
  program generation, AES fill/hash, networking) is ≤ 5 % combined.
* Compiler and compiler flags do not move the needle (GCC vs Clang: 1967 vs 1952 H/s).
* The loop is bounded by memory-system latency chains (page walks, scratchpad/dataset
  loads): **37 % of each v1 iteration is stall** (75 ns compute of 121 ns). RandomX v2 does
  1.5× the work per hash yet ran ~6 % *faster* than v1 here because its 2-ahead prefetch
  removes the dataset stall. On Apple P-cores (scratchpad L2-resident) the dataset stall
  is the one that remains for v1 — so the levers are memory-latency levers.
* Measure every change with `--bench=1M` (2–3 runs) and check the hash sum.

Legend: **Gain** = expected hashrate effect on Apple Silicon, **Conf.** = confidence.

## A. No code changes (do these first)

| # | Action | Gain | Conf. | Notes |
|---|---|---|---|---|
| A1 | Sweep thread count: `--bench=1M -t P`, `-t P+2`, `-t P+E` (P/E = performance/efficiency core counts) and keep the best via `-t N` | 0–15 % | medium | Default uses **all** cores (`HwlocCpuInfo::allThreads`, `BasicCpuInfo_arm.cpp:52`). E-core threads have ~1 MiB of L2 each on M1-class E-clusters vs 2 MiB needed. `sysctl hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu` gives P/E counts. |
| A2 | Thermal/power headroom: AC power, good airflow; avoid fanless sustained throttling | 0–30 % | medium | Check `sudo powermetrics --samplers cpu_power,thermal`. Mac mini/Studio rarely throttle; MacBook Air does. |
| A3 | Prevent sleep while mining: `caffeinate -i ./xmrig …` | avoids 100 % loss when idle sleep kicks in | high | CLI processes don't get App Nap, but system sleep stops mining. |
| A4 | Avoid memory pressure (≥ 3 GB free) | avoids catastrophic drops | high | On macOS arm64 the 2 GiB dataset is ordinary pageable memory (no huge pages ⇒ no `mlock`, see `VirtualMemory.cpp:77` fallback); under pressure it can be compressed or swapped. Watch Activity Monitor ▸ Memory Pressure. |
| A5 | `--cpu-no-yield` | < 0.1 % | high | Removes one `sched_yield()` per hash (`CpuWorker.cpp:385`). |
| A6 | Donation 1 % → 0 % | +1 % earnings | high | Only by editing `src/donate.h:40-41` (README says it may be disabled in source). |
| A7 | Nearest pool region | stale-share rate only | high | No hashrate effect. |
| A8 | After the FCMP++ fork Monero uses `rx/2` automatically | — | high | Don't compare v1/v2 hashrates as "better/worse"; difficulty rescales. |

## B. Code changes worth trying on Apple Silicon (measure first)

| # | Change | Where | Gain | Effort | Conf. |
|---|---|---|---|---|---|
| B1 | **Port the stage profiler to arm64** (`cntvct_el0`), add a JIT-compile scope to the A64 JIT | `src/crypto/rx/Profiler.h:48`, `jit_compiler_a64.cpp:120` | enables everything below | 15 min | high |
| B2 | Set an explicit QoS class on worker threads (`pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)`; optional mode: P-threads USER_INITIATED + E-threads `QOS_CLASS_BACKGROUND` for deterministic placement) | `Platform_mac.cpp:69` (`setThreadPriority`) or `Worker::Worker` (`Worker.cpp:25`) | 0–5 %, mostly stability | small | low–medium |
| B3 | P/E- and L2-aware auto-config on macOS (`hw.nperflevels`, `hw.perflevelN.logicalcpu`, `hw.perflevelN.l2cachesize`), and honour `--cpu-max-threads-hint` on ARM (currently ignored) | `BasicCpuInfo_arm_mac.cpp`, `HwlocCpuInfo.cpp:258` | better defaults (= A1 automatically) | medium | high |
| B4 | `mlock()` the dataset/scratchpads when huge pages are unavailable (respect `vm.user_wire_limit`) | `VirtualMemory::VirtualMemory` fallback (`VirtualMemory.cpp:77`) | stability under pressure | small | medium |
| B5 | Measure FPCR-write cost (v1 CFROUND): build with `RANDOMX_FREQ_CFROUND(0)`/`RANDOMX_FREQ_NOP(1)`; if it is large, emit "skip `msr fpcr` when the mode is unchanged" (x8 already mirrors FPCR) | `jit_compiler_a64.cpp:1173` | 0–? % (v1 only) | small | low (on x86 the same test showed **0 %**) |
| B6 | Dataset prefetch/load variants for M1–M3: `prfm pldl1strm` vs `pldl1keep`/`pldl2keep`, `ldnp` vs `ldp` (#3820 tuned this on M4: ~8 %) | `jit_compiler_a64_static.S:306-321` | 0–8 % | small | medium |
| B7 | Scratchpad prefetch in the ARM64 loop (x86 has `randomx_prefetch_scratchpad`, ARM64 has none): `prfm` the next spAddr0/spAddr1 lines as soon as spMix is known | `jit_compiler_a64_static.S` main-loop epilogue | 0–3 % | small | low (scratchpad is L2-resident on P-cores) |
| B8 | Two hashes in flight per thread ("software SMT"): interleave the iterations of two VMs so one VM's dataset/scratchpad latency overlaps the other's compute | A64 JIT + `CpuWorker` (`N=2` for RandomX) | ceiling ≈ stall share: up to ~1.6× per thread for v1 on the x86 test box (37 % stall), much less for v2 (17 %); real gain lower | **very high** (register pressure: 2×(8 int + 12 vector) regs; 2× scratchpad footprint = 4 MiB/core, fits M2–M4 P-clusters only) | low–medium |

Rejected after analysis (don't spend time here):
* *Early dataset prefetch* (issue the prefetch right after the last write to
  readReg2/readReg3 inside the program): that write is on average only ~7 instructions
  before the end of a 256-instruction program, so the gain is a few ns.
* *NEON Blake2b / Argon2*: Blake2b is 0.2 % of hash time; Argon2 runs once per seed.
* *Compiler flags* (`-mcpu=apple-mN`, LTO, PGO): only touch the ≤ 5 % of C++ in the hot
  path.
* *Light mode*, *more threads than cores* (no SMT on Apple), *network/TLS tweaks*.
* *FPGA / GPU*: see `09-fpga-asic-gpu.md`.

## C. Platform-level

| # | Option | Gain | Conf. |
|---|---|---|---|
| C1 | Linux on Apple Silicon (Asahi; M1/M2 families) to get huge pages for the dataset (xmrig's Linux path uses hugetlbfs / `MADV_HUGEPAGE` / `MADV_COLLAPSE`, `VirtualMemory_unix.cpp`) and `perf` | unknown; on x86 here 4 KiB→2 MiB pages was +25 %, Apple already starts at 16 KiB pages so expect less | low–medium (untested) |
| C2 | Mine on x86 Linux boxes too: 2 MiB/1 GiB huge pages, MSR mod (`--randomx-wrmsr`, root; `scripts/randomx_boost.sh`), SMT | large per box (Ryzen 9000 ≈ 20–27 kH/s) | high |

## D. Hardware

ASIC (Antminer X5, ~212 kH/s @ 1.35 kW) is the only thing that beats CPUs per box; FPGAs
and GPUs do not. Details: `09-fpga-asic-gpu.md`.

## Suggested order of work

1. A1–A4 on the Mac (an afternoon, no code).
2. B1 (profiler port) → get the real Apple breakdown (JIT execute vs compile vs AES), then
   the E4/E5-style arm64 measurement builds (`07`, "Open questions") → the Mac's compute
   floor and dataset stall per iteration = the ceiling for B6/B8/C1.
3. B5/B6/B7 quick JIT experiments guided by B1; B2/B3 for robust defaults.
4. Only if the Apple profile shows the loop is latency-bound and you have weeks: B8.
5. For more total hashrate, add x86 Linux machines (C2) rather than exotic hardware.

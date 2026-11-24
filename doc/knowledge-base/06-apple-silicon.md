# 06 — Apple Silicon / macOS specifics

Everything below is what the code does on `XMRIG_OS_MACOS` + `XMRIG_ARM=8` (arm64).

## Build

* `cmake/cpu.cmake`: `CMAKE_OSX_ARCHITECTURES` (if `x86_64` or `arm64`) overrides
  `CMAKE_SYSTEM_PROCESSOR`; arm64 ⇒ `ARM_TARGET=8`, `XMRIG_ARM=8`.
  Compiler flags: `-march=armv8-a+crypto` for M1–M3; **`-mcpu=native` + `-DXMRIG_ARM_V9`
  only if the *build machine* reports `Apple M4` or newer** (`sysctl machdep.cpu.brand_string`).
  A compile test sets `XMRIG_ARM_CRYPTO` when `vaeseq_u8` compiles (hardware AES intrinsics).
* `cmake/os.cmake`: `XMRIG_OS_APPLE` + `XMRIG_OS_MACOS`; **`WITH_SECURE_JIT` forced ON**.
* Linked: IOKit, CoreServices (battery/idle detection), static OpenSSL, libuv, optional hwloc.
* Not built on macOS: MSR mod (`WITH_MSR` is x86 Linux/Windows only), 1 GiB pages,
  `RxFix`, x86 JIT/asm, AVX2/SSE4.1 Blake2b, VAES.
* **Do not run an x86_64 build under Rosetta 2**: the x86 RandomX JIT writes x86 code at
  run time that Rosetta must translate again and again. Check the banner:
  `ABOUT  XMRig/6.27.0 clang/… (built for macOS ARMv8, 64 bit)` (printed by
  `BaseConfig.cpp` from `APP_OS`/`APP_ARCH` in `src/version.h`) and `file ./xmrig` ⇒ `arm64`.
* Compiler flags barely matter for hashrate (>95 % of time is in JIT-emitted code; GCC vs
  Clang builds measured identical within noise on x86). `-mcpu=apple-mN` would only
  affect the ≤5 % of C++ code (AES fill/hash, Blake2b, JIT emitter).

## CPU detection & thread auto-config

* `BasicCpuInfo_arm_mac.cpp`: AES from `sysctl hw.optional.arm.FEAT_AES`, brand from
  `machdep.cpu.brand_string`; M4/M5 get an "(ARMv9)" suffix.
* Thread count for RandomX = **one thread per logical CPU, P- and E-cores alike**:
  `HwlocCpuInfo::allThreads()` (with hwloc) or `BasicCpuInfo::threads()` (without). Cache
  sizes are not considered and `--cpu-max-threads-hint` is **ignored on ARM**. Use `-t N`
  or an explicit `"rx": [-1, -1, …]` list in `config.json` to choose.
* **Affinity is a no-op**: `Platform::setThreadAffinity()` returns `true` without doing
  anything (`src/base/kernel/Platform_mac.cpp`); when a thread has an affinity (hwloc
  auto-config assigns one per PU) `Thread::start` sets a Mach `THREAD_AFFINITY_POLICY` tag,
  which is only a grouping hint and is not supported on Apple Silicon. macOS decides where
  each thread runs and threads migrate between P- and E-clusters.
* **Priority**: `--cpu-priority N` → `setpriority(PRIO_PROCESS, 0, nice)` (N=0→19, 1→5,
  2→0, 3→−5, 4→−10, 5→−15) — this changes the *process* nice value, not one thread.
  Default `-1` leaves it alone. No QoS class is set anywhere; worker threads run at the
  default QoS, which makes them eligible for P-cores (Background QoS would pin them to
  E-cores).

Why P vs E matters for RandomX: each thread needs a 2 MiB scratchpad that stays in cache.
P-clusters have a large shared L2 (12–16 MiB per cluster depending on generation) — enough
for one scratchpad per P-core. E-clusters have a much smaller shared L2 (e.g. 4 MiB on M1
for 4 E-cores), so E-core threads spill to the SLC/DRAM, run several times slower, and add
memory-system pressure. Whether adding E-core threads is a net gain is chip-dependent:
**measure `-t P`, `-t P+2`, `-t P+E` with `--bench=1M`** (see `10-benchmarking-and-profiling.md`).

## Memory: no huge pages on macOS arm64

* `VirtualMemory::isHugepagesAvailable()` returns `false` on macOS arm64 (banner:
  `HUGE PAGES unavailable`). `allocateLargePagesMemory()` tries
  `mmap(…, VM_FLAGS_SUPERPAGE_SIZE_2MB)`, but user-space superpages are an x86_64-only
  XNU feature (which is why xmrig reports them unavailable on arm64), so the dataset ends
  up on the normal page size.
* Apple Silicon's base page is **16 KiB** (4× x86's 4 KiB), so the 2080 MiB dataset is
  ~133 k pages. Each dataset access is effectively random over 2 GiB, far beyond any TLB
  reach, so nearly every one pays a page-table walk on top of DRAM latency.
* How much this costs, measured on x86 here (rx/0): 4 KiB pages −20 % hashrate vs 2 MiB
  pages, all of it inside the JIT loop (247 → 302 µs per program). With 16 KiB pages the
  penalty should be smaller but present; it cannot be removed under macOS.
* Only way out on the same hardware: **Linux on Apple Silicon (Asahi, M1/M2 families)**,
  where xmrig's Linux path uses hugetlbfs or `madvise(MADV_HUGEPAGE/MADV_COLLAPSE)` on the
  dataset (`VirtualMemory::adviseLargePages`). Untested here — treat as a hypothesis to
  measure.

## JIT on macOS arm64 (W^X)

* JIT buffers: `mmap(PROT_READ|WRITE|EXEC, MAP_PRIVATE|MAP_ANON|MAP_JIT)`
  (`VirtualMemory::allocateExecutableMemory`).
* Per program (8× per hash): `enableWriting()` → `pthread_jit_write_protect_np(false)`;
  emit code; `getProgramFunc()` → `enableExecution()` → `pthread_jit_write_protect_np(true)` +
  `sys_icache_invalidate()` over the emitted range (`jit_compiler_a64.cpp`).
  The toggle is a cheap per-thread register switch; the I-cache maintenance is the
  larger cost. JIT compile is ~2 % of hash time on x86 here; on arm64 it is unmeasured
  (the built-in profiler uses `rdtsc` and does not build on arm64 — see
  `08-optimization-opportunities.md` for a port).
* If you codesign with the Hardened Runtime you must add the
  `com.apple.security.cs.allow-jit` entitlement, otherwise `MAP_JIT` fails. A plain CMake
  build (ad-hoc linker signature) works.
* The dataset-init SuperscalarHash is JIT-compiled on arm64 too
  (`generateSuperscalarHash`), and hardware AES (`aese/aesmc` fused pairs) is used for the
  scratchpad, program generation and RandomX v2 FE mix.

## Things that exist on other platforms but not here

| Feature | Linux/Windows x86 gain | macOS arm64 |
|---|---|---|
| 2 MiB huge pages | +25 % measured here (rx/0, 4 vCPUs) | unavailable |
| 1 GiB pages | +1–3 % (docs) | unavailable |
| MSR mod | up to +15 % (docs) | N/A (x86 MSRs) |
| SMT (2 threads/core hide DRAM stalls) | significant on many x86 CPUs | Apple cores have no SMT |
| Thread affinity / NUMA | used | no-op / single NUMA node |

## Reference hashrates (rx/0) to compare your own `--bench=1M` against

| Chip | H/s | Source (quality) |
|---|---|---|
| M1 | ~2,000 @ ~35 W | Kryptex pool device page (estimate, settings unknown) |
| M2 (MacBook Air) | 2,084–2,577 | OpenBenchmarking.org, xmrig 6.18.1, 1M hashes (measured, fanless) |
| M2 | ~2,890 @ ~20 W | Kryptex (estimate) |
| M4 Pro | ~6,820 @ ~46 W | Kryptex (estimate) |

For comparison, this tree on 4 vCPUs of a 2.1 GHz Xeon VM: 1,956 H/s (rx/0, 2 MiB pages).

## Practical knobs on a Mac (no code changes)

* Build native arm64 Release; confirm `HUGE PAGES unavailable`, `READY threads N/N`.
* Benchmark thread counts (`--bench=1M -t N`), keep the best; set it with `-t N`.
* `--randomx-mode=fast` (auto already picks fast with ≥ ~2.4 GB free).
* `--cpu-no-yield` (removes one `sched_yield` per hash; tiny).
* Keep it on AC power and cool: fanless machines throttle under sustained all-core
  load. `--pause-on-battery` if it's a laptop you carry. Check with
  `sudo powermetrics --samplers cpu_power,thermal`.
* Close other heavy apps: anything that evicts the P-cluster L2 lowers hashrate.
* Once Monero forks to RandomX v2 (blob v17) expect a different (likely better relative)
  picture: on the x86 test box the v2 prefetch cut the exposed dataset stall from 28 ns to
  3 ns per iteration once the scratchpad was cache-resident — the situation Apple P-cores
  are always in — so v1-on-Mac is probably dataset-latency-bound and v2 should help.

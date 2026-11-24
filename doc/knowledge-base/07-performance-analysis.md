# 07 — Performance analysis (measured on this tree)

## Test setup and caveats

* Machine: cloud KVM guest, Intel Xeon (family 6 model 207, Sapphire/Emerald-Rapids
  class), **4 vCPUs**, TSC 2.1 GHz, 2 MiB L2 per core, large shared L3, 15.7 GB RAM,
  1280 × 2 MiB huge pages configured. No hardware PMU counters in the guest (perf
  `cycles`/`instructions` unsupported), so explanations below are inferred from
  controlled A/B experiments, not counters.
* Builds: GCC 13.3 (`RelWithDebInfo`) and Clang 18.1 (`Release`, `-DWITH_PROFILING=ON`),
  CPU backend only. Measurement-only variants are described per experiment.
* Method: full `--bench=250K` runs (≈2 min, hash sum verified) or 75 s timed runs
  (10 s hashrate window + profiler averages, per thread).
* This is **not an Apple machine**. VMs make TLB misses costlier (two-level page walks)
  and have noisy neighbours (run-to-run spread here ≈ ±1.5–2 %). Use the *structure* of
  the results, then re-measure on the Mac with the recipes in `10-benchmarking-and-profiling.md`.

## Results

| ID | Build | Algo | Pages | Variant | Thr | H/s | JIT exec / program | Hash / thread |
|---|---|---|---|---|---|---|---|---|
| A | GCC | rx/0 | 2 MiB | stock | 4 | **1967** (250K, sum ✓) | – | – |
| B | GCC | rx/0 | 4 KiB | stock (THP blocked) | 4 | **1572** (250K, sum ✓) | – | – |
| P1 | Clang+prof | rx/0 | 2 MiB | stock | 4 | 1952 (250K, sum ✓) | 247.0 µs | 2081 µs |
| R | Clang+prof | rx/0 | 2 MiB | stock, repeats | 4 | 1923, 1982 (250K, sum ✓) | – | – |
| P3 | Clang+prof | rx/2 | 2 MiB | stock | 4 | 2050 (10 s) | 230.4 µs | 1966 µs |
| R2 | Clang+prof | rx/2 | 2 MiB | stock, repeats | 4 | **2032, 2118** (250K, sum ✓) | – | – |
| P2 | Clang+prof | rx/0 | 4 KiB | stock | 4 | 1597 (10 s) | 301.7 µs | 2521 µs |
| P4 | Clang+prof | rx/2 | 4 KiB | stock | 4 | 1765 (10 s) | 268.7 µs | 2271 µs |
| T1 | Clang+prof | rx/0 | 2 MiB | stock | **1** | 467 (10 s) | 251.0 µs | 2113 µs |
| E1 | measurement-only | rx/0 | 2 MiB | dataset window 32 MiB (L3-resident) | 4 | 1916 (10 s) | 257.5 µs | 2174 µs |
| E2 | measurement-only | rx/0 | 2 MiB | dataset window 256 KiB (L2-resident) | 4 | 1995 (10 s) | 233.6 µs | 1972 µs |
| E3 | measurement-only | rx/0 | 2 MiB | CFROUND → NOP | 4 | 1947 (10 s) | 248.5 µs | 2094 µs |
| E3b | measurement-only | rx/2 | 2 MiB | CFROUND → NOP | 4 | 2107 (10 s) | 223.5 µs | 1908 µs |
| L1 | Clang+prof | rx/0 | 2 MiB | `--randomx-mode=light` | 4 | 213 (10 s) | 2,328 µs | 18,744 µs |

Scratchpad- and dataset-window variants (E4, E4b, E5, E5b) are in the next section.

Hash sums: rx/0 250K = `7D6054757BB08A63`, rx/2 250K = `18CF741A71484072` — both equal to
the references in `src/backend/common/benchmark/BenchState_test.h`.

## Findings

1. **Where the time goes** (P1, per hash per thread, 2.08 ms): JIT program execution
   95.0 %, JIT compile 2.1 % (8 × 5.6 µs), scratchpad AES hash+fill 2.6 % (53 µs),
   program generation 0.1 %, Blake2b 0.2 %. In v2 (P3): JIT compile 7.9 µs/program,
   generation 0.31 µs/program, execution 230 µs/program.
2. **Compiler choice is irrelevant**: GCC 1967 vs Clang 1952/1923/1982 H/s.
3. **Page size matters a lot**: 4 KiB pages cost **−20 %** (A→B) and the entire loss is
   inside JIT execution (247 → 302 µs/program, +22 %); RandomX v2 suffers less (+17 %),
   consistent with its deeper dataset prefetch hiding part of the page-walk latency.
4. **With huge pages, dataset DRAM latency is mostly hidden on this CPU**: making the
   dataset L3-resident (E1, 32 MiB window) gave nothing; making it L2-resident (E2,
   256 KiB) gave only −5 % execution time. The 1-iteration-ahead prefetch already covers
   most of the DRAM latency here because one iteration (~120 ns) is about as long as a
   DRAM access.
5. **CFROUND/MXCSR writes are not a bottleneck on this Intel core** (E3: 248.5 vs 247.0 µs).
6. **Threads scale linearly**: 1 thread 251 µs/program vs 4 threads 247 µs — no
   bandwidth/LLC contention at 4 threads; per-thread speed is a latency/core property.
7. **RandomX v2 is *faster* than v1 here** — mean 2075 H/s vs 1956 H/s (+6 %) while doing
   ~1.5× the work per hash (6.29 M vs 4.19 M VM instructions, 2× the AES). Per iteration:
   v1 256 instructions in ~120 ns, v2 384 instructions + 16 AES in ~112 ns. So v1's loop
   leaves a large part of the core idle; neither CFROUND (E3) nor dataset latency alone
   (E2) explains it — the combined-window experiments below do (findings 9–10).

### Scratchpad and combined-window experiments

Measurement-only builds that shrink `ScratchpadL3_Size` (the window used by the
per-iteration 64 B reads/writes and L3 `ISTORE`s; the AES fill/hash shrinks with it, so
compare **JIT execute** only):

| ID | Algo | Variant | H/s (10 s) | JIT exec / program | per iteration |
|---|---|---|---|---|---|
| P1 | rx/0 | stock (2 MiB scratchpad) | 1952 | 247.0 µs | 120.6 ns |
| E4 | rx/0 | scratchpad window 1 MiB | 2250 | 213.8 µs | 104.4 ns |
| E4 | rx/0 | scratchpad window 256 KiB | 2306 | 210.6 µs | 102.8 ns |
| P3 | rx/2 | stock | 2050 | 230.4 µs | 112.5 ns |
| E4b | rx/2 | scratchpad window 256 KiB | 2356 | 198.2 µs | 96.8 ns |
| E2 | rx/0 | dataset window 256 KiB (scratchpad stock) | 1995 | 233.6 µs | 114.1 ns |
| **E5** | rx/0 | dataset 256 KiB **and** scratchpad 256 KiB (≈ no memory stalls) | 3067 | **154.3 µs** | **75.3 ns** |
| **E5b** | rx/2 | dataset 256 KiB **and** scratchpad 256 KiB | 2488 | **192.4 µs** | **93.9 ns** |

8. **The 2 MiB scratchpad not fitting in this CPU's 2 MiB L2 costs ~14 %** of loop time
   (1 MiB and 256 KiB windows give nearly the same gain, so it is a capacity effect: the
   scratchpad plus code, stack and dataset lines exceed L2 and some scratchpad reads go
   to L3). On Apple P-cores the shared L2 is 12–16 MiB per cluster, so this particular
   loss should be absent there.
9. **37 % of every v1 iteration is memory stall.** Pure compute (E5) is 75 ns per
   iteration vs 121 ns stock. The two stall sources overlap: removing only the dataset
   latency saves 7 ns (E2), only the scratchpad misses 18 ns (E4), both 45 ns (E5) — each
   hides behind the other.
10. **RandomX v2's 2-ahead prefetch removes the dataset stall.** With the scratchpad
    cache-resident, the exposed dataset stall is **28 ns/iteration in v1** (E4 − E5) but
    only **3 ns in v2** (E4b − E5b). v2's extra work costs only +25 % compute per iteration
    (94 vs 75 ns for +50 % instructions + 16 AES) and is absorbed by the time v1 spent
    stalled — hence v2 ≥ v1 in H/s.

## Model of one iteration (why "more work" can be free)

Loop-carried dependencies per iteration (spec order):

```
r ^= DATASET[ma]          (prefetched 1 iteration earlier in v1, 2 in v2)
spMix = r[readReg0] ^ r[readReg1]           -> next spAddr0/spAddr1
r ^= SP[spAddr0] (64 B), f/e <- SP[spAddr1] (64 B)   random within 2 MiB
256/384 program instructions (int chains feed mx and spMix; FP chains mostly don't)
mx ^= r[readReg2] ^ r[readReg3]; prefetch DATASET[mx]
```

Every iteration must wait for (a) the dataset line chosen one iteration earlier (v1),
(b) a random scratchpad line whose address depends on that dataset line, and (c) the
integer dependency chains of the program. Out-of-order cores overlap the FP work and
independent instructions with these waits, which is why the extra v2 instructions cost
little.

Measured decomposition on this machine (ns per iteration):

| | v1 (rx/0) | v2 (rx/2) |
|---|---|---|
| Pure compute (E5/E5b) | 75 | 94 |
| + dataset latency only (scratchpad resident: E4/E4b) | 103 (+28) | 97 (+3) |
| + scratchpad L2 misses only (dataset resident: E2) | 114 (+39) | – |
| Stock (both) | 121 (+45 = 37 % stall) | 112 (+19 = 17 % stall) |

Implications:

* **Per-thread hashrate is ~37 % below what the core could compute** (v1); the upper bound
  of any latency-hiding scheme here is ≈ 1.6× per thread.
* Anything that shortens (a) or (b) — huge pages, lower DRAM/L2 latency, keeping the
  scratchpad resident in the nearest large cache — speeds up v1 more than raw core speed.
* A core without SMT (Apple) cannot fill those waits with a second thread; x86 SMT can.
  The software equivalent is two interleaved VMs per thread (B8 in `08`).
* Hiding (a) with deeper prefetch is exactly what RandomX v2 did — and it worked: v2's
  dataset stall is 3 ns vs 28 ns.

## What transfers to Apple Silicon, and what doesn't

| Finding | Transfers? |
|---|---|
| ~95 % in the JIT loop; flags/compiler irrelevant; Blake2b/AES/program-gen small | Yes (same algorithm, same structure in the A64 JIT) |
| Small pages hurt (TLB/page walks on 2 GiB) | Yes in direction; macOS uses 16 KiB pages (between 4 KiB and 2 MiB), and huge pages are unavailable |
| Dataset stall ≈ 28 ns/iteration in v1 once the scratchpad is cache-resident | **Most relevant to Apple**: P-cores keep the scratchpad in L2 (the E4 situation), Apple cores compute faster and LPDDR + 16 KiB-page walks are slower, so v1 on a Mac is likely *dataset-latency-bound* (consistent with the +8 % #3820 got on M4 from dataset prefetch/NT-load changes). Verify with the E2/E5-style arm64 build. |
| Scratchpad L2-miss stall (~14 %) | Probably absent on P-cores: P-cluster L2 (12–16 MiB) holds the 2 MiB scratchpads of all P-cores; present on E-cores |
| CFROUND cost ≈ 0 | Unknown: depends on the cost of `msr fpcr` on Apple cores (test E3 on the Mac) |
| v2 ≥ v1 hashrate | Likely similar or better on Apple for the same reasons; measure with `--algo=rx/2` |
| Linear thread scaling | Only within the P-cluster; E-cores are a separate, slower regime |

## Open questions to answer on the Mac (cheap, in this order)

1. `--bench=1M` for `-t P`, `-t P+E` (and steps between) — best thread count.
2. Profiler port (B1 in `08`) → Apple breakdown: execute vs compile (+ I-cache flush) vs AES.
3. `--algo=rx/2` vs `rx/0` — is the Mac latency-bound in v1 (v2 relatively faster)?
4. E5-style build on arm64 (small dataset window via `Log2_DatasetBaseSize` in
   `JitCompilerA64::generateProgram`, plus `ScratchpadL3_Size(262144)`) vs E4-style
   (scratchpad only) — gives the Mac's compute floor and its dataset stall per iteration.
   That number is the ceiling for B6/B8/C1 in `08`.
5. E3-style CFROUND → NOP on arm64 — is `msr fpcr` expensive?

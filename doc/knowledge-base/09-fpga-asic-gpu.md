# 09 — FPGA, ASIC and GPU: can hardware acceleration speed this up?

Short answer: **an FPGA will not beat your Mac or a desktop CPU on RandomX, a GPU is
5–20× less energy-efficient than a CPU, and the only hardware that beats CPUs is a
dedicated ASIC (Bitmain Antminer X5).** Details and numbers below.

## Why RandomX resists FPGAs (from the algorithm, not just the docs)

RandomX was designed so that the best "hardware" is a general-purpose out-of-order CPU
(tevador/RandomX `doc/design.md`). Concretely, per hash (v1):

| Requirement | Why it hurts an FPGA |
|---|---|
| 8 new random programs per hash (256 instr; 384 in v2), each run 2048× | Bitstreams can't be reconfigured per program (seconds to load), so you must build a **soft VM/CPU** that interprets them. Soft cores run at ~200–500 MHz with little ILP vs 3–5 GHz 8-wide OoO cores. |
| 64-bit IEEE-754 double add/sub/mul/div/sqrt with 4 rounding modes, 128-bit SIMD | Full FP64 with dynamic rounding is DSP-heavy and deeply pipelined in fabric; FDIV/FSQRT are worse. |
| 64×64→128 multiplies (IMULH/ISMULH), rotates, branches (CBRANCH), reciprocal multiply | Each needs dedicated datapaths; branches break simple pipelining. |
| 2 MiB scratchpad **per hash in flight**, ~40 random scratchpad accesses + 2×64 B loads + 2×64 B stores per iteration | On-chip SRAM is the binding limit: even the largest FPGAs have only tens of MB of BRAM+UltraRAM (e.g. ~57 MB on a Virtex UltraScale+ VU13P), i.e. at most ~25 scratchpads, each needing several random ports per cycle. Putting scratchpads in DDR/HBM adds ~100 ns to dozens of accesses per iteration. |
| 16,384 **dependent** random 64 B reads from a 2 GiB dataset per hash | Iteration *i+1* cannot start until the dataset line of iteration *i* arrives. With FPGA DDR/HBM latency (~100–200 ns), one VM instance is capped at roughly 16,384 × latency ≈ 2–3 ms per hash ⇒ **≤ 300–500 H/s per instance even with zero compute time**. |
| Cache init (Argon2d 256 MiB) + dataset (2 GiB of SuperscalarHash) every ~2.8 days | Needs a CPU anyway (or more fabric); the hobby FPGA project skips it and uploads the dataset. |

Back-of-envelope: a soft in-order VM at 300 MHz executing ~1 VM instruction/cycle needs
~0.85 µs per iteration (256 instructions) vs ~0.04–0.12 µs on a CPU core, so ~14 ms per
hash ≈ 70 H/s per VM instance. Matching a Ryzen 9 9950X (≈27 kH/s) would need ~400
instances ⇒ ~800 MiB of scratchpad SRAM, >10× more than any FPGA has. Matching one Apple
P-core (~0.4–0.7 kH/s) would already need ~6–10 instances on a multi-thousand-dollar card.

Evidence: the RandomX README states FPGAs can only run it as a soft microprocessor and
will be much less efficient than a CPU; there is **no published, benchmarked FPGA
RandomX miner** (the community VHDL project MainSilent/RandomX-FPGA implements only the VM
instruction set; an NTHU feasibility study did not get it running).

**Verdict:** do not invest in FPGA for RandomX. It is a multi-person-year effort with an
expected result far below a commodity CPU in H/s, H/J and H/$.

## ASIC: it exists now

Kryptex (a pool, i.e. a commercially interested source; no independent benchmark found)
lists the **Bitmain Antminer X5**, described as the first professional RandomX ASIC for
Monero (article dated 19 May 2026): **~212 kH/s at ~1350 W ≈ 157 H/J**.

How that compares (CPU numbers from SChernykh's RandomX v2 testing gist, measured with
large pages + MSR mod; Apple numbers are Kryptex estimates):

| Device | RandomX v1 H/s | Power | H/J |
|---|---|---|---|
| Antminer X5 (Kryptex) | ~212,000 | 1350 W | ~157 |
| Ryzen 9 9950X @ 285 W | 27,186 | 285 W | 95 |
| Ryzen 9 9950X @ 100 W | 19,912 | 100 W | 199 |
| Ryzen 9 7945HX @ 62 W | 19,715 | 62 W | 318 |
| Ryzen AI 9 365 @ 28 W | 7,740 | 28 W | 276 |
| Apple M4 Pro (Kryptex est.) | ~6,820 | 46 W | ~148 |
| Apple M2 (Kryptex est.) | ~2,890 | 20 W | ~145 |
| Apple M1 (Kryptex est.) | ~2,000 | 35 W | ~57 |
| RTX 3080 LHR (minerstat est.) | ~1,560 | 90 W | ~17 |

Takeaways: the X5 wins on hashes per box and per dollar, not clearly on hashes per joule
against power-tuned modern CPUs. Unknown: whether it supports **RandomX v2** (`rx/2`), which
Monero activates with the FCMP++ fork and which xmrig already supports — check before
buying anything specialised.

## GPU

* xmrig's OpenCL backend has RandomX for AMD: a per-program JIT to GCN/RDNA machine code
  for gfx803/gfx900/gfx1010 (`src/backend/opencl/runners/OclRxJitRunner.cpp`,
  `cl/rx/randomx_run_gfx*.asm`) and a generic interpreter VM (`OclRxVmRunner`,
  `cl/rx/randomx_vm.cl`). NVIDIA goes through the external CUDA plugin.
* GPUs suffer from the same per-hash 2 MiB scratchpad and dependent dataset reads, plus
  divergence on branches and weak FP64 on consumer cards. Estimates: ~1.5–1.7 kH/s for an
  RTX 3080-class card at ~90–120 W (≈15–17 H/J) — roughly one laptop CPU's hashrate at
  10× worse efficiency.
* Apple GPUs: no Metal backend exists; OpenCL on macOS is deprecated (OpenCL 1.2) while
  xmrig targets OpenCL 2.0 by default. Even with a port, expect it to be far below the
  CPU cores on the same chip. **Not worth pursuing.**

## What actually buys more RandomX hashes

1. More/better CPU cores with ≥ 2 MiB of fast cache per thread, low-latency DRAM, huge
   pages (Linux/Windows), MSR mod — e.g. a Ryzen 9000 desktop on Linux is roughly 4–13×
   the Apple machines in the table above.
2. On existing Apple hardware: correct thread count, P-core residency, thermal headroom;
   possibly Linux (Asahi) for huge pages on M1/M2. See `08-optimization-opportunities.md`.
3. An ASIC, if the economics (and RandomX v2 support) check out.

Sources: tevador/RandomX README & design.md; github.com/MainSilent/RandomX-FPGA;
NTHU implementation-competition summary; pool.kryptex.com/articles/antminer-x5-en;
gist.github.com/SChernykh/6058ecf01c929883b9d19c7eeadc8809; minerstat.com GPU comparisons.

# 05 — RandomX internals (as implemented in xmrig)

Code: `src/crypto/randomx/` (forked library) and `src/crypto/rx/` (xmrig glue).
Reference spec: tevador/RandomX `doc/specs.md` and `doc/design.md`.

## Memory objects

| Object | Size | Built from | Lifetime | Code |
|---|---|---|---|---|
| Cache | 256 MiB | Argon2d(seed, salt `"RandomX\x03"`, 3 passes, 1 lane) | per seed (~2048 blocks ≈ 2.8 days) | `dataset.cpp: initCache`, `RxCache` |
| SuperscalarHash programs | 8 programs | Blake2Generator(seed) | per seed; JIT-compiled on x86 & ARM64 | `superscalar.cpp`, `generateSuperscalarHash` |
| Dataset | 2 GiB + 32 MiB extra = 2080 MiB (34,078,719 × 64 B items) | each item = 8 × (superscalar program + XOR of a random cache line) | per seed | `RxDataset`, `randomx_init_dataset` |
| Scratchpad | 2 MiB per thread (L1 = first 16 KiB, L2 = first 256 KiB, L3 = all) | AES generator from Blake2b(blob) | per hash | `CpuWorker` `VirtualMemory` |
| VM / JIT code buffer | ~30 KiB code per thread | program bytes | per program (8 per hash) | `vm_compiled.cpp`, `jit_compiler_*` |

Fast mode keeps the dataset in RAM (one copy per NUMA node). Light mode keeps only the
cache and computes each dataset item on demand (the VM calls the superscalar code inside
the loop) — small memory, much lower hashrate.

## One hash, step by step (RandomX v1 = `rx/0`)

```
H   = Blake2b-512(blob)                                   # input = 76+ byte hashing blob with nonce at byte 39
SP  = fillAes1Rx4(H, 2 MiB)                               # 4 AES lanes, 1 round per 16 B; H := final generator state
for p in 0..7:
    P   = fillAes4Rx4(H, 128 + 8*256 bytes)               # 128 B config entropy + 256 instructions x 8 B
    VM.init(P.config)                                     # a0..a3, ma, mx, readReg0..3, datasetOffset, E masks
    JIT-compile P                                         # ~5.6 us here (x86); ARM64 similar + icache flush
    repeat 2048 times:                                    # "iteration"
        r[0..7]  ^= SP[spAddr0 .. +64]                    # integer regs from scratchpad (L3-wide random address)
        f/e[0..3] = int32->double(SP[spAddr1 .. +64])     # FP regs (E masked into a safe exponent range)
        execute 256 VM instructions                       # int ALU/mul/mulh, FP add/sub/mul/div/sqrt, branches, stores
        mx ^= r[readReg2] ^ r[readReg3]
        prefetch DATASET[mx]                              # for the NEXT iteration
        r[0..7]  ^= DATASET[ma .. +64]                    # <-- dependent DRAM access (2 GiB random)
        swap(ma, mx)
        SP[spAddr1] = r[0..7];  f ^= e;  SP[spAddr0] = f[0..3]
        spMix = r[readReg0] ^ r[readReg1]                 # next scratchpad addresses
    if p < 7: H = Blake2b-512(register file, 256 B)
A   = hashAes1Rx4(SP)                                     # fused with the next hash's fill in xmrig
R   = Blake2b-256(register file)                          # final RandomX hash
```

Per hash: 8 × 2048 × 256 = **4,194,304 VM instructions**, 16,384 dependent random
dataset reads (64 B each), ~32,768 scratchpad 64 B reads + writes, 262,144 AES rounds
(scratchpad fill + hash), ~8–9 Blake2b calls.

### The VM

* Registers: integer `r0–r7` (64-bit), FP `f0–f3` (additive), `e0–e3` (multiplicative),
  `a0–a3` (read-only constants), each FP register = 2 doubles (128-bit SIMD).
* Instruction = 8 bytes {opcode, dst, src, mod, imm32}; the opcode byte is mapped through a
  256-entry table built from these frequencies (`randomx.cpp`, `RandomX_ConfigurationBase`):

| Group | Instructions (frequency /256) |
|---|---|
| integer ALU | IADD_RS 16, ISUB_R 16, IXOR_R 15, IROR_R 8, IROL_R 2, INEG_R 2, ISWAP_R 4 |
| integer multiply | IMUL_R 16, IMULH_R 4, ISMULH_R 4, IMUL_RCP 8 (multiply by precomputed reciprocal) |
| integer w/ memory | IADD_M 7, ISUB_M 7, IMUL_M 4, IMULH_M 1, ISMULH_M 1, IXOR_M 5 |
| FP | FADD_R 16, FSUB_R 16, FMUL_R 32, FSCAL_R 6, FSQRT_R 6, FSWAP_R 4, FADD_M 5, FSUB_M 5, FDIV_M 4 |
| control | CBRANCH 25 (taken ≈ 1/256, jumps back), CFROUND 1 (sets FP rounding mode) |
| store | ISTORE 16 (L1/L2, or L3 when cond ≥ 14) |

  Memory operands hit L1 (16 KiB) or L2 (256 KiB) windows of the scratchpad, chosen by
  `mod.mem`; the per-iteration 64 B loads/stores use the whole 2 MiB.
* IEEE-754 double precision with all 4 rounding modes (CFROUND) — why CPUs and GPUs with
  full FP64 behave correctly and simplified hardware cannot cut corners.

### JIT compilers

* **x86-64** `jit_compiler_x86.cpp` + `jit_compiler_x86_static.S`: r0–r7 ↔ r8–r15,
  F ↔ xmm0–3, E ↔ xmm4–7, A ↔ xmm8–11; variants for BMI2 (MULX/RORX), the Intel JCC
  erratum (branch alignment), AMD; dataset item code optionally AVX2 (`init-avx2`);
  scratchpad prefetch mode 0–3 patched into the loop.
* **ARM64** `jit_compiler_a64.cpp` + `jit_compiler_a64_static.S` (Apple Silicon path):
  r0–r7 ↔ x4–x7, x12–x15; F ↔ v16–v19, E ↔ v20–v23, A ↔ v24–v27; IMUL_RCP reciprocals
  kept in x21–x30/x0/x11 or literal pool; `x18` untouched (Apple platform register).
  The loop prefetches the next dataset line with `prfm pldl1strm` and reads the current
  one with `ldnp` (non-temporal) (#3820, ~8% on M4). The static prologue/epilogue is
  copied once; each program re-emits only the body (+ a few patched epilogue words) and
  flushes only those ranges from the I-cache (#3845).
* **RISC-V** scalar + vector JITs (`jit_compiler_rv64*`).
* Interpreter fallback (`vm_interpreted*`) when no JIT (very slow).

### XMRig-specific optimisations over the reference implementation

| Optimisation | Where |
|---|---|
| Fused scratchpad hash (end of hash n) + fill (start of hash n+1), 1 pass over 2 MiB | `hashAndFillAes1Rx4`, `randomx_calculate_hash_next` |
| Software pipelining of first/next hash in the worker loop | `CpuWorker::start` |
| JIT-compiled SuperscalarHash for dataset init (x86, AVX2 variant, ARM64, RISC-V) | `generateSuperscalarHash` |
| Huge pages / 1 GiB pages for dataset, scratchpads, VM pool; NUMA-local dataset copies | `VirtualMemory*`, `RxNUMAStorage` |
| MSR mod (disable/adjust HW prefetchers) for Ryzen/Intel; Ryzen exception-frame fix | `RxMsr`, `RxFix_*` (x86 Linux/Windows only) |
| Cache QoS (Intel RDT) so non-mining cores don't evict L3 | `RxConfig::cacheQoS` |
| VAES-512 AES for Zen 5; runtime-selected soft-AES variants by thread count | `aes_hash_vaes512.cpp`, `SelectSoftAESImpl` |
| BMI2 / JCC-erratum aware instruction selection | `jit_compiler_x86.cpp` |

## RandomX v2 (`rx/2`, Monero after the FCMP++ hard fork, blob version ≥ 17)

`RandomX_ConfigurationMoneroV2` (`randomx.cpp`) = v1 plus:

| Tweak | Change | Code |
|---|---|---|
| `ProgramSize = 384` | 1.5× VM instructions per hash (6,291,456) | config |
| `Tweak_V2_CFROUND` | rounding mode only changes when 4 selected bits are zero (~16× less often) | `h_CFROUND` (ARM64 `tst`+`bne`), x86 JIT |
| `Tweak_V2_AES` | F registers mixed with E registers using 16 AES rounds per iteration instead of a XOR (another 262,144 AES/hash) | `randomx_program_aarch64_v2_FE_mix` |
| `Tweak_V2_PREFETCH` | dataset prefetch **2 iterations ahead** instead of 1 | `vm_instructions_end_v2`, `program_read_dataset_v2.inc` |
| `Tweak_V2_COMMITMENT` | final PoW value = Blake2b-256(blob ‖ R); submitted as `result`, with R sent as `commitment` | `randomx_calculate_commitment`, `CpuWorker`, `Client::submit` |

Upstream notes (SChernykh's "RandomX v2 testing" gist): v2 is ~1.5× the work per hash;
on many CPUs the hashrate drops only 0–25 % and some *gain*, i.e. work per joule rises
15–65 %. **Measured here: v2 was faster than v1 (mean 2075 vs 1956 H/s, 4 threads)**:
37 % of a v1 iteration is memory stall, and the 2-ahead prefetch cuts the exposed dataset
stall from 28 ns to 3 ns per iteration, so v2's extra work fills time v1 spent waiting
(see `07-performance-analysis.md`).

## Cost model that matters for optimisation

Measured with the built-in profiler on this machine (4 threads, 2 MiB pages, rx/0):

| Stage (per hash, per thread) | Time | Share |
|---|---|---|
| Execute JIT program (8 × 247 µs) | 1,976 µs | **95.0 %** |
| JIT compile (8 × 5.6 µs) | 45 µs | 2.1 % |
| Scratchpad hash + fill (AES, 2 MiB) | 53 µs | 2.6 % |
| Program generation (8 × 0.23 µs AES) | 1.8 µs | 0.1 % |
| Blake2b (~9 × 0.38 µs) | 3.5 µs | 0.2 % |
| **Total** | **2,081 µs** (≈ 480 H/s/thread) | |

Each program iteration takes ~121 ns (247 µs / 2048) here, of which only ~75 ns is
compute; the rest is waiting on scratchpad and dataset loads. Anything outside the JIT
loop is ≤ 5 % of the total, so optimisation work has to target the loop itself or the
memory system it waits on.

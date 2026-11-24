# CLAUDE.md

XMRig 6.27.0 (CPU/GPU RandomX miner). The owner mines Monero on Apple Silicon macOS
(`-o xmr-us-west1.nanopool.org:14433 -u <wallet> --tls --coin monero`) and is looking for
ways to speed up the flow (code optimisation, FPGA, other hardware).

**Read `doc/knowledge-base/README.md` first** — it indexes a deep-dive knowledge base:
architecture, startup/config, stratum/TLS, mining pipeline, RandomX internals (incl. v2),
Apple Silicon specifics, measured performance analysis, ranked optimisation ideas,
FPGA/ASIC/GPU feasibility, and benchmarking/profiling recipes.

## Build

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release            # add -DWITH_OPENCL=OFF -DWITH_CUDA=OFF for CPU-only
make -j$(nproc)                                # or ninja
./xmrig --bench=1M                             # offline benchmark; rx/0 hash sum is verified
```

Deps: libuv, OpenSSL (or `-DWITH_TLS=OFF`), optional hwloc. Profiling build:
`-DWITH_PROFILING=ON` (x86-only `rdtsc`; arm64 port described in
`doc/knowledge-base/10-benchmarking-and-profiling.md`).

## Facts that save time

* Hot path: `src/backend/cpu/CpuWorker.cpp` → `randomx_calculate_hash_next`
  (`src/crypto/randomx/randomx.cpp`) → JIT program loop
  (`jit_compiler_x86*` on x86-64, `jit_compiler_a64*` on Apple Silicon). ~95 % of time is
  inside JIT-generated code; compiler flags barely matter.
* Monero switches from `rx/0` to `rx/2` (RandomX v2) when the job blob major version
  is ≥ 17 (`Coin::algorithm`, `src/base/crypto/Coin.cpp`).
* macOS arm64: no huge pages, thread affinity is a no-op, W^X JIT via `MAP_JIT` +
  `pthread_jit_write_protect_np`, one thread per core (P + E) by default.
* After any change to RandomX/JIT code, run `--bench=250K` (sum `7D6054757BB08A63` for
  rx/0) or `--bench=1M` and confirm the hash sum is green before mining.
* Console output only goes to a TTY or pipe; use `--log-file` when scripting. The
  benchmark waits for Ctrl+C after printing its result.
* Measurement-only builds (modified dataset mask, CFROUND frequency, scratchpad size)
  produce invalid hashes — never mine with them.

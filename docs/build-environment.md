# Local Build Environment Status

Recorded: 2026-09-11, checked on the primary working machine
(`ThinkPadX1Yoga`, Arch Linux). This resolves the "toolchain/build environment
reproduced locally" item from Phase 0 of `../plans/roadmap.md`.

## Already present, no action needed

| Tool | Found | Version |
|---|---|---|
| `clang` | `/usr/bin/clang` | 22.1.8 |
| `lld` | `/usr/bin/lld` | (LLVM 22 toolchain) |
| `dtc` (devicetree compiler) | `/usr/bin/dtc` | 1.8.1 |
| `mkbootimg` | `/usr/bin/mkbootimg` | — |
| `bc`, `bison`, `flex`, `openssl`, `make` | present | — |
| `libelf` | installed | 0.196-1 |
| `base-devel` (group) | installed | — |

This is enough to do a modern **`LLVM=1` clang/lld kernel build** —
mainline Linux has supported building `arm64` entirely with Clang + LLVM
tools (no GNU cross-`gcc` required) for years now, and current upstream
kernels (`v7.x`, what this project targets per `PORTING_ANALYSIS.md` and the
S9 Ultra project's precedent) build cleanly that way with
`ARCH=arm64 LLVM=1 LLVM_IAS=1`.

## Optional, not yet installed

- `aarch64-linux-gnu-gcc` / `aarch64-linux-gnu-binutils` — available in the
  Arch `extra` repo (`pacman -S aarch64-linux-gnu-gcc` pulls in
  `aarch64-linux-gnu-binutils` too) but **not required** for an `LLVM=1`
  build. Worth installing only if a `LLVM=1`-only build hits something that
  genuinely needs GNU `as`/`ld.bfd` (rare on current mainline `arm64`, but not
  impossible with some vendor/downstream-derived driver code we may end up
  porting from `references/gts7l`). Not installed yet — do so on demand if a
  build actually fails without it, rather than preemptively.
- Android platform tools beyond `adb` (e.g. `fastboot`, a `heimdall` build,
  `avbtool`) — not checked yet; needed before Phase 1 flashing attempts, not
  before a first kernel *build*.

## Disk space

`/` has **90G free** of 1.7T (95% used overall) at time of writing. A kernel
source tree + `O=` build output directory typically needs on the order of
10-20G for a full `allmodconfig`-adjacent build; a targeted `gts7l`
defconfig-sized build is much smaller. Not currently a blocker, but worth
re-checking before a full build — 90G can shrink fast on a 95%-full root if
other things are writing to it concurrently.

## First build attempt — done, succeeded (2026-09-11)

Proof-of-toolchain build completed successfully:

- Source: shallow-cloned upstream `torvalds/linux` at tag `v7.2`
  (`work/linux`, gitignored scratch space — not committed, matches the
  reference project's `work/` convention).
- Command: `make ARCH=arm64 LLVM=1 LLVM_IAS=1 defconfig` then
  `make ARCH=arm64 LLVM=1 LLVM_IAS=1 -j20 Image dtbs`.
- Result: **clean build, zero compiler warnings**, `arch/arm64/boot/Image`
  produced (40MB, verified as a real ARM64 boot Image via `file`), and both
  `sm8250-samsung-r8q.dtb` and `sm8250-samsung-x1q.dtb` compiled without
  issue — confirming the Samsung SM8250 board files from
  `kernel-baseline.md`'s chosen base build cleanly on this toolchain.
- Kernel release string: `7.2.0`. Build time: ~13 minutes on 20 cores.
  Source tree + build output: 5.4G on disk (84G free remained afterward).
- **This fully closes out the "toolchain works end-to-end" question** — no
  GNU cross-`gcc` was needed, `LLVM=1`/`LLVM_IAS=1` clang+lld was sufficient
  for a complete `arm64` build including devicetree compilation.

### Important process note for next time

A background kernel build was started via `nohup make ... & disown`, which
returns almost immediately — the harness's background-task notification for
*that launcher command* arrived within a second, **before the actual
multi-minute compile had gone anywhere**. Do not treat that notification as
"the build is done." The correct pattern used here: separately background a
`until ! kill -0 <pid>; do sleep 5; done` wait-loop on the real `make` PID,
and treat *that* command's completion notification as the real signal. Watch
for this trap again for any future long build kicked off with
`nohup ... & disown` rather than the Bash tool's own `run_in_background`.

## Not yet done (next steps)

- This proof build targeted the generic `arm64` `defconfig`, not a
  `gts7l`-specific kernel config. Phase 1's actual devicetree/driver work
  still needs to happen before anything boots on the physical tablet.
- Android platform tools beyond `adb` (e.g. `fastboot`, a `heimdall` build,
  `avbtool`) — not checked yet; needed before Phase 1 flashing attempts, not
  before a kernel *build*.

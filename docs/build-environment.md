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

## Not yet done (next steps when Phase 1 build work starts)

- Fetch actual upstream mainline Linux source (not the stale
  `sm8250-mainline` mirror in `references/linux` — see
  `kernel-baseline.md` for why that mirror was rejected as a base) at a
  recent tag, e.g. `v7.2` or later, matching what `kernel-baseline.md`
  decided to build on.
- First build attempt: confirm `sm8250-samsung-x1q_defconfig`-equivalent (or
  a plain `defconfig` + `CONFIG_ARCH_QCOM`) builds and boots in QEMU or on
  the `x1q`/`r8q` upstream boards conceptually, before touching `gts7l`
  specifics — establishes the build process works at all before adding
  device-specific unknowns.

# Current Device State — Working Tablet

Recorded: 2026-09-11, via `adb` against the tablet as currently connected and
booted (stock One UI, rooted). This is a factual snapshot for planning
purposes — re-verify before relying on any of it for a flashing decision, and
append a new dated section below rather than overwriting this one if the
device state changes.

## ⚠️ CRITICAL: do not let anti-rollback (`rp`) advance

**The owner is treating this unit as a collector's device on its original,
first-released One UI build and explicitly does not want it to ever update —
neither via OTA nor via a manual flash of newer firmware.**

The relevant field is the anti-rollback / rollback-protection counter, which
shows up as **`ro.boot.rp` / `androidboot.rp` = `1`** in both `getprop` and
`/proc/cmdline` on this unit right now. On Qualcomm/Samsung devices this value
is backed by an **eFuse-based monotonic counter**: it can only ever go up, and
each Samsung firmware release is tagged with an RP value it requires. Flashing
(via Odin/Download-mode or an OTA) any component — bootloader (`abl`/`xbl`),
`vbmeta`, or the AP tar — built against a **higher** RP value than what's
currently fused will **burn the fuse to that higher value irreversibly**, and
after that this device can never accept an Odin flash of the original
`T875XXU1ATK4` firmware (or anything else below the new fused value) again.
This is a one-way trip, done in hardware, not undoable by a factory reset,
re-flash, or unroot.

**Implications for this whole project:**
- Never trigger a Samsung OTA check/download on this device (Wi-Fi OTA,
  Software Update app, Smart Switch "update"). Keep it off Wi-Fi for updates,
  or keep auto-update disabled, or both.
- Never Odin/Heimdall-flash a firmware package newer than `T875XXU1ATK4`
  (bootloader string below) onto this device, for any reason, including "just
  to test something" or "the recovery needs a newer bootloader to work."
- When we get to needing a **custom recovery (TWRP)** or a **custom kernel**
  for bring-up, the AP tar / bootloader/vbmeta pieces used must be built or
  selected specifically to avoid bumping RP. If a candidate TWRP/AP package's
  release notes mention a newer security patch level/bootloader than
  `T875XXU1ATK4`/`2020-11-01`, treat it as unsafe until proven otherwise (check
  its actual RP tag, not just its label) — when in doubt, ask the user before
  flashing anything to the `abl`, `xbl`, `xbl_config`, or `vbmeta*` partitions.
- This constraint does not obviously block the mainline-Linux bring-up itself
  (a mainline kernel/boot image doesn't need a bootloader upgrade — the S9
  Ultra project reused the stock ABL as-is), but it must be treated as a hard
  boundary condition for every future phase, especially Phase 0/Phase 5 in
  `../plans/roadmap.md`.

## Identity

| Field | Value |
|---|---|
| `adb` serial | `<serial>` |
| Model | `SM-T875` (LTE variant) |
| `adb devices -l` product/device | `product:gts7leea` `device:gts7l` |
| SoC board codename | `kona` (Qualcomm SM8250 / Snapdragon 865, confirms `PORTING_ANALYSIS.md`) |
| CSC / sales code | `ITV` (Italy) |
| OMC network code | `ITV` |
| Locale at last boot | `en-GB` product locale / `en-US` current / `it-IT` default |

**Correction to `plans/roadmap.md`:** the physical unit in hand is the **LTE
model `SM-T875` (`gts7l`/`gts7leea`)**, not the Wi-Fi-only `SM-T870`
(`gts7wifi`) the roadmap currently assumes throughout. Modem/RIL bring-up
(`mdm`, `modem`, `modemst1/2`, `mdm1m9kefs*` partitions all present) is
therefore in scope unless we deliberately decide to ignore the modem and treat
it as Wi-Fi-only for Linux purposes. **Roadmap needs updating** — flagged in
`plans/roadmap.md` cross-phase notes.

## Firmware / bootloader

| Field | Value |
|---|---|
| Bootloader string | `T875XXU1ATK4` |
| Build fingerprint | `samsung/gts7leea/gts7l:10/QP1A.190711.020/T875XXU1ATK4:user/release-keys` |
| Android version | 10 (API 29) |
| Build ID | `QP1A.190711.020` |
| Security patch level | 2020-11-01 |
| Build date | 2020-11-19 (KST) |
| OMC/CSC build version | `T875OXM1ATK4` |
| `ro.build.version.security_index` | `1` (matches the "first release" expectation) |

This is consistent with being the **first publicly released firmware for this
model** — exactly what the owner wants preserved.

## Security / boot-state flags

Two different reads of nominally the same flags gave **different answers**,
which matters enough to record precisely rather than average out:

**Via `getprop` (property service, queried live over adb shell as root):**

| Property | Value |
|---|---|
| `ro.boot.verifiedbootstate` | `green` |
| `ro.boot.warranty_bit` | `0` |
| `ro.boot.flash.locked` | `1` (locked) |
| `ro.boot.rp` | `1` |

**Via `/proc/cmdline` (raw kernel boot arguments for the currently running
boot, read directly, not through the property service):**

| Field | Value |
|---|---|
| `androidboot.verifiedbootstate` | `orange` |
| `androidboot.warranty_bit` | `1` |
| `androidboot.rp` | `1` (agrees) |

**Read this as:** the device is rooted with Magisk (`su -c id` →
`uid=0(root) ... context=u:r:magisk:s0`; `su` binary at `/sbin/su`; kernel
string `4.19.81-19993249`). Magisk (via resetprop / Zygisk) commonly rewrites
`ro.boot.warranty_bit` to `0` and `ro.boot.verifiedbootstate` to `green` at
runtime so that apps querying these properties see a "clean" device — this is
the most likely explanation for the mismatch, and it is now **confirmed by the
owner physically**: Knox is `0x1` (**tripped/void**) and the **bootloader is
unlocked**. `/proc/cmdline`'s `orange`/`warranty_bit=1` reading was the
accurate one; the `getprop` `green`/`0` values are Magisk-spoofed cosmetic
overrides and should be disregarded for security-state questions on this
device going forward. `ro.boot.rp = 1` was consistent both ways, so the
anti-rollback counter reading above is trusted.

**Bootloader-unlocked confirmation matters for the roadmap:** with OEM unlock
already done, Phase 0/Phase 1 flashing work (custom recovery, test kernels/DTB,
boot images) does **not** additionally need an unlock step — but the
anti-rollback (`rp`) constraint above is independent of the unlock state and
still applies in full: an unlocked bootloader still enforces/advances the RP
eFuse on any image that requests it.

`ro.oem_unlock_supported` = `1`. Current "OEM unlock" toggle state could not
be read (`settings get global oem_unlock_supported` returned `null` — that
namespace key doesn't exist on this build/needs a different query); not yet
determined whether OEM unlock is presently toggled on in Developer Options.

## Root / modification state

- Rooted via **Magisk**, `su` present at `/sbin/su`, shell escalates to full
  root (`uid=0`, SELinux domain `u:r:magisk:s0`).
- Kernel: `4.19.81-19993249`, built `Thu Nov 19 20:05:53 KST 2020`,
  clang 8.0.12 (Android NDK) — this is Samsung's stock downstream kernel, not
  anything mainline; expected at this stage.
- `ro.build.tags` = `release-keys`, `ro.build.type` = `user` — a standard
  retail/production build, rooted after the fact (not an engineering build).
- No FOTA/system-update package was found in `pm list packages` beyond an
  unrelated `com.android.dreams.phototable` false-positive match — worth a
  closer look before assuming there's no update-agent app at all (the grep
  pattern may have been too narrow, or Samsung's updater may be a system
  service rather than a listed launchable package).
- No `/efs/FactoryApp/knoxwarranty` file was found/readable at the checked
  path — Knox warranty status should be confirmed via Download mode instead,
  per the note above.

## Storage

- `/data` (`sda37`, "userdata" by-name): 107G total, 103G used, 3.5G free —
  **storage is nearly full**; worth keeping in mind before any operation that
  needs scratch space on-device (backups, dual-boot split, etc.).
- `dm-0` (a dm-verity/mapped block, mounted at `/system/lib64/...` per this
  `df` invocation's quirky mount-point reporting): 5.6G, 100% used — this is
  a read-only system partition reporting expected fullness, not a concern.
- Battery: 91%, AC powered, Li-ion, healthy (`health: 2` = "good").
- Uptime at capture time: 2 days, 14h26m.

## Partition layout (`/dev/block/by-name/`)

Full listing captured (37+ named partitions across `sda`/`sdb`/`sdd` block
devices) — notable ones for bring-up planning:

- `boot`, `recovery`, `dtbo`, `vbmeta`, `vbmeta_samsung` — standard Android
  Verified Boot chain, present and distinct (`vbmeta` and `vbmeta_samsung` are
  separate partitions, matching Samsung's usual split).
- `abl`, `aop`, `xbl`, `xbl_config`, `tz`, `hyp`, `keymaster`, `cmnlib`,
  `cmnlib64` — Qualcomm/Samsung early boot-chain firmware blobs. **These are
  exactly the components whose version is tied to the RP counter — do not
  touch without checking RP impact first.**
- `param` — boot-mode flag partition (`PARAM_BOOT_RECOVERY_ENTER` etc., same
  role as documented for the S9 Ultra project).
- `persist`, `persistent` — as usual holds calibration/persistent data;
  `ro.frp.pst` points at `/dev/block/persistent` for FRP.
- `super` — dynamic partitions block (`ro.boot.dynamic_partitions = true`,
  `ro.build.ab_update = false` — **this device is A-only, not A/B**, despite
  having dynamic partitions; consistent with Samsung's Android 10-era setup).
- `modem`, `modemst1`, `modemst2`, `mdm1m9kefs1-3`, `mdmddr`, `fsg` — modem/RIL
  firmware and EFS, present because this is the LTE `T875`, not the Wi-Fi-only
  `T870`.
- `efs`, `sec_efs`, `keydata`, `keyrefuge`, `keystore`, `spu` — device
  identity/crypto material; standard, do not touch.
- No `by-name` symlink obviously named "TWRP" or similar was found, and a
  `strings` grep of the `recovery` partition for "twrp" returned nothing — the
  currently flashed recovery is most likely still **stock recovery**, not
  TWRP. Not yet confirmed by direct inspection of its contents beyond this
  grep.

## Open questions / follow-ups for Phase 0

- [x] Confirm true Knox/warranty/verified-boot state — **confirmed by owner:
      Knox `0x1` (tripped/void), bootloader unlocked.**
- [ ] Confirm whether stock recovery or a custom recovery is actually flashed
      (grep was inconclusive, not authoritative).
- [ ] Identify the actual FOTA/update-agent package name on this build so it
      can be deliberately disabled (`pm disable-user`) as a safety measure
      against accidental OTA, on top of not signing into Wi-Fi for updates.
- [ ] Free up `/data` before any on-device build/backup work — only 3.5G free.
- [x] Decide primary target: **`gts7l` (LTE, this physical unit) is primary
      for now; `gts7wifi` support is a desired future goal, not blocking.**
      See `plans/roadmap.md` cross-phase notes.

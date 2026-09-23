# Phase 3: suspend/resume (started 2026-09-23)

The last open Phase 3 exit criterion: "Suspend/resume cycle survives
repeatedly without corruption". Work is in small steps, like the audio
bring-up. Every test runs from a shell with a timed RTC wake
(`tools/rootfs/suspend/susptest.sh`), and the kernel log and suspend
statistics are saved on both sides.

## Baseline (read-only survey)

- **Sleep states:** `/sys/power/state` = `freeze mem disk`, `mem_sleep` =
  `[s2idle]` only. As usual for Qualcomm on mainline there is no PSCI
  SYSTEM_SUSPEND "deep" state: sleep means s2idle, with the CPUs and the
  cluster in their deepest cpuidle states and RPMh taking the rest of the
  SoC down.
- **PSCI:** v1.1 in **OS-initiated (OSI) mode**. The kernel logs `OSI mode
  supported` and also `[Firmware Bug]: failed to set PC mode: -3`: the
  firmware refuses platform-coordinated mode, which is fine with OSI plus
  the psci CPU power-domain tree from `sm8250.dtsi`.
- **cpuidle:** WFI and per-core power collapse (`silver/gold-rail-power-
  collapse`) are used. The cluster domain `power-domain-cpu-cluster0` (with
  `cluster_sleep_0`) showed no idle usage in normal running. Whether it,
  and the SoC's CX/AOSS sleep, is reached in s2idle is unknown until
  `qcom_stats` is readable.
- **Wakeup sources:** the PM8150 power key and RTC, gpio-keys (volume),
  the MAX77705 PMIC, USB, the SLPI/ADSP remoteprocs, and MHI (Wi-Fi).
- **RTC alarm:** works (`/sys/class/rtc/rtc0/wakealarm`, `alarm_IRQ: yes`)
  even though setting the RTC's time is not allowed.
  `rtcwake -m freeze -s N` drives the tests.
- **Crash capture:** pstore/ramoops (512 KB console). The tests set
  `printk.console_suspend=N` so the console keeps logging.

## Test 1 (2026-09-23): s2idle, 20 s RTC wake, stock kernel config

**Result: suspends and resumes** (not a reboot: suspend_stats
`success=1`, no failure counters, and uptime advanced 23 s across the
test). The RTC woke the SoC. The screen stayed off until the power
button was pressed, which is expected: KWin leaves the display off after a
non-user wake.

Problems seen:
1. **The SLPI crashes at resume:** `PDM: service 'sensor_process' crash:
   'EX:sensor_process:0x1:frpc_dsp:0x74'`, right after tasks are thawed.
   remoteproc recovers the SLPI, and `hexagonrpcd` restarts by itself,
   but **iio-sensor-proxy segfaults** and is not restarted, so sensors and
   auto-rotate are gone after resume.
2. **Wi-Fi is torn down:** ath11k deauthenticates (`DEAUTH_LEAVING`) and
   is powered fully off and on again (MHI power-on during resume).
   Internet returns a few seconds after wake.
3. **USB:** `dwc3-qcom-legacy a6f8800.usb: port-1 HS-PHY not in L2`.
4. **Unknown:** whether the SoC reaches CX collapse or AOSS sleep at all,
   i.e. whether suspend saves any power.

## Test 2 (2026-09-23): SLPI crash at resume, fixed (0026)

`pm_test=freezer` alone reproduced the crash, so it came from freezing
userspace, not device suspend. `hexagonrpcd` blocks in a FastRPC invoke
with `wait_for_completion_interruptible()`. The freezer's fake signal
aborts that wait, the in-flight call to the SLPI is abandoned, and the
SLPI's `sensor_process` faults on the dead reply. Patch **0026** makes the
wait `TASK_INTERRUPTIBLE | TASK_FREEZABLE`: the freezer parks the task in
place, and the call completes normally after thaw. Verified: no SLPI crash
across real s2idle, auto-rotate works after resume.

## Test 3 (2026-09-23): does s2idle reach CX collapse / AOSS sleep?

`qcom_stats` (kernel with `QCOM_STATS`) counts RPMh sleep modes. The
counters work (`adsp`, `slpi`, `slpi_island` count up), but **`aosd`,
`cxsd` and `ddr` stayed 0** across every s2idle, while the CPU cluster
domain does enter `cluster_sleep_0` in s2idle.

Found and fixed so far:

1. **Providers that never ran `sync_state()`** (`state_synced` = 0).
   fw_devlink was in strict mode, so a supplier with any unbound consumer
   waits forever:
   - `rpmhpd` waited on camcc (`=m`; the rootfs has no modules), and until
     sync it clamps every RPMh power domain, CX included, to its top
     corner (`rpmhpd.c`, "Clamp to highest corner");
   - the `mc_virt` and `aggre2` interconnects waited on the crypto engine
     (`=m`) and held INT_MAX, pinning DDR at 1555 MHz;
   - gcc and gpucc waited on the GMU, which adreno drives without binding
     a driver to it.
   Fix: `CONFIG_FW_DEVLINK_SYNC_STATE_TIMEOUT=y` (sync forced 10 s after
   boot probing, logged as "Timed out. Forcing sync_state()"). DDR now
   scales 547-2736 MHz.
2. **`clk_ignore_unused`** on the cmdline (a bring-up leftover that never
   fixed the problem it was added for) kept every bootloader-enabled
   clock running, among them GPLL0-fed UFS ICE at 300 MHz, the PCIe1/2
   refgen clocks, the UFS-card AXI clocks and the debug UART. Dropped;
   the display is unaffected (MSM DRM claims its own clocks).

   **Do not stop the ADSP by hand** since this change: with unused clocks
   really gated, `echo stop` on the ADSP remoteproc tears down the LPASS
   clocks under the active VA macro and the SoC resets silently (pstore
   ends at `va_macro 3370000.codec: unable to prepare mclk`). A real ADSP
   crash would probably do the same; noted for later.

3. **Four drivers still held CXO when the CPUs went down.** Found with
   event tracing (`FTRACE`): clock prepare/unprepare events plus
   `rpmh_send_msg`, replayed from a clock-tree snapshot up to the RPMh
   sleep-set flush (`tools/rootfs/suspend/susptest-clktrace.sh`). Note
   that a clock only has to be *prepared* to hold CXO: `bi_tcxo` is an
   RPMh clock and casts its XO vote in its prepare op.
   - **UFS, patch 0027:** a leak in `ufs-qcom`. Resume enables the lane
     clocks twice (`ufs_qcom_setup_clocks()` in hibern8, then
     `ufs_qcom_resume()`) and disable drops one, so every suspend leaked
     one prepare on all UFS clocks (the gated prepare count equalled the
     number of suspends so far). They are fed from GPLL0.
   - **BT UART, patch 0028:** `uart_suspend_port()` powers the port down
     with `pm_runtime_put_sync()`, which is a no-op during system suspend
     (the PM core holds a runtime PM reference on every device). Fixed
     with a late `pm_runtime_force_suspend()` for non-console ports.
   - **Display, patch 0029:** the DSI PHY used pm_clk for its AHB clock,
     and pm_clk keeps clocks prepared while runtime suspended. Two PHYs
     (dual-DSI panel) meant two permanent prepares. Replaced with
     prepare+enable / disable+unprepare in the runtime PM callbacks, plus
     a late `pm_runtime_force_suspend()` (DRM turns the display off in
     its prepare callback, after the PM core took its reference).
   - **Wi-Fi PCIe, patch 0030 + DT:** the Root Port advertises a hot-plug
     slot, and `pci_bridge_d3_possible()` refuses D3 for hot-plug ports,
     so `dw_pcie_suspend_noirq()` never took the link to L2 or turned the
     controller off. New optional `qcom,no-hotplug-slot` property on
     `&pcie0` (the QCA6390 is soldered down) clears the slot bits. The link
     now goes down in suspend and retrains on resume; Wi-Fi reconnects.

With all four fixed, a debug build (a `trace_printk` in
`clk_core_(un)prepare` for `bi_tcxo`) showed the CXO prepare count
reaching **0** before the flush, and the flush writes the right sleep
set: `xo.lvl` 0, CX/MX/MMCX 0, the DDR bandwidth BCMs 0.

**The counters still stay at 0**, also with the USB cable unplugged and
after sending AOSS explicit "don't prevent" messages
(`/sys/kernel/debug/qcom_aoss/prevent_{aoss_sleep,cx_collapse,ddr_collapse}`
= 0). So the application CPUs' own RPMh votes are now clean, and whatever
still blocks AOSS sleep is outside them. Candidates, none checked yet:

- the **display RSC** (`disp_rsc`), a separate RPMh voter that mainline
  never drives; ABL's continuous splash may leave votes in it;
- subsystems that mainline doesn't boot here (**CDSP**, and whatever
  stock does with the modem side);
- **PMIC regulator** votes (always-on LDOs in HPM);
- a firmware difference in what the stats report (unlikely, since the
  DDR LPM counters in `ddr_stats` are also 0).

Useful next reference: boot stock Android, read its sleep stats
(`/sys/power/rpmh_stats/master_stats` or `/d/rpm_stats`) to confirm the
hardware reaches AOSS sleep at all in this setup, and compare.

Tooling notes: `susptest-unplugged.sh` waits for the charger to report
offline (the USB gadget's `usb0` carrier never drops on unplug, since dwc3
has no VBUS sensing). `susptest-minimal.sh` (it stops the ADSP) must not
be used any more; see above.

One unexplained event: on kernel #127 (the first without
`clk_ignore_unused`) the tablet hung silently about 10 minutes after boot,
idle, after one suspend test, and rebooted by itself (watchdog). pstore
ends in routine SLPI "Handover" spam; screen-off alone didn't reproduce
it. Not seen again on later kernels; watch for it.

## Next

- Find the remaining AOSS-sleep blocker (see the candidate list above).
- Remove the debug-only `FTRACE` options from the fragment once done.
- Then: KDE-triggered suspend, wake sources (power key, charger plug),
  and a repeated-cycle soak test.

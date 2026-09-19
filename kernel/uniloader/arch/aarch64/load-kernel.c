// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2022, Ivaylo Ivanov <ivo.ivanov.ivanov1@gmail.com>
 * Copyright (c) 2026, Igor Belwon <igor.belwon@mentallysanemainliners.org>
 */

#include <main/boot.h>
#include <string.h>

void arch_load_kernel(void* kernel, void* dt, void* ramdisk)
{
	memcpy((void*)CONFIG_PAYLOAD_ENTRY, kernel, (unsigned long) &kernel_size);
#ifndef CONFIG_RAMDISK_NO_COPY
	__optimized_memcpy((void*)CONFIG_RAMDISK_ENTRY, ramdisk, (unsigned long) &ramdisk_size);
#endif

	/*
	 * Round 28 (docs/kernel-boot-debugging.md, UbuntuTabS7 project) -
	 * the DRAM-marker approach (Rounds 25-27) hit two independent, real
	 * confounds in a row (an untested "free" address that didn't survive
	 * a cold-boot DDR retrain; then a "padding" offset inside ramoops
	 * that turned out to still be live, overwritten by TWRP's own kernel
	 * before the next readback). Reconsidered rather than guessing a
	 * third address: this device's own hardware "apps watchdog"
	 * (`qcom,kpss-wdt`, `work/linux/.../sm8250.dtsi` `watchdog@17c10000`,
	 * register layout confirmed directly against the real mainline
	 * driver `drivers/watchdog/qcom-wdt.c`'s `reg_offset_data_kpss`
	 * table) is the same class of mechanism that already, reliably,
	 * repeatedly produced real, analyzable crash-dump entries in
	 * `/dev/block/by-name/debug` throughout this project (Round 23's
	 * genuine `out_of_memory` panic; RWC=72-78's `Watchdog Reset
	 * (CPU HANG)` entries) - proven infrastructure, not a new guess.
	 *
	 * Arm it here, directly, with a short (3s) timeout, immediately
	 * before the jump - mirroring the real driver's own
	 * `qcom_wdt_start()` sequence exactly (disable, reset counter, set
	 * bark/bite time, enable). If the kernel hangs before it can ever
	 * pet this watchdog (plausible - this project's own testing already
	 * showed the hang happens before Linux's *own* software lockup
	 * detectors can even arm), this hardware watchdog fires
	 * independently and forces a real reset regardless - no reliance on
	 * the owner's manual hard-reboot, and (per this device's own
	 *`sec_debug`/`TZBSP` crash-dump behavior, already proven multiple
	 * times this session) the resulting `Watchdog Reset (CPU HANG)`
	 * event should itself be captured with a real, symbolized backtrace,
	 * same as Round 23's OOM panic - the richest evidence this project
	 * has found so far, without needing to read anything back through
	 * uniLoader's own screen at all. `sleep_clk` (this device's real
	 * `fixed-clock` at 32768 Hz-ish, already confirmed at Round 16) is
	 * this watchdog's clock source, so timeout-in-seconds * clock-rate
	 * gives the tick count for BARK_TIME/BITE_TIME.
	 */
	{
		volatile unsigned int *wdt = (volatile unsigned int *)0x17c10000ULL;
		unsigned int rate = 32000; /* sleep_clk, confirmed via this
					      device's own DTB */
		unsigned int ticks = 3 * rate; /* 3 second timeout */

		wdt[0x8 / 4] = 0;      /* WDT_EN = 0 (disable while reprogramming) */
		wdt[0x4 / 4] = 1;      /* WDT_RST = 1 (reset the counter) */
		wdt[0x10 / 4] = ticks; /* WDT_BARK_TIME */
		wdt[0x14 / 4] = ticks; /* WDT_BITE_TIME */
		wdt[0x8 / 4] = 1;      /* WDT_EN = 1 (QCOM_WDT_ENABLE) - armed,
					   left running and unpetted */
		asm volatile("dsb sy" ::: "memory");
	}

	load_kernel_and_jump(dt, 0, 0, 0, (void*)CONFIG_PAYLOAD_ENTRY);
}

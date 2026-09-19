/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung Galaxy Tab S7 LTE (SM-T875, "gts7l")
 *
 * No early/late init hooks needed. A `simplefb` device is wired up here
 * purely as a debugging aid (docs/kernel-boot-debugging.md Round 21) - to
 * get direct visual confirmation uniLoader itself runs and reaches
 * board/driver init, before jumping to the real kernel, since Round 20's
 * hardware test (CPU warming, no visible output, a PS_HOLD reset loop)
 * couldn't distinguish "uniLoader itself is stuck" from "the real kernel
 * took over and crashed later" without this. Reuses the exact physical
 * framebuffer region and geometry ABL's own splash screen draws to on
 * this device (`cont_splash_region@9c000000`, confirmed real via this
 * device's own stock devicetree and directly observed in ABL's own log:
 * `Width = 1600, Height = 2560`) - not a Phase 2 real panel driver, this
 * is Phase 1 debugging only.
 */

#include <board.h>
#include <util.h>
#include <drivers/framework.h>
#include <lib/simplefb.h>
#include <lib/debug.h>

static struct video_info gts7l_fb = {
	.format = FB_FORMAT_ARGB8888,
	.width = 1600,
	.height = 2560,
	/*
	 * NOT row pitch in bytes - this driver's own convention (confirmed
	 * against every other board's video_info, e.g. board-r0q.c) uses
	 * `stride` to mean bytes-per-pixel. clean_fbmem()/draw_pixel() both
	 * compute the real row size internally as width*stride. Getting this
	 * wrong (an earlier version of this file used width*4=6400 here) made
	 * clean_fbmem()'s memset size 1600x too large - ~26GB starting at
	 * 0x9c000000, far past physical RAM. That's what caused the
	 * black-screen-then-hang in Round 21's first hardware test.
	 */
	.stride = 4,
	.address = (void *)0x9c000000
};

static const struct device gts7l_devices[] = {
	{ "simplefb", &gts7l_fb, "fb" },
};

/*
 * Round 25 debug marker readback (docs/kernel-boot-debugging.md) - this
 * device's TWRP kernel has neither /dev/mem nor /proc/kcore, so there's no
 * way to inspect arbitrary physical RAM from userspace after a hang. Since
 * DRAM survives the warm PS_HOLD reset used to get back into TWRP (the
 * same principle pstore/ramoops already relies on), have uniLoader itself
 * read the fixed marker address and print it on its own splash screen -
 * runs on *every* boot, right after simplefb comes up (late_init, so a
 * console is already registered), before jumping to the kernel again.
 * On the first flash this prints whatever garbage was already there; the
 * meaningful read is whatever shows after a hang+reboot cycle, reflecting
 * what the *previous* boot's kernel (kernel/arch/arm64/kernel/head.S,
 * see kernel/patches/0001-round25-early-dram-debug-marker.patch) left
 * behind - `deadbeef cafec0de` means the kernel's very first instructions
 * genuinely executed; anything else means the jump never got that far.
 * Printed as two 32-bit halves since nanoprintf's large-format (%llx)
 * specifiers are disabled in this build (see lib/console/console.c).
 */
static int gts7l_late_init(void)
{
	volatile unsigned long long *marker =
		(volatile unsigned long long *)0x95000000ULL;
	unsigned long long val = *marker;
	unsigned int hi = (unsigned int)(val >> 32);
	unsigned int lo = (unsigned int)(val & 0xffffffffU);

	printk(KERN_INFO, "debug marker @ 0x95000000:\n");
	printk(KERN_INFO, "%x %x\n", hi, lo);
	return 0;
}

struct board_data board_ops = {
	.name = "samsung-gts7l",
	.ops = {
		.late_init = gts7l_late_init,
	},
	.devices = gts7l_devices,
	.num_devices = ARRAY_SIZE(gts7l_devices),
	.quirks = 0
};

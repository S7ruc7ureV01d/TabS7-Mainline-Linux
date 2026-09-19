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

struct board_data board_ops = {
	.name = "samsung-gts7l",
	.ops = {
	},
	.devices = gts7l_devices,
	.num_devices = ARRAY_SIZE(gts7l_devices),
	.quirks = 0
};

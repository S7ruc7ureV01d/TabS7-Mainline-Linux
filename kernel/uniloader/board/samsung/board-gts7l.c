/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Samsung Galaxy Tab S7 LTE (SM-T875, "gts7l")
 *
 * Minimal board file - no early/late init hooks and no framebuffer needed
 * yet. This device's own display/panel bring-up is a Phase 2 concern
 * (see plans/roadmap.md); Phase 1 only needs uniLoader to hand off to the
 * real mainline kernel with a real mainline devicetree.
 */

#include <board.h>

struct board_data board_ops = {
	.name = "samsung-gts7l",
	.ops = {
	},
	.devices = NULL,
	.num_devices = 0,
	.quirks = 0
};

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
	 * Round 28's hardware-watchdog arm (3s timeout) lived here and did
	 * its job perfectly - Round 30's readback confirmed the kernel now
	 * genuinely boots all the way to `Run /init as init process`, and
	 * the reset loop the owner saw was just this watchdog firing on
	 * schedule, unpetted, exactly as programmed. It's no longer a
	 * diagnostic aid, just an obstacle now that the real bug (Round 30's
	 * overlapping PAYLOAD_ENTRY) is fixed - removed so the kernel can
	 * run past its own `/init` instead of being cut off at a fixed 3s.
	 */

	load_kernel_and_jump(dt, 0, 0, 0, (void*)CONFIG_PAYLOAD_ENTRY);
}

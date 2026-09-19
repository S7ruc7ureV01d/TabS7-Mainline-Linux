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
	 * Round 25 debug canary (docs/kernel-boot-debugging.md,
	 * UbuntuTabS7 project) - written by uniLoader itself, immediately
	 * before the jump, at a different address than the kernel's own
	 * primary_entry marker (0x95000000). If this canary reads back
	 * correctly on the next boot but the kernel's marker doesn't, that
	 * proves the 0x9500xxxx region is genuinely accessible/writable DRAM
	 * (ruling out a hardware-protected-region explanation for the
	 * kernel marker's absence) and isolates the problem to the jump/
	 * kernel-entry itself, not this memory region.
	 */
	{
		volatile unsigned long long *canary =
			(volatile unsigned long long *)0x95001000ULL;
		*canary = 0xc001babeb00b1e55ULL;
		asm volatile("dc cvac, %0\n dsb sy" :: "r"(canary) : "memory");
	}

	load_kernel_and_jump(dt, 0, 0, 0, (void*)CONFIG_PAYLOAD_ENTRY);
}

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
	 * Round 27 debug canary (docs/kernel-boot-debugging.md,
	 * UbuntuTabS7 project) - written by uniLoader itself, immediately
	 * before the jump, at a different address than the kernel's own
	 * primary_entry marker. Moved from Round 25/26's guessed "free" DRAM
	 * address (0x95001000, which didn't survive the owner's hard-reboot
	 * recovery combo even though this exact write definitely executes
	 * every cycle) to unused padding *inside* this device's real,
	 * DTB-declared `ramoops@9fa00000` carveout - the same region this
	 * project has directly, repeatedly read real content back from after
	 * that exact reset combo throughout this whole debugging effort. If
	 * this canary reads back correctly on the next boot but the kernel's
	 * marker doesn't, that isolates the problem to the jump/kernel-entry
	 * itself, not DRAM retention.
	 */
	{
		volatile unsigned long long *canary =
			(volatile unsigned long long *)0x9fac5000ULL;
		*canary = 0xc001babeb00b1e55ULL;
		asm volatile("dc cvac, %0\n dsb sy" :: "r"(canary) : "memory");
	}

	load_kernel_and_jump(dt, 0, 0, 0, (void*)CONFIG_PAYLOAD_ENTRY);
}

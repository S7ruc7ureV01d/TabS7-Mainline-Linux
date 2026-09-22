/* Minimal, libc-free ARM64 memory-pressure reproducer.
 * Replicates the exact conditions this project's own
 * `stress-ng --vm 1 --vm-bytes 1500M --vm-keep --timeout 30s` repro used
 * (docs/load-test-modules.md) via raw Linux syscalls only, so it links
 * and runs identically on Android's kernel with no bionic/libc
 * dependency at all - just direct syscalls, same ABI on any Linux
 * kernel including Android's.
 */

#define __NR_mmap 222
#define __NR_munmap 215
#define __NR_nanosleep 101
#define __NR_write 64
#define __NR_exit 93

static long syscall3(long n, long a, long b, long c) {
	register long x8 asm("x8") = n;
	register long x0 asm("x0") = a;
	register long x1 asm("x1") = b;
	register long x2 asm("x2") = c;
	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
	return x0;
}

static long syscall6(long n, long a, long b, long c, long d, long e, long f) {
	register long x8 asm("x8") = n;
	register long x0 asm("x0") = a;
	register long x1 asm("x1") = b;
	register long x2 asm("x2") = c;
	register long x3 asm("x3") = d;
	register long x4 asm("x4") = e;
	register long x5 asm("x5") = f;
	asm volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8) : "memory");
	return x0;
}

static void write_str(const char *s, long len) {
	syscall3(__NR_write, 1, (long)s, len);
}

void _start(void) {
	const long SIZE = 5000L * 1024 * 1024; /* exceeds available RAM, forcing real OOM-level reclaim */
	const long PROT_READ = 1, PROT_WRITE = 2;
	const long MAP_PRIVATE = 2, MAP_ANONYMOUS = 0x20;

	write_str("vmstress: mmap 1500M\n", 21);
	long addr = syscall6(__NR_mmap, 0, SIZE, PROT_READ | PROT_WRITE,
			     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (addr < 0 && addr > -4096) {
		char buf[32] = "vmstress: mmap failed errno=  \n";
		long e = -addr;
		buf[29] = '0' + (e % 10);
		buf[28] = (e >= 10) ? ('0' + (e / 10) % 10) : ' ';
		write_str(buf, 32);
		syscall3(__NR_exit, 1, 0, 0);
	}

	write_str("vmstress: touching every page\n", 31);
	volatile unsigned char *p = (volatile unsigned char *)addr;
	for (long i = 0; i < SIZE; i += 4096)
		p[i] = 1;

	write_str("vmstress: holding for 30s\n", 26);
	long ts[2] = {30, 0};
	syscall3(__NR_nanosleep, (long)ts, 0, 0);

	write_str("vmstress: done, exiting\n", 24);
	syscall3(__NR_munmap, addr, SIZE, 0);
	syscall3(__NR_exit, 0, 0, 0);
}

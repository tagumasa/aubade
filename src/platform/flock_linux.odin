#+build linux

// Singleton spawn lock (Linux): an exclusive whole-file fcntl write lock,
// acquired through bounded F_SETLK polling. An unbounded F_SETLKW would let
// a wedged-but-alive holder block every future spawn forever; the bounded
// budget matches what probe_running tolerates when waiting out a draining
// predecessor. darwin carries a bounded flock(2) poll (flock_poll.odin) and
// Windows uses LockFileEx (flock_windows.odin).
package platform

import "core:fmt"
import "core:sys/unix"
import "core:time"

// fcntl record-lock commands on Linux. This file is linux-only; the darwin
// and windows locks live in flock_poll.odin / flock_windows.odin.
F_SETLK_CMD :: 6

F_WRLCK_VAL :: u16(1)
F_UNLCK_VAL :: u16(2)

O_RDWR_CREAT :: 0o102 // O_RDWR | O_CREAT (linux)
O_CLOEXEC_FLAG :: 0o2000000 // O_CLOEXEC: the lock fd must not ride into spawned children

// The kernel's struct flock layout (natural alignment: u16, u16, pad to 8,
// i64 at offset 8, i64 at 16, i32 at 24; 32 bytes) — fcntl copies its own
// 32-byte shape from this buffer, so the struct MUST NOT be #packed (the
// packed 24-byte layout put l_start at offset 4 and only worked while
// l_start and l_len stayed zero).
Lock_Range :: struct {
	l_type:   u16,
	l_whence: u16,
	l_start:  i64,
	l_len:    i64,
	l_pid:    i32,
}

File_Lock :: struct {
	fd:   int,
	path: string,
}

LOCK_ACQUIRE_BUDGET_MS :: 30_000 // bounded: a wedged holder must not wedge every future spawn
LOCK_ACQUIRE_SLICE_MS  :: 50

// Acquire the exclusive lock, retrying a non-blocking F_SETLK until the
// deadline (timeout_ms <= 0 is a single attempt). The lock file is created
// if missing. Returns ok=false when the deadline passed or the OS refused.
file_lock_acquire :: proc(path: string, timeout_ms: i64 = LOCK_ACQUIRE_BUDGET_MS) -> (lock: File_Lock, ok: bool) {
	if timeout_ms <= 0 {
		return file_lock_try_acquire(path)
	}
	deadline := mono_ms() + timeout_ms
	for {
		got, got_ok := file_lock_try_acquire(path)
		if got_ok {
			return got, true
		}
		if mono_ms() >= deadline {
			return {}, false
		}
		time.sleep(time.Duration(LOCK_ACQUIRE_SLICE_MS) * time.Millisecond)
	}
}

// A single non-blocking attempt: F_SETLK either takes the lock or reports
// a rival holder via EACCES/EAGAIN (both surface as res < 0 here).
file_lock_try_acquire :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	c := to_cstring(path)
	fd := unix.sys_open(c, O_RDWR_CREAT | O_CLOEXEC_FLAG, 0o600)
	if fd < 0 {
		return {}, false
	}
	fl := Lock_Range{l_type = F_WRLCK_VAL, l_whence = 0, l_start = 0, l_len = 0}
	res := unix.sys_fcntl(fd, F_SETLK_CMD, cast(int)(uintptr(&fl)))
	if res < 0 {
		unix.sys_close(fd)
		return {}, false
	}
	return {fd = fd, path = path}, true
}

file_lock_release :: proc(lock: ^File_Lock) {
	fl := Lock_Range{l_type = F_UNLCK_VAL, l_whence = 0, l_start = 0, l_len = 0}
	unix.sys_fcntl(lock.fd, F_SETLK_CMD, cast(int)(uintptr(&fl)))
	unix.sys_close(lock.fd)
	lock.fd = -1
}

// Liveness probe for zombie-parent detection: true if a process with this
// pid exists (checked through /proc).
pid_alive :: proc(pid: int) -> bool {
	path := fmt.aprintf("/proc/%d", pid, allocator = context.temp_allocator)
	c := to_cstring(path)
	return unix.sys_access(c, 0 /* F_OK */) == 0
}

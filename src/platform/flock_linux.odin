#+build linux

// Singleton spawn lock (Linux): an exclusive whole-file fcntl write lock,
// acquired through the shared bounded poll (flock.odin) around one
// non-blocking F_SETLK attempt. darwin carries a bounded flock(2) poll
// (flock_darwin.odin) and Windows uses LockFileEx (flock_windows.odin).
package platform

import "core:fmt"
import "core:os"
import "core:sys/unix"

// fcntl record-lock commands on Linux. This file is linux-only; the darwin
// and windows locks live in flock_darwin.odin / flock_windows.odin.
F_SETLK_CMD :: 6

F_WRLCK_VAL :: u16(1)
F_UNLCK_VAL :: u16(2)

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

// A single non-blocking attempt: F_SETLK either takes the lock or reports
// a rival holder via EACCES/EAGAIN (both surface as res < 0 here). The
// open rides core:os, whose POSIX open defaults to O_CLOEXEC — the lock
// fd must not survive into spawned children.
file_lock_try_acquire :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	f, err := os.open(path, {.Write, .Read, .Create}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return {}, false
	}
	fd := int(os.fd(f))
	fl := Lock_Range{l_type = F_WRLCK_VAL, l_whence = 0, l_start = 0, l_len = 0}
	res := unix.sys_fcntl(fd, F_SETLK_CMD, cast(int)(uintptr(&fl)))
	if res < 0 {
		os.close(f)
		return {}, false
	}
	return {file = f}, true
}

// file_lock_release drops the lock and closes the descriptor — a nil-guarded
// no-op on an already-released lock, the same shape as the darwin and
// windows twins (the fcntl variant must not read os.fd through a nil file).
file_lock_release :: proc(lock: ^File_Lock) {
	if lock.file == nil {
		return
	}
	fl := Lock_Range{l_type = F_UNLCK_VAL, l_whence = 0, l_start = 0, l_len = 0}
	unix.sys_fcntl(int(os.fd(lock.file)), F_SETLK_CMD, cast(int)(uintptr(&fl)))
	os.close(lock.file)
	lock.file = nil
}

// Liveness probe for zombie-parent detection: true if a process with this
// pid exists (checked through /proc).
pid_alive :: proc(pid: int) -> bool {
	path := fmt.aprintf("/proc/%d", pid, allocator = context.temp_allocator)
	c := to_cstring(path)
	return unix.sys_access(c, 0 /* F_OK */) == 0
}

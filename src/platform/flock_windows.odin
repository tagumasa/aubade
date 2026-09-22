#+build windows

// Singleton spawn lock (Windows): an exclusive LockFileEx byte-range lock
// over the whole file — the same never-renamed, no-payload discipline as
// the POSIX fcntl variant, acquired through bounded immediate-fail retries
// (a blocking LockFileEx would let a wedged-but-alive holder block every
// future spawn forever). The handle comes from os.fd(), which extracts the
// raw HANDLE from the os.File; os.File.impl is a pointer to the internal
// File_Impl struct on Windows, not the handle itself.
package platform

import "core:os"
import "core:sys/windows"
import "core:time"

LOCK_ACQUIRE_BUDGET_MS :: 30_000
LOCK_ACQUIRE_SLICE_MS  :: 50

File_Lock :: struct {
	file: ^os.File,
}

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

file_lock_try_acquire :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	f, err := os.open(path, {.Write, .Read, .Create}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return {}, false
	}

	// Whole-file exclusive lock, immediate-fail (LOCKFILE_FAIL_IMMEDIATELY):
	// a rival holder surfaces as a failed call instead of an unbounded
	// block. LockFileEx requires an OVERLAPPED pointer; its offset fields
	// select the range, so a zeroed one with full-file lengths covers
	// everything.
	ov: windows.OVERLAPPED
	handle := windows.HANDLE(os.fd(f))
	ok_lock := windows.LockFileEx(
		handle,
		windows.LOCKFILE_EXCLUSIVE_LOCK | windows.LOCKFILE_FAIL_IMMEDIATELY,
		0,
		0xFFFF_FFFF,
		0xFFFF_FFFF,
		&ov,
	)
	if !ok_lock {
		os.close(f)
		return {}, false
	}
	return {file = f}, true
}

file_lock_release :: proc(lock: ^File_Lock) {
	if lock.file != nil {
		ov: windows.OVERLAPPED
		windows.UnlockFileEx(windows.HANDLE(os.fd(lock.file)), 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &ov)
		os.close(lock.file)
		lock.file = nil
	}
}

// pid_alive: a process handle proves existence; NULL means gone (or access
// denied, which for same-user daemons means gone).
PROCESS_QUERY_LIMITED_INFORMATION :: windows.DWORD(0x1000)

pid_alive :: proc(pid: int) -> bool {
	handle := windows.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, windows.DWORD(pid))
	if handle == nil {
		return false
	}
	windows.CloseHandle(handle)
	return true
}

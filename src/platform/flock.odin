// The singleton spawn lock's shared half: the bounded poll loop every
// platform's non-blocking try-acquire rides, with one budget everywhere
// (a wedged-but-alive holder must never wedge every future spawn; probe
// running tolerates the same wait). The per-OS halves — fcntl on Linux,
// flock(2) on darwin, LockFileEx on Windows (flock_linux.odin,
// flock_darwin.odin, flock_windows.odin) — provide file_lock_try_acquire
// and file_lock_release; the locking discipline (never renamed, no
// payload, kernel-arbitrated, released by the losing side's close) is
// common to all three.
package platform

import "core:os"
import "core:time"

LOCK_ACQUIRE_BUDGET_MS :: 30_000
LOCK_ACQUIRE_SLICE_MS  :: 50

File_Lock :: struct {
	file: ^os.File,
}

// Acquire the exclusive lock, retrying the platform's non-blocking
// attempt until the deadline (timeout_ms <= 0 is a single attempt). The
// lock file is created if missing. Returns ok=false when the deadline
// passed or the OS refused.
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

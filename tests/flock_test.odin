// Bounded spawn-lock acquisition: a held lock must fail within the budget
// (never block indefinitely behind a wedged-but-alive holder), and a
// released lock must be acquirable again.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "src:platform"

@(test)
flock_acquire_is_bounded :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-flock-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	path, _ := filepath.join([]string{dir, "spawn.lock"}, context.allocator)
	defer delete(path, context.allocator)

	held, ok := platform.file_lock_try_acquire(path)
	testing.expect(t, ok)

	// fcntl locks are per-process on Linux: a second acquire from this
	// same process replaces its own lock instead of conflicting, so the
	// held-lock rejection is only observable cross-process there. darwin
	// (O_EXCL create) and Windows (per-handle LockFileEx) reject it
	// in-process.
	when ODIN_OS != .Linux {
		_, bounded_ok := platform.file_lock_acquire(path, 120)
		testing.expect(t, !bounded_ok, "bounded acquire must fail while the lock is held")
	}

	platform.file_lock_release(&held)
	again, ok2 := platform.file_lock_acquire(path, 1000)
	testing.expect(t, ok2, "acquire must succeed after release")
	platform.file_lock_release(&again)
}

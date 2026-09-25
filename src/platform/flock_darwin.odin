#+build darwin

// Singleton spawn lock (darwin): an advisory flock(2) exclusive lock over
// the whole file, acquired through the shared bounded poll (flock.odin) —
// the same kernel-arbitrated, never-renamed, no-payload discipline as the
// Linux fcntl variant and the Windows LockFileEx one. The lock lives on
// the open file description, so a crashed holder releases it the moment
// its last descriptor closes: there is no pid to validate and no stale
// file to remove, which deletes the recovery race the previous
// O_EXCL+pid+remove design carried (a waiter's unlink could delete a
// fresh winner's lock between its liveness read and the remove, crowning
// two daemons for one project).
//
// The lock file is never unlinked: every contender opens and locks the
// same inode, and an unlink would fork the arbitration (the next opener
// would create a fresh inode and win instantly while a polling waiter
// still watches the old one). The flock operation codes are fixed BSD
// ABI in libSystem — the one constant surface this file needs. kill(pid,
// 0) stays the only other foreign call (the endpoint drain wait reads
// it; the lock itself never inspects pids).
package platform

import "core:os"

foreign import libsystem "system:System"

@(default_calling_convention = "c")
foreign libsystem {
	flock :: proc(fd: i32, operation: i32) -> i32 ---
	kill  :: proc(pid: i32, sig: i32) -> i32 ---
}

// flock(2) operations — stable since 4.2BSD, identical on macOS.
LOCK_EX :: i32(2)
LOCK_NB :: i32(4)

// One pass: open the lock file (created when missing) and take the
// exclusive lock without blocking. Both racing waiters hold descriptors
// on the same inode, and only the kernel decides who wins — a failed
// attempt means a live rival holds the lock, not a leftover to clean.
file_lock_try_acquire :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	f, err := os.open(path, {.Write, .Create}, os.Permissions{.Write_User, .Read_User})
	if err != nil {
		return {}, false
	}
	if flock(cast(i32)os.fd(f), LOCK_EX | LOCK_NB) != 0 {
		os.close(f)
		return {}, false
	}
	return {file = f}, true
}

file_lock_release :: proc(lock: ^File_Lock) {
	if lock.file != nil {
		// The lock releases with the descriptor; the file itself stays
		// for the next contender to open.
		os.close(lock.file)
		lock.file = nil
	}
}

// pid_alive: kill(pid, 0) delivers no signal and reports existence.
pid_alive :: proc(pid: int) -> bool {
	return kill(i32(pid), 0) == 0
}

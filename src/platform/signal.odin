// The stop-signal bridge: SIGINT/SIGTERM (POSIX) or a console close
// event (Windows) must land on the process's root cancel token as
// .Shutdown — cutting any grace window and running the global stop path
// (drain deadline, endpoint removal) instead of dying to the default
// disposition. A signal handler may only do async-signal-safe work, so
// the handler itself latches a flag — the one sanctioned static outside
// the hosts, next to the logger — and a small watcher thread fires the
// token and exits. Install exactly once per process, before the threads
// whose loops the stop must reach.
package platform

import "base:intrinsics"
import "core:mem"
import "core:thread"
import "core:time"

// Watch latency bound. A real-time sleep, not clock_wait: this thread
// owns no deadline logic, it only bounds how long a delivered signal may
// sit unlatched (the same short-slice pattern the idle monitor uses).
SIGNAL_WATCH_SLICE_MS :: 50

// Poll slice for stop_signals_wait_exited: how coarsely that parking loop
// samples the watcher's exit flag before the caller's timeout runs out.
SIGNAL_EXIT_WAIT_SLICE_MS :: 2

stop_requested: bool

// Signal_Wake is the optional unblock hook: a host whose main loop parks
// somewhere a fired token cannot reach (a blocking channel receive) gets
// it pried open here — called once, right after the token fired.
Signal_Wake :: proc(user: rawptr)

Signal_Watch_Box :: struct {
	root:      ^Cancel_Token,
	allocator: mem.Allocator,
	wake:      Signal_Wake,
	wake_user: rawptr,
	exited:    ^u32, // optional latch, set to 1 on the watcher's way out
}

// install_stop_signals registers the OS handlers and starts the watcher
// thread bound to `root`. False means the OS rejected the registration
// (the caller logs and carries on — the RPC stop path still works). The
// optional `exited` latch lets the process-exit path observe the watcher's
// departure before destroying the token the watcher polls (see
// stop_signals_wait_exited).
install_stop_signals :: proc(
	root: ^Cancel_Token,
	a := context.allocator,
	wake: Signal_Wake = nil,
	wake_user: rawptr = nil,
	exited: ^u32 = nil,
) -> bool {
	if !signal_register_handlers() {
		// A refused registration may still have replaced the default
		// disposition for the signals that took — restore it, or the
		// caller's "default termination" fallback is false: the handler
		// latches, and nothing observes the latch.
		signal_reset_handlers()
		return false
	}
	// A fresh install is a fresh latch: a stale true (an earlier cycle
	// in the same process, e.g. a test) would fire the new token
	// immediately.
	intrinsics.atomic_store_explicit(&stop_requested, false, .Release)
	box := new(Signal_Watch_Box, a)
	box^ = {root = root, allocator = a, wake = wake, wake_user = wake_user, exited = exited}
	// Self-cleaning: the thread frees its own resources when the watcher
	// returns, so there is no handle to join — its exit paths are "token
	// fired" and "root already fired", both process-shutdown moments.
	thr := thread.create_and_start_with_data(
		box, signal_watch_entry, self_cleanup = true, name = "aubade-signal-watch",
	)
	if thr == nil {
		free(box, a)
		// The handlers are in place but the watcher that fires the token
		// never starts: a delivered signal would latch the flag and
		// suppress the default termination instead of stopping anything.
		signal_reset_handlers()
		return false
	}
	return true
}

// reset_stop_signals restores the default dispositions and clears the
// latch — for tests that raise real signals inside the shared test
// process, so the runner itself stays killable afterwards.
reset_stop_signals :: proc() {
	signal_reset_handlers()
	intrinsics.atomic_store_explicit(&stop_requested, false, .Release)
}

signal_watch_entry :: proc(data: rawptr) {
	box := cast(^Signal_Watch_Box)data
	root := box.root
	alloc := box.allocator
	wake := box.wake
	wake_user := box.wake_user
	exited := box.exited
	free(box, alloc)
	for {
		if intrinsics.atomic_load_explicit(&stop_requested, .Acquire) {
			token_fire(root, .Shutdown)
			if wake != nil {
				wake(wake_user)
			}
			watch_note_exit(exited)
			return
		}
		if token_is_fired(root) {
			// The process is stopping through another path; do not
			// outlive it.
			watch_note_exit(exited)
			return
		}
		time.sleep(SIGNAL_WATCH_SLICE_MS * time.Millisecond)
	}
}

watch_note_exit :: proc(exited: ^u32) {
	if exited != nil {
		intrinsics.atomic_store_explicit(exited, 1, .Release)
	}
}

// stop_signals_wait_exited parks until the watcher has observed the fired
// root and left, or timeout_ms elapses (real-time slices by design — this
// is process-exit ordering, not request logic). False means it never left:
// the caller must NOT destroy the token the watcher still polls — leak it
// into process exit instead of racing the watcher's next check.
stop_signals_wait_exited :: proc(exited: ^u32, timeout_ms: i64) -> bool {
	if intrinsics.atomic_load_explicit(exited, .Acquire) == 1 {
		return true
	}
	deadline := mono_ms() + timeout_ms
	for intrinsics.atomic_load_explicit(exited, .Acquire) != 1 {
		if mono_ms() >= deadline {
			return false
		}
		time.sleep(SIGNAL_EXIT_WAIT_SLICE_MS * time.Millisecond)
	}
	return true
}

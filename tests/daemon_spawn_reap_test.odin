// spawn_reap_pending: a daemon spawn that loses the flock race exits
// within milliseconds, and the session child — which outlives it for the
// whole client session — must reap it. Driving the drain with a real
// short-lived process verifies handle tracking, non-blocking polling, and
// the actual reap (a zombie would keep the pid visible in /proc).
package tests

import "core:os"
import "core:testing"
import "core:time"

import "src:daemon"

@(test)
daemon_spawn_reap_pending_collects_exited :: proc(t: ^testing.T) {
	// POSIX-only end-to-end check (/bin/sh, /proc); Windows has no
	// zombies, and the drain there reduces to handle bookkeeping.
	when ODIN_OS == .Windows {
		return
	}

	desc: os.Process_Desc
	desc.command = {"/bin/sh", "-c", "exit 0"}
	started, err := os.process_start(desc)
	testing.expect(t, err == nil, "process_start must succeed")
	if err != nil {
		return
	}
	pending: [dynamic]os.Process
	defer delete(pending)
	append(&pending, started)

	// The shell exits in milliseconds; the drain must observe the exit
	// and drop the handle — the wait itself reaps and releases it.
	collected := false
	for _ in 0..<400 {
		daemon.spawn_reap_pending(&pending)
		if len(pending) == 0 {
			collected = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, collected, "an exited spawn must leave the pending list")

	// A true reap removes the pid from /proc entirely; a zombie would
	// keep the entry alive (the live observation behind this fix). The
	// /proc half lives in the linux-tagged twin file — fmt's only home
	// here.
	when ODIN_OS == .Linux {
		expect_proc_reaped(t, started.pid)
	}
}

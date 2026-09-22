// Parent spawn (simplified): the parent itself takes the spawn lock and
// probes for an existing listener, so children only dial, spawn on failure,
// and retry — the lock serializes concurrent parents without the child
// participating in the lock dance.
package daemon

import "core:fmt"
import "core:os"

import "src:platform"

NULL_DEVICE :: "/dev/null" when (ODIN_OS == .Linux || ODIN_OS == .Darwin) else "NUL"

// spawn_parent launches `aubade _daemon` for the project with the given
// timing parameters. stdio goes to the null device; the spawner does not
// wait. The started handle is returned for the caller to track: a daemon
// that loses the flock race (or exits early for any other reason) must be
// reaped by spawn_reap_pending, or it stays a zombie until the spawner —
// a client-session child that outlives it for the whole session — exits.
// Returns ok == false when the process could not be started.
spawn_parent :: proc(
	exe_path: string,
	cfg: Config,
	ping_ms, timeout_ms, grace_ms, drain_ms: i64,
) -> (ok: bool, handle: os.Process) {
	// The child must receive the NUL handle as its std streams; the
	// Windows inheritance marking is the spawn seam's business
	// (platform/spawn_windows.odin marks exactly the three stdio
	// handles around the spawn — an inheritable open here would ride
	// into unrelated concurrent children).
	null_out, err := os.open(NULL_DEVICE, {.Write}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return false, {}
	}

	args := make([dynamic]string, 0, context.temp_allocator)
	append(&args, exe_path)
	append(&args, "_daemon")
	append(&args, "--project")
	append(&args, cfg.project_root)
	append(&args, "--home")
	append(&args, cfg.home)
	if ping_ms != cfg.hb_ping_ms {
		append(&args, "--hb-ping-ms")
		append(&args, fmt_i64(ping_ms))
	}
	if timeout_ms != cfg.hb_timeout_ms {
		append(&args, "--hb-timeout-ms")
		append(&args, fmt_i64(timeout_ms))
	}
	if grace_ms != cfg.grace_ms {
		append(&args, "--grace-ms")
		append(&args, fmt_i64(grace_ms))
	}
	if drain_ms != cfg.drain_ms {
		append(&args, "--drain-ms")
		append(&args, fmt_i64(drain_ms))
	}

	desc: os.Process_Desc
	desc.command = args[:]
	desc.stdin = null_out
	desc.stdout = null_out
	desc.stderr = null_out

	started, perr := platform.spawn_start(desc)
	os.close(null_out)
	if perr != nil {
		delete(args)
		return false, {}
	}
	// No wait here: the winning daemon must outlive the spawner, and
	// blocking on it would deadlock the session. The caller tracks the
	// handle; spawn_reap_pending collects whatever exits (flock-race
	// losers, early deaths). The formatted flag strings die with the temp
	// storage of this thread.
	delete(args)
	return true, started
}

// spawn_reap_pending polls every tracked spawn with a non-blocking wait
// and stops tracking the ones that exited — the wait itself reaps the
// child and releases the platform handle (on Linux the pidfd). A process
// still running stays tracked; for the winning daemon that means until
// the spawner exits, whereupon the kernel closes what is left.
spawn_reap_pending :: proc(pending: ^[dynamic]os.Process) {
	i := 0
	for i < len(pending^) {
		state, werr := os.process_wait(pending^[i], timeout = 0)
		if state.exited || werr != .Timeout {
			last := len(pending^) - 1
			if i != last {
				pending^[i] = pending^[last]
			}
			pop(pending)
			continue
		}
		i += 1
	}
}

fmt_i64 :: proc(v: i64) -> string {
	return fmt.aprintf("%d", v, allocator = context.temp_allocator)
}

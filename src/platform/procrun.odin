// procrun: bounded child-process runner for tool-side command execution.
// Unlike os.process_exec it takes an explicit working directory and full
// child environment, caps each captured stream at max_stream_bytes while
// still draining it (so a noisy child cannot wedge the pipe), and kills a
// child that outlives timeout_ms while keeping whatever it produced.
package platform

import "core:os"
import "core:strings"
import "core:time"

PROCRUN_POLL :: 20 * time.Millisecond
PROCRUN_LINGER_POLL :: 100 * time.Millisecond
PROCRUN_KILL_IDLE_ROUNDS :: 50

// Budget for the post-loop reap of a child the poll loop abandoned (a
// SIGKILLed child normally dies within one poll; uninterruptible I/O is
// the only thing that outlasts this).
PROCRUN_REAP_BUDGET_MS :: i64(2_000)

Procrun_Opts :: struct {
	// argv of the child; command[0] is the executable.
	command: []string,
	// "" = inherit the caller's working directory.
	working_dir: string,
	// KEY=VALUE entries; nil = inherit the caller's environment.
	env: []string,
	// When false the child's stderr goes to the null device.
	capture_stderr: bool,
	// Per-stream capture cap in bytes (<= 0 = unlimited).
	max_stream_bytes: int,
	// Kill the child after this many milliseconds (0 = no timeout).
	timeout_ms: i64,
	// Cancel-token checkpoint: when non-nil and fired, the child is killed
	// at the next poll round (the discipline every blocking wait follows;
	// the timeout stays the outer bound). The result reports the cut-short
	// run through timed_out.
	token: ^Cancel_Token,
	// Run the child in its own containment and stop the whole tree on
	// timeout/cancel — a backgrounded job must not outlive the call that
	// spawned it, on normal exit any more than on a kill. POSIX builds
	// run the child through the proctree seam (own process group, group
	// kill, and a sweep of the group at return; Linux additionally walks
	// /proc for descendants that changed group and arms Pdeathsig so a
	// crashed daemon strands no orphans). Windows builds wrap the child
	// in a kill-on-close Job object (job_windows.odin): TerminateJobObject
	// on stop, and the handle close at return (or daemon death) is the
	// same sweep.
	process_group: bool,
}

Procrun_Result :: struct {
	// -1 when the run was killed by the timeout; otherwise the child's
	// exit status.
	exit_code: int,
	stdout:    string,
	stderr:    string,
	timed_out: bool,
}

procrun :: proc(opts: Procrun_Opts, allocator := context.allocator) -> (res: Procrun_Result, err: os.Error) {
	// The seam pipes and spawn keep the child's inheritance to its own
	// stdio on every platform (spawn_windows.odin / spawn_posix.odin).
	stdout_r, stdout_w, perr := spawn_pipe()
	if perr != nil {
		return {}, perr
	}

	stderr_r: ^os.File
	stderr_w: ^os.File
	if opts.capture_stderr {
		r, w, e := spawn_pipe()
		if e != nil {
			os.close(stdout_r)
			os.close(stdout_w)
			return {}, e
		}
		stderr_r, stderr_w = r, w
	}

	when ODIN_OS != .Windows {
		if opts.process_group {
			pid, gerr := proctree_spawn({
				command     = opts.command,
				working_dir = opts.working_dir,
				env         = opts.env,
				stdout_w    = stdout_w,
				stderr_w    = stderr_w if opts.capture_stderr else nil,
				// Linux: a crashed daemon must not strand the command
				// tree. The forking thread is a pool worker that lives
				// for the daemon's lifetime, so the signal fires on
				// daemon death (or a forced worker terminate, which
				// wants the tree dead anyway). darwin accepts and
				// ignores the flag.
				pdeathsig   = true,
			})
			// The child owns its descriptors once spawned; close this
			// side's write ends right after the spawn attempt so reads
			// see EOF.
			os.close(stdout_w)
			if opts.capture_stderr {
				os.close(stderr_w)
			}
			if gerr != nil {
				os.close(stdout_r)
				if opts.capture_stderr {
					os.close(stderr_r)
				}
				// The seam's closed vocabulary collapses to procrun's
				// os.Error surface: any spawn failure is "the command did
				// not start".
				return {}, os.Error(os.General_Error.Invalid_Command)
			}
			// procrun_run_group owns the read ends from here.
			return procrun_run_group(opts, allocator, pid, stdout_r, stderr_r)
		}
	}

	desc := os.Process_Desc {
		working_dir = opts.working_dir,
		command = opts.command,
		env = opts.env,
		stdout = stdout_w,
		stderr = stderr_w,
	}
	child, serr := spawn_start(desc)
	// The child owns its descriptors now; close this side's write ends in
	// both the success and failure cases so reads see EOF.
	os.close(stdout_w)
	if opts.capture_stderr {
		os.close(stderr_w)
	}
	if serr != nil {
		os.close(stdout_r)
		if opts.capture_stderr {
			os.close(stderr_r)
		}
		return {}, serr
	}

	// Windows group runs: wrap the fresh child in a kill-on-close Job so
	// the stop below lands on the whole tree. POSIX group runs went
	// through proctree_spawn above and never reach the direct path.
	stop_job := uintptr(0)
	when ODIN_OS == .Windows {
		if opts.process_group {
			stop_job = procrun_arm_stop_job(child)
		}
	}
	// With kill-on-close set, dropping the Job handle at return is also
	// the sweep that takes down stragglers the wait never saw. On POSIX
	// the release is the stop seam's no-op — the slot is always zero.
	defer procrun_release_stop_job(stop_job)

	defer os.close(stdout_r)
	defer if opts.capture_stderr {
		os.close(stderr_r)
	}

	out_buf := make([dynamic]u8, 0, 4096, allocator)
	err_buf := make([dynamic]u8, 0, 4096, allocator)
	defer delete(out_buf)
	defer delete(err_buf)

	state: os.Process_State
	killed := false
	idle_rounds := 0
	err_done := !opts.capture_stderr
	out_done := false
	deadline := mono_ms() + opts.timeout_ms

	buf: [4096]u8 = ---
	for {
		progress := false
		if !out_done {
			p, done := drain_into(stdout_r, buf[:], &out_buf, opts.max_stream_bytes)
			progress = progress || p
			out_done = done
		}
		if opts.capture_stderr && !err_done {
			p, done := drain_into(stderr_r, buf[:], &err_buf, opts.max_stream_bytes)
			progress = progress || p
			err_done = done
		}

		wait_ms := PROCRUN_POLL
		if out_done && err_done {
			wait_ms = PROCRUN_LINGER_POLL
		}
		st, werr := os.process_wait(child, wait_ms)
		if werr == nil {
			// The child is gone; pick up anything it wrote on its way out.
			if !out_done {
				_, out_done = drain_into(stdout_r, buf[:], &out_buf, opts.max_stream_bytes)
			}
			if opts.capture_stderr && !err_done {
				_, err_done = drain_into(stderr_r, buf[:], &err_buf, opts.max_stream_bytes)
			}
			state = st
			break
		}
		if werr != .Timeout {
			err = werr
			break
		}

		if opts.timeout_ms > 0 && !killed && mono_ms() >= deadline {
			// Kill once at the deadline. When the kill itself fails (the
			// child may already be exiting), keep waiting on the normal
			// reap path instead of claiming a timeout we did not cause.
			if procrun_kill_child(child, stop_job) == nil {
				killed = true
				res.timed_out = true
			}
		}
		if !killed && opts.token != nil {
			if _, fired := token_check(opts.token); fired {
				if procrun_kill_child(child, stop_job) == nil {
					killed = true
					res.timed_out = true
				}
			}
		}
		if killed {
			// SIGKILL is normally reaped within one poll; if something still
			// holds the pipes or the wait starves, stop lingering and keep
			// whatever was captured so far.
			if progress {
				idle_rounds = 0
			} else {
				idle_rounds += 1
				if idle_rounds >= PROCRUN_KILL_IDLE_ROUNDS {
					break
				}
			}
		}
	}

	// The wait-error and kill-linger breaks leave the child unreaped, and
	// this caller's process typically outlives the run by a long margin —
	// reap here, bounded: a SIGKILLed child dies within one poll unless
	// wedged in uninterruptible I/O, and procrun must return what it
	// captured rather than block on the wedged case.
	if !state.exited {
		reap_deadline := mono_ms() + PROCRUN_REAP_BUDGET_MS
		for {
			st, werr := os.process_wait(child, PROCRUN_LINGER_POLL)
			if werr == nil {
				state = st
				break
			}
			if werr != .Timeout || mono_ms() >= reap_deadline {
				break // reaped elsewhere, or unreapable past the budget
			}
		}
	}

	if err == nil {
		if state.exited {
			res.exit_code = state.exit_code
			if killed && !state.success {
				res.exit_code = -1
			}
		} else {
			res.exit_code = -1
		}
	}
	res.stdout = strings.clone(string(out_buf[:]), allocator)
	res.stderr = strings.clone(string(err_buf[:]), allocator)
	return res, err
}

when ODIN_OS != .Windows {
	// procrun_run_group is the process_group twin of the poll loop above:
	// the same drain cadence and idle-round bail-out, but the wait is a
	// WNOHANG probe paced by the poll sleep and the kill lands on the
	// child's process group (plus any escaped descendant through the /proc
	// tree walk). It owns the read ends it is handed.
	// The declaration itself carries the gate, not just the call in
	// procrun: the compiler type-checks unreached procedures too, so
	// the proctree seam must not surface in a build that lacks it.
	procrun_run_group :: proc(opts: Procrun_Opts, allocator := context.allocator, pid: int, stdout_r, stderr_r: ^os.File) -> (res: Procrun_Result, err: os.Error) {
		out_buf := make([dynamic]u8, 0, 4096, allocator)
		err_buf := make([dynamic]u8, 0, 4096, allocator)
		defer delete(out_buf)
		defer delete(err_buf)

		defer os.close(stdout_r)
		defer if opts.capture_stderr {
			os.close(stderr_r)
		}

		killed := false
		idle_rounds := 0
		err_done := !opts.capture_stderr
		out_done := false
		deadline := mono_ms() + opts.timeout_ms
		exited := false
		exit_code := 0

		buf: [4096]u8 = ---
		for {
			progress := false
			if !out_done {
				p, done := drain_into(stdout_r, buf[:], &out_buf, opts.max_stream_bytes)
				progress = progress || p
				out_done = done
			}
			if opts.capture_stderr && !err_done {
				p, done := drain_into(stderr_r, buf[:], &err_buf, opts.max_stream_bytes)
				progress = progress || p
				err_done = done
			}

			if e, code := proctree_try_wait(pid); e {
				// The child is gone; pick up anything it wrote on its way out.
				if !out_done {
					_, out_done = drain_into(stdout_r, buf[:], &out_buf, opts.max_stream_bytes)
				}
				if opts.capture_stderr && !err_done {
					_, err_done = drain_into(stderr_r, buf[:], &err_buf, opts.max_stream_bytes)
				}
				exited = true
				exit_code = code
				break
			}
			wait_ms := PROCRUN_POLL
			if out_done && err_done {
				wait_ms = PROCRUN_LINGER_POLL
			}
			// The probe does not block; pace the poll round. Real-time sleep
			// by design: only its length bounds wake latency, the deadline
			// arithmetic reads the monotonic clock.
			time.sleep(wait_ms)

			if opts.timeout_ms > 0 && !killed && mono_ms() >= deadline {
				// Kill once at the deadline — the whole group. When the kill
				// itself fails (the child may already be exiting), keep
				// waiting on the normal reap path instead of claiming a
				// timeout we did not cause.
				if proctree_kill_group(pid, .KILL) {
					killed = true
					res.timed_out = true
				}
			}
			if !killed && opts.token != nil {
				if _, fired := token_check(opts.token); fired {
					if proctree_kill_group(pid, .KILL) {
						killed = true
						res.timed_out = true
					}
				}
			}
			if killed {
				// SIGKILL is normally reaped within one poll; if something
				// still holds the pipes or the wait starves, stop lingering
				// and keep whatever was captured so far.
				if progress {
					idle_rounds = 0
				} else {
					idle_rounds += 1
					if idle_rounds >= PROCRUN_KILL_IDLE_ROUNDS {
						break
					}
				}
			}
		}

		// The kill-linger break leaves the child unreaped — reap here,
		// bounded, exactly like the direct path.
		if !exited {
			reap_deadline := mono_ms() + PROCRUN_REAP_BUDGET_MS
			for {
				if e, code := proctree_try_wait(pid); e {
					exited = true
					exit_code = code
					break
				}
				if mono_ms() >= reap_deadline {
					break
				}
				time.sleep(PROCRUN_LINGER_POLL)
			}
		}

		// The straggler sweep: the run is over, so nothing the tree left
		// behind may outlive it — the same guarantee the Windows twin gets
		// from the Job handle's kill-on-close at procrun return. By here
		// the leader is reaped (normal exit) or already kill-targeted
		// (timeout, cancel, or wedged past the reap budget), so the group
		// signal lands on the members it leaves behind (sh 'sleep 30 &'),
		// never on a leader whose output is still being captured.
		_ = proctree_kill_group(pid, .KILL)

		if exited {
			res.exit_code = exit_code // -1 when the death was a signal
		} else {
			res.exit_code = -1
		}
		res.stdout = strings.clone(string(out_buf[:]), allocator)
		res.stderr = strings.clone(string(err_buf[:]), allocator)
		return res, nil
	}
}

// drain_into moves every byte currently available on the pipe into out,
// respecting the capture cap but always consuming, and reports whether the
// pipe reached EOF.
drain_into :: proc(r: ^os.File, buf: []u8, out: ^[dynamic]u8, cap_bytes: int) -> (progress: bool, done: bool) {
	for {
		has, herr := os.pipe_has_data(r)
		if herr != nil || !has {
			return progress, herr != nil
		}
		n, rerr := os.read(r, buf)
		if n > 0 {
			progress = true
			if cap_bytes <= 0 || len(out^) < cap_bytes {
				room := n
				if cap_bytes > 0 {
					room = min(n, cap_bytes - len(out^))
				}
				append(out, ..buf[:room])
			}
		}
		if rerr != nil {
			return progress, true
		}
		if n == 0 {
			return progress, false
		}
	}
}

#+build windows

// Windows platform seam: core:os process_start for the child (the
// spawned image may be a .cmd/.bat launcher — CreateProcess starts the
// interpreter for those itself), taskkill /T for the explicit tree kill
// (the OS walks the tree natively), and a Job object per child as the
// containment (platform/job_windows.odin owns the primitives):
// kill-on-close ties every member's lifetime to the daemon's handle
// table, so a daemon crash cannot strand an orphaned server (the analog
// of the Linux seam's Pdeathsig), and the job memory limit makes the
// tree's allocations fail once it passes its cap (the cgroup
// memory.max analog, with fail-the-allocation enforcement instead of
// the OOM kill).
//
// Compile-verified by cross-target check on Linux; runtime verification
// happens on Windows hosts (the CI matrix).
package lsproc

import "core:mem"
import "core:os"
import "core:sys/windows"

import "src:platform"
import "src:util"

Platform_State :: struct {
	child:     os.Process, // owns the reaped handle semantics of core:os
	job:       windows.HANDLE, // containment job; nil = none; closing it kills the tree

	stdin_w:   ^os.File, // parent's write end; nil = closed
	stdout_r:  ^os.File, // parent's read ends
	stderr_r:  ^os.File,
	allocator: mem.Allocator,
}

platform_state_new :: proc(a: mem.Allocator) -> ^Platform_State {
	s := new(Platform_State, a)
	s^ = {allocator  = a}
	return s
}

platform_state_destroy :: proc(s: ^Platform_State) {
	if s.stdin_w != nil {
		os.close(s.stdin_w)
	}
	if s.stdout_r != nil {
		os.close(s.stdout_r)
	}
	if s.stderr_r != nil {
		os.close(s.stderr_r)
	}
	if s.job != nil {
		// The watcher released containment already; a straggler here
		// means nobody ran the release — close best effort anyway.
		platform.job_close(s.job)
	}
	free(s, s.allocator)
}

platform_spawn :: proc(l: ^Launch, p: ^Proc) -> platform.Err {
	// The seam pipes and spawn keep the child's inheritance to its own
	// stdio: without them every running server's pipe set rides into
	// each spawned child (core marks pipe ends inheritable and spawns
	// with bInheritHandles=true), and a strayed stdin write end holds
	// the pipe off EOF past the daemon's own close.
	stdin_r, stdin_w, e1 := platform.spawn_pipe()
	stdout_r, stdout_w, e2 := platform.spawn_pipe()
	stderr_r, stderr_w, e3 := platform.spawn_pipe()
	if e1 != nil || e2 != nil || e3 != nil {
		close_file(stdin_r)
		close_file(stdin_w)
		close_file(stdout_r)
		close_file(stdout_w)
		close_file(stderr_r)
		close_file(stderr_w)
		return platform.Err(.Internal)
	}

	env := l.env
	if env == nil {
		environ, _ := os.environ(context.temp_allocator)
		env = environ
	}
	desc := os.Process_Desc{
		working_dir = l.working_dir,
		command     = l.command,
		env         = env,
		stdin       = stdin_r,
		stdout      = stdout_w,
		stderr      = stderr_w,
	}
	child, serr := platform.spawn_start(desc)
	// The child owns its ends now, in both outcomes.
	close_file(stdin_r)
	close_file(stdout_w)
	close_file(stderr_w)
	if serr != nil {
		close_file(stdin_w)
		close_file(stdout_r)
		close_file(stderr_r)
		return platform.Err(.NotFound)
	}

	p.pid = child.pid
	p.state.child = child
	p.state.stdin_w = stdin_w
	p.state.stdout_r = stdout_r
	p.state.stderr_r = stderr_r
	return nil
}

close_file :: proc(f: ^os.File) {
	if f != nil {
		os.close(f)
	}
}

// platform_wait_exit blocks until the child is reaped through core:os
// (the stored Process carries the handle); -1 = killed by a signal.
platform_wait_exit :: proc(p: ^Proc) -> int {
	state, err := os.process_wait(p.state.child, -1)
	if err != nil {
		return -1
	}
	if state.exited {
		return state.exit_code
	}
	return -1
}

// platform_kill_tree runs taskkill /T (the OS expands the tree). /F is
// the force form used for the KILL stage.
platform_kill_tree :: proc(pid: int, kind: Signal_Kind) {
	pid_text := util.int_to_dec(pid, context.temp_allocator)
	command := []string{"taskkill", "/T", "/PID", pid_text}
	if kind == .KILL {
		command = []string{"taskkill", "/T", "/F", "/PID", pid_text}
	}
	opts := platform.Procrun_Opts{
		command = command,
		// Bounded: a wedged taskkill must cost one stage slice, never
		// the whole staged stop (the Job kill-on-close remains the
		// backstop).
		timeout_ms = HELPER_RUN_TIMEOUT_MS,
	}
	_, _ = platform.procrun(opts, context.temp_allocator)
}

// platform_child_pids: enumeration by pid alone has no cheap route here
// (the job's process list hangs off the job handle, not the pid, and
// the toolhelp snapshots cost a full system walk). Diagnostics lose
// little: the tree kill goes through taskkill /T, and the job's
// kill-on-close owns every straggler the tree walk could miss.
platform_child_pids :: proc(pid: int, a := context.allocator) -> []int {
	return nil
}

// platform_containment_setup moves the fresh child into an anonymous
// Job object with kill-on-close and a job-wide memory ceiling (the
// primitives live in platform/job_windows.odin). The daemon's handle
// table owns the group: when the daemon dies, the last job handle
// closes with it and the kernel takes every member down — the orphan
// containment the Linux seam gets from Pdeathsig. Past the ceiling the
// tree's allocations fail (the kernel enforces at commit time; there is
// no OOM-kill flavor to ask for). Best effort: without the job the
// server runs uncontained, observable through lsproc_contained. The
// child handle is consumed only here — the exit wait that closes it
// starts with the watcher, which is created after this setup returns.
platform_containment_setup :: proc(p: ^Proc, limit_mb: int, language: string) -> bool {
	job := platform.job_create(limit_mb)
	if job == nil {
		return false
	}
	if !platform.job_assign(job, p.state.child) {
		platform.job_close(job)
		return false
	}
	p.state.job = job
	return true
}

// platform_containment_release drops the job handle once the child is
// dead (the watcher calls it after the exit wait; the spawn-failure
// path calls it after the kill). With kill-on-close set, the close is
// also the sweep that reaps a straggler which outlived the server root:
// the group's lifetime ends with aubade's management of it, never with
// an orphan.
platform_containment_release :: proc(p: ^Proc) {
	if p.state.job != nil {
		platform.job_close(p.state.job)
		p.state.job = nil
	}
}

platform_contained :: proc(p: ^Proc) -> bool {
	return p.state.job != nil
}

// platform stream accessors. The _locked suffix means the caller holds
// p.mu — true only for close_stdin (lsproc_stop calls it between its wait
// stages). The stream I/O accessors are deliberately lock-free: each end
// has one owning thread (stdin writes go through the jsonrpc writer,
// stdout belongs to the reader thread, stderr to the pump), and a stop or
// death racing the I/O surfaces as a failed os.read/os.write or EOF at
// the handle level, never as a mutex ordering.

platform_close_stdin_locked :: proc(p: ^Proc) {
	if p.state.stdin_w != nil {
		os.close(p.state.stdin_w)
		p.state.stdin_w = nil
	}
}

platform_write_stdin :: proc(p: ^Proc, buf: []u8) -> int {
	if p.state.stdin_w == nil {
		return -1
	}
	n, err := os.write(p.state.stdin_w, buf)
	if err != nil {
		return -1
	}
	return n
}

platform_read_stdout :: proc(p: ^Proc, buf: []u8) -> (int, bool) {
	if p.state.stdout_r == nil {
		return 0, true
	}
	n, err := os.read(p.state.stdout_r, buf)
	if err != nil || n == 0 {
		os.close(p.state.stdout_r)
		p.state.stdout_r = nil
		return 0, true
	}
	return n, false
}

platform_read_stderr :: proc(p: ^Proc, buf: []u8) -> (int, bool) {
	if p.state.stderr_r == nil {
		return 0, true
	}
	n, err := os.read(p.state.stderr_r, buf)
	if err != nil || n == 0 {
		os.close(p.state.stderr_r)
		p.state.stderr_r = nil
		return 0, true
	}
	return n, false
}

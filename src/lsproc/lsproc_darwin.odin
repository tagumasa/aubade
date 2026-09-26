#+build darwin

// macOS platform seam: raw fork/exec through core:sys/posix with setpgid,
// pgrep-based tree kill, and two containments standing in for what Linux
// gets from Pdeathsig + cgroups: a death sitter (an out-of-process
// observer forked per server — EOF on the daemon-owned life pipe means
// the daemon died, and the sitter kills the server's process group) and
// an RSS watchdog (polling is the only memory enforcement macOS offers;
// the kernel-side guarantee the Linux cgroup path has does not exist
// here).
//
// Verified by cross-target check; runtime verification happens on the CI
// macOS runners.
package lsproc

import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"

import "src:platform"
import "src:util"

WATCHDOG_POLL_MS :: i64(250)

Platform_State :: struct {
	stdin_w:       posix.FD, // parent's write end; -1 = closed
	stdout_r:      posix.FD, // parent's read ends
	stderr_r:      posix.FD,
	life_w:        posix.FD, // death sitter's life pipe, daemon's write end; -1 = none
	sitter:        int,      // death sitter pid; 0 = none
	is_contained:  bool,
	watchdog:      ^thread.Thread,
	is_watchdog_on: bool, // stop flag; cleared by platform_state_destroy
	allocator:     mem.Allocator,
}

platform_state_new :: proc(a: mem.Allocator) -> ^Platform_State {
	s := new(Platform_State, a)
	s^ = {
		stdin_w  = -1,
		stdout_r = -1,
		stderr_r = -1,
		life_w   = -1,
		allocator  = a,
	}
	return s
}

platform_state_destroy :: proc(s: ^Platform_State) {
	s.is_watchdog_on = false // the watchdog observes this at its next tick
	if s.watchdog != nil {
		thread.join(s.watchdog) // it parks in clock_wait(250ms) at most
		free(s.watchdog, s.allocator)
	}
	// When the watcher released containment already this is a no-op
	// (life_w is -1); a straggler here means the release path never ran —
	// stand the sitter down anyway or it lingers until the daemon's death.
	stand_down_sitter(s)
	if s.stdin_w >= 0 {
		_ = posix.close(s.stdin_w)
	}
	if s.stdout_r >= 0 {
		_ = posix.close(s.stdout_r)
	}
	if s.stderr_r >= 0 {
		_ = posix.close(s.stderr_r)
	}
	free(s, s.allocator)
}

resolve_executable :: proc(command0: string, a: mem.Allocator) -> (cstring, platform.Err) {
	if strings.index_byte(command0, '/') >= 0 {
		c := to_cstr(command0, a)
		if posix.access(c, {.X_OK}) != .OK {
			return nil, platform.Err(.NotFound)
		}
		return c, nil
	}
	path_env := os.get_env("PATH", a)
	if path_env == "" {
		return nil, platform.Err(.NotFound)
	}
	for len(path_env) > 0 {
		dir := path_env
		if i := strings.index_byte(path_env, ':'); i >= 0 {
			dir = path_env[:i]
			path_env = path_env[i + 1:]
		} else {
			path_env = ""
		}
		candidate := strings.concatenate({dir, "/", command0}, a)
		c := to_cstr(candidate, a)
		if posix.access(c, {.X_OK}) == .OK {
			return c, nil
		}
	}
	return nil, platform.Err(.NotFound)
}

platform_spawn :: proc(l: ^Launch, p: ^Proc) -> platform.Err {
	a := context.temp_allocator

	exe, err := resolve_executable(l.command[0], a)
	if err != nil {
		return err
	}
	cargs := make([]cstring, len(l.command) + 1, a)
	for arg, i in l.command {
		cargs[i] = to_cstr(arg, a)
	}
	env, eerr := spawn_env_cstrings(l, a)
	if eerr != nil {
		return eerr
	}

	// Initialized to -1 (not the zero value): a zero-value entry is the
	// real fd 0, and the pipe-failure cleanup below closes every array —
	// pipes pipe() never created must read as "no descriptor" (the Linux
	// seam's close-on-failure hazard, mirrored here).
	stdin_fds := [2]posix.FD{-1, -1}
	stdout_fds := [2]posix.FD{-1, -1}
	stderr_fds := [2]posix.FD{-1, -1}
	err_fds := [2]posix.FD{-1, -1}
	if posix.pipe(&stdin_fds) != .OK || posix.pipe(&stdout_fds) != .OK ||
	   posix.pipe(&stderr_fds) != .OK || posix.pipe(&err_fds) != .OK {
		close_fds(&stdin_fds)
		close_fds(&stdout_fds)
		close_fds(&stderr_fds)
		close_fds(&err_fds)
		return platform.Err(.Internal)
	}
	defer close_fds(&err_fds)

	// Darwin has no pipe2 in this core version, and plain pipe() fds are
	// not close-on-exec (the Linux seam gets that from pipe2(.CLOEXEC)):
	// mark every descriptor FD_CLOEXEC before the fork. Descriptor flags
	// are per-descriptor and fork copies inherit them, so in the child
	// all eight pipe fds vanish at a successful execve — the parent's
	// exec-failure read below gets its EOF exactly like on Linux, and the
	// spawned process does not inherit stray pipe write ends that would
	// keep its stdin open past the parent's close. dup2 clears the flag
	// on the std destinations, so the child's 0/1/2 survive exec.
	pipes := [4][2]posix.FD{
		stdin_fds, stdout_fds, stderr_fds, err_fds,
	}
	for pair in pipes {
		for fd in pair {
			_ = posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
		}
	}

	cwd := to_cstr(".", a)
	if l.working_dir != "" {
		cwd = to_cstr(l.working_dir, a)
	}

	switch pid := posix.fork(); pid {
	case -1:
		close_fds(&stdin_fds)
		close_fds(&stdout_fds)
		close_fds(&stderr_fds)
		return platform.Err(.Internal)

	case 0:
		// Child: raw libc calls only.
		_ = posix.setpgid(0, 0)
		_ = posix.dup2(stdin_fds[0], posix.STDIN_FILENO)
		_ = posix.dup2(stdout_fds[1], posix.STDOUT_FILENO)
		_ = posix.dup2(stderr_fds[1], posix.STDERR_FILENO)
		if posix.chdir(cwd) != .OK {
			child_abort(&err_fds)
		}
		if posix.execve(exe, &cargs[0], env) == -1 {
			child_abort(&err_fds)
		}

	case:
		// Parent: the child owns its ends now. The exec-error pipe's
		// parent write end must close HERE — the read below only sees
		// EOF when every write end is gone, and the parent's own copy
		// would hold it open forever (same contract as the Linux seam).
		_ = posix.close(stdin_fds[0])
		_ = posix.close(stdout_fds[1])
		_ = posix.close(stderr_fds[1])
		_ = posix.close(err_fds[1])
		err_fds[1] = -1

		// exec-failure pipe (same contract as the Linux seam): the errno
		// byte means the child already exited(126) — reap it so nothing
		// zombies (the pid is never registered with the watcher on this
		// path, so nobody else will). No WNOWAIT: that flag LEAVES the
		// child waitable instead of reaping it. EINTR retries, like the
		// Linux seam: an interrupted read must not read as a clean exec.
		err_byte := [1]u8{0}
		n := posix.read(err_fds[0], &err_byte[0], 1)
		for n == -1 && posix.errno() == .EINTR {
			n = posix.read(err_fds[0], &err_byte[0], 1)
		}
		if n == 1 {
			info: posix.siginfo_t
			_ = posix.waitid(.P_PID, cast(posix.id_t)pid, &info, {.EXITED})
			_ = posix.close(stdin_fds[1])
			_ = posix.close(stdout_fds[0])
			_ = posix.close(stderr_fds[0])
			return platform.Err(.NotFound)
		}

		p.pid = int(pid)
		p.state.stdin_w = stdin_fds[1]
		p.state.stdout_r = stdout_fds[0]
		p.state.stderr_r = stderr_fds[0]
	}
	return nil
}

child_abort :: proc(err_fds: ^[2]posix.FD) {
	errno := u8(posix.errno())
	_ = posix.write(err_fds[1], &errno, 1)
	posix.exit(126)
}

close_fds :: proc(fds: ^[2]posix.FD) {
	if fds[0] >= 0 {
		_ = posix.close(fds[0])
	}
	if fds[1] >= 0 {
		_ = posix.close(fds[1])
	}
}

// platform_wait_exit blocks until the child is reaped. Raw waitid, not
// core's os.process_wait: on darwin that entry validates the Process
// handle (the proc start time from proc_pid_rusage) and a hand-built
// Process{pid = ...} carries handle 0, which never matches — every wait
// would return ESRCH and read as exit code -1. waitid(.EXITED) reaps and
// reports in one call; -1 = killed by a signal.
platform_wait_exit :: proc(p: ^Proc) -> int {
	info: posix.siginfo_t
	for {
		wpid := posix.waitid(.P_PID, cast(posix.id_t)p.pid, &info, {.EXITED})
		if wpid == -1 {
			if posix.errno() == .EINTR {
				continue
			}
			return -1
		}
		break
	}
	switch info.si_code.chld {
	case .EXITED:
		return int(info.si_status)
	case .KILLED, .DUMPED, .TRAPPED, .STOPPED, .CONTINUED:
		// Signal death or a non-exit event reads as -1.
		return -1
	}
	return -1
}

// platform_kill_tree signals the root and every descendant (children via
// pgrep -P, recursively).
platform_kill_tree :: proc(pid: int, kind: Signal_Kind) {
	sig := "-TERM"
	if kind == .KILL {
		sig = "-KILL"
	}
	children := pgrep_children(pid, context.temp_allocator)
	defer delete(children, context.temp_allocator)
	for c in children {
		kill_one(c, sig)
	}
	kill_one(pid, sig)
}

kill_one :: proc(pid: int, sig: string) {
	pid_text := util.int_to_dec(pid, context.temp_allocator)
	opts := platform.Procrun_Opts{
		command  = {"/bin/kill", sig, pid_text},
		// Bounded: a wedged kill must cost one stage slice, never the
		// whole staged stop.
		timeout_ms = HELPER_RUN_TIMEOUT_MS,
	}
	_, _ = platform.procrun(opts, context.temp_allocator)
}

// platform_child_pids snapshots descendant pids via pgrep -P.
platform_child_pids :: proc(pid: int, a := context.allocator) -> []int {
	return pgrep_children(pid, a)
}

// pgrep_children snapshots a pid's descendants via pgrep -P, recursively.
// Returns a PLAIN slice on `a` (delete(x, a) frees it) — the Linux seam's
// contract; a dynamic's slice view cannot be freed that way, and the
// recursion frees each child query's result instead of stranding it.
pgrep_children :: proc(pid: int, a: mem.Allocator) -> []int {
	pid_text := util.int_to_dec(pid, context.temp_allocator)
	opts := platform.Procrun_Opts{
		command        = {"/usr/bin/pgrep", "-P", pid_text},
		capture_stderr = false,
		// Bounded: a wedged pgrep must degrade the tree kill to the
		// root-only form, not wedge the caller.
		timeout_ms     = HELPER_RUN_TIMEOUT_MS,
	}
	res, _ := platform.procrun(opts, a)
	out := make([dynamic]int, 0, 4, a)
	fields, _ := strings.fields(res.stdout, a)
	for field in fields {
		if child, ok := strconv.parse_int(field, 10); ok {
			append(&out, int(child))
			kids := pgrep_children(int(child), a)
			for gc in kids {
				append(&out, gc)
			}
			delete(kids, a)
		}
	}
	result := make([]int, len(out), a)
	for v, i in out {
		result[i] = v
	}
	delete(out)
	return result
}

// --- containments -----------------------------------------------------------

// platform_containment_setup arms both macOS containments: the death
// sitter (orphan protection — the Pdeathsig analog, start_death_sitter
// below) and the RSS watchdog (the memory ceiling). Each is best effort;
// containment counts as armed when at least one is.
platform_containment_setup :: proc(p: ^Proc, limit_mb: int, language: string) -> bool {
	sitter_armed := start_death_sitter(p)
	watchdog_armed := start_rss_watchdog(p, limit_mb)
	p.state.is_contained = sitter_armed || watchdog_armed
	return p.state.is_contained
}

// start_rss_watchdog starts the thread that enforces the per-language
// memory ceiling: every WATCHDOG_POLL_MS it samples the child's resident
// set via ps and kills the tree when the limit is exceeded. A polling
// safety net, not the kernel-side ceiling the Linux cgroup path provides.
start_rss_watchdog :: proc(p: ^Proc, limit_mb: int) -> bool {
	p.state.is_watchdog_on = true
	args := new(Watchdog_Args, p.state.allocator)
	args^ = {proc_ = p, limit_kb = cast(i64)limit_mb * 1024}
	p.state.watchdog = thread.create_and_start_with_data(
		args, watchdog_entry, self_cleanup = false, name = "lsproc-watchdog",
	)
	if p.state.watchdog == nil {
		free(args, p.state.allocator)
		p.state.is_watchdog_on = false
		return false
	}
	return true
}

// --- Death sitter (the orphan containment) ----------------------------------
//
// macOS has no Pdeathsig: nothing the child can arm survives exec, and a
// daemon-side thread dies with the daemon. The only observer that
// outlives the daemon is another process, so containment forks one per
// server: the sitter holds the read end of a life pipe whose write end
// the daemon owns. EOF on that pipe means every write end is gone — the
// daemon died — and the sitter kills the server's process group
// (setpgid(0,0) made the server its own group leader; its descendants
// inherited the group, and processes that escape the group are beyond a
// raw-syscall observer, the same class Linux's Pdeathsig also misses).
// A one-byte stand-down from containment release retires the sitter on
// the normal path; launchd reaps it when the daemon died first.

start_death_sitter :: proc(p: ^Proc) -> bool {
	life_fds := [2]posix.FD{-1, -1}
	if posix.pipe(&life_fds) != .OK {
		return false
	}
	// CLOEXEC before the fork: fd flags are visible process-wide
	// immediately, so a server another thread spawns mid-setup execs the
	// pipe away instead of holding a sibling sitter's write end — a held
	// write end would delay that sitter's EOF past the daemon's death.
	// The sitter itself never execs, so its read end keeps the flag
	// harmlessly.
	for fd in life_fds {
		_ = posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	// Value copy: the sitter child reads its COW snapshot after the fork
	// — no pointer into the daemon's heap, no lock.
	server_pid := p.pid
	switch sp := posix.fork(); sp {
	case -1:
		_ = posix.close(life_fds[0])
		_ = posix.close(life_fds[1])
		return false
	case 0:
		death_sitter_entry(life_fds[0], server_pid)
	case:
		_ = posix.close(life_fds[0])
		p.state.life_w = life_fds[1]
		p.state.sitter = int(sp)
		return true
	}
	return false
}

// death_sitter_entry runs in the forked sitter: raw libc calls only —
// no allocation, no locks (the daemon's threads exist only in the daemon
// now; a malloc or lock here can deadlock on a fork-copied mutex).
death_sitter_entry :: proc(life_r: posix.FD, server_pid: int) {
	// Close every descriptor except the life pipe's read end: the fork
	// inherited the daemon's whole table — listener sockets, the server's
	// pipes, sibling sitters' life pipes (including this pipe's own
	// write end, which would hold the EOF off forever). Anything kept
	// open here outlives the daemon in the wrong process.
	rl: posix.rlimit
	if posix.getrlimit(.NOFILE, &rl) == .OK {
		for fd := 0; fd < int(rl.rlim_cur); fd += 1 {
			if cast(posix.FD)fd != life_r {
				_ = posix.close(cast(posix.FD)fd)
			}
		}
	}
	for {
		byte := [1]u8{0}
		n := posix.read(life_r, &byte[0], 1)
		if n == 1 {
			posix.exit(0) // stand-down: release already reaped the server
		}
		if n == 0 {
			// EOF: the daemon died. Kill the server's whole process
			// group, descendants included.
			_ = posix.kill(cast(posix.pid_t)(-server_pid), .SIGKILL)
			posix.exit(0)
		}
		if posix.errno() != .EINTR {
			posix.exit(0) // pipe broken — nothing left to watch for
		}
	}
}

// stand_down_sitter retires the sitter on a daemon-alive path: the byte
// wakes it and it exits without killing; the blocking reap keeps it from
// zombieing — the daemon is its parent, so nobody else will. No-op when
// no sitter was armed.
stand_down_sitter :: proc(s: ^Platform_State) {
	if s.life_w < 0 {
		return
	}
	byte := [1]u8{'D'}
	_ = posix.write(s.life_w, &byte[0], 1)
	_ = posix.close(s.life_w)
	s.life_w = -1
	if s.sitter != 0 {
		info: posix.siginfo_t
		for {
			w := posix.waitid(.P_PID, cast(posix.id_t)s.sitter, &info, {.EXITED})
			if w != -1 || posix.errno() != .EINTR {
				break
			}
		}
		s.sitter = 0
	}
}

Watchdog_Args :: struct {
	proc_:    ^Proc,
	limit_kb: i64,
}

watchdog_entry :: proc(data: rawptr) {
	args := cast(^Watchdog_Args)data
	p := args.proc_
	defer free(args, p.state.allocator)
	for {
		sync.mutex_lock(&p.mu)
		on := p.state.is_watchdog_on
		exited := p.is_exited
		sync.mutex_unlock(&p.mu)
		if !on || exited {
			return
		}
		platform.clock_wait(p.clock, WATCHDOG_POLL_MS)
		// One ps sample per tick: it decides both liveness (ps that ran
		// and listed nothing = gone) and the limit. A failed or timed-out
		// sample carries no evidence — skip the tick, keep containment.
		rss, gone := proc_rss_kb(p)
		if gone {
			return
		}
		if rss > args.limit_kb {
			platform_kill_tree(p.pid, .KILL)
			return
		}
		// Per-tick temp reset (the dispatch threads' idiom): both ps
		// samples build their scratch on temp, and this loop ticks for
		// the lifetime of every spawned server.
		free_all(context.temp_allocator)
	}
}

// proc_rss_kb samples the resident set through ps (Activity Monitor's own
// source). gone reports what the sample proves: only a ps that ran and
// listed nothing means the process is dead — a failed or timed-out ps is
// no evidence either way, so the caller skips the tick instead of
// disarming containment.
proc_rss_kb :: proc(p: ^Proc) -> (rss_kb: i64, gone: bool) {
	pid_text := util.int_to_dec(p.pid, context.temp_allocator)
	opts := platform.Procrun_Opts{
		command = {"/bin/ps", "-o", "rss=", "-p", pid_text},
		// Bounded: a wedged ps must cost one tick, never the watchdog
		// thread.
		timeout_ms = HELPER_RUN_TIMEOUT_MS,
	}
	res, err := platform.procrun(opts, context.temp_allocator)
	if err != nil || res.timed_out {
		return 0, false
	}
	fields, _ := strings.fields(res.stdout, context.temp_allocator)
	if len(fields) == 0 {
		return 0, true
	}
	rss, ok := strconv.parse_int(fields[0], 10)
	if !ok {
		return 0, false
	}
	return cast(i64)rss, false
}

platform_containment_release :: proc(p: ^Proc) {
	stand_down_sitter(p.state)
	p.state.is_contained = false // the watchdog exits on the exited flag
}

platform_contained :: proc(p: ^Proc) -> bool {
	return p.state.is_contained
}

// platform stream accessors. The _locked suffix means the caller holds
// p.mu — true only for close_stdin (lsproc_stop calls it between its wait
// stages). The stream I/O accessors are deliberately lock-free: each end
// has one owning thread (stdin writes go through the jsonrpc writer,
// stdout belongs to the reader thread, stderr to the pump), and a stop or
// death racing the I/O surfaces as EBADF/EPIPE or EOF at the fd level,
// never as a mutex ordering.

platform_close_stdin_locked :: proc(p: ^Proc) {
	if p.state.stdin_w >= 0 {
		_ = posix.close(p.state.stdin_w)
		p.state.stdin_w = -1
	}
}

platform_write_stdin :: proc(p: ^Proc, buf: []u8) -> int {
	if p.state.stdin_w < 0 {
		return -1
	}
	return int(posix.write(p.state.stdin_w, raw_data(buf), len(buf)))
}

// read_pipe drains one pipe end; EOF (read 0) or error closes the fd and
// reports the pipe done.
read_pipe :: proc(fd: ^posix.FD, buf: []u8) -> (int, bool) {
	if fd^ < 0 {
		return 0, true
	}
	n := posix.read(fd^, raw_data(buf), len(buf))
	if n <= 0 {
		_ = posix.close(fd^)
		fd^ = -1
		return 0, true
	}
	return int(n), false
}

platform_read_stdout :: proc(p: ^Proc, buf: []u8) -> (int, bool) {
	return read_pipe(&p.state.stdout_r, buf)
}

platform_read_stderr :: proc(p: ^Proc, buf: []u8) -> (int, bool) {
	return read_pipe(&p.state.stderr_r, buf)
}

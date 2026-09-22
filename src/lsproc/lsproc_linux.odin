#+build linux

// Linux platform seam: raw fork/exec (core:os cannot set setpgid or
// Pdeathsig, and language servers need both — setpgid so the tree is
// signalable as a group and a stray server cannot take the session's
// terminal down with it; Pdeathsig so a daemon crash never strands an
// orphaned server), cgroup v2 memory containment under a delegated
// subtree, and /proc-based tree kill.
package lsproc

import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"

import "src:platform"
import "src:util"

PR_SET_PDEATHSIG :: 1
CLD_EXITED :: 1

Platform_State :: struct {
	stdin_w:     linux.Fd, // parent's write end; -1 = closed
	stdout_r:    linux.Fd, // parent's read ends
	stderr_r:    linux.Fd,
	cgroup_dir:  string, // owned; "" = no containment
	is_contained: bool,
	allocator:   mem.Allocator,
}

platform_state_new :: proc(a: mem.Allocator) -> ^Platform_State {
	s := new(Platform_State, a)
	s^ = {
		stdin_w  = -1,
		stdout_r = -1,
		stderr_r = -1,
		allocator  = a,
	}
	return s
}

platform_state_destroy :: proc(s: ^Platform_State) {
	if s.stdin_w >= 0 {
		_ = linux.close(s.stdin_w)
	}
	if s.stdout_r >= 0 {
		_ = linux.close(s.stdout_r)
	}
	if s.stderr_r >= 0 {
		_ = linux.close(s.stderr_r)
	}
	if s.cgroup_dir != "" {
		// The watcher released containment already; a straggler here means
		// the child never exited cleanly — remove best effort anyway.
		_ = os.remove(s.cgroup_dir)
		delete(s.cgroup_dir, s.allocator)
	}
	free(s, s.allocator)
}

// resolve_executable finds command0: a path containing '/' is checked
// directly, a bare name is searched through PATH (first executable hit).
resolve_executable :: proc(command0: string, a: mem.Allocator) -> (cstring, platform.Err) {
	if strings.index_byte(command0, '/') >= 0 {
		c := to_cstr(command0, a)
		if linux.access(c, linux.X_OK) != .NONE {
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
		if linux.access(c, linux.X_OK) == .NONE {
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

	dir_flags : linux.Open_Flags : {.NONBLOCK, .DIRECTORY, .LARGEFILE, .CLOEXEC}
	dir_fd := linux.AT_FDCWD
	if l.working_dir != "" {
		fd, errno := linux.open(to_cstr(l.working_dir, a), dir_flags)
		if errno != .NONE {
			return platform.Err(.NotFound)
		}
		dir_fd = fd
	}
	defer if dir_fd != linux.AT_FDCWD {
		_ = linux.close(dir_fd)
	}

	// stdin: parent writes [1], child reads [0]; stdout/stderr mirrored.
	// Initialized to -1 (not the zero value): a zero-value entry is the
	// real fd 0, and the pipe-failure cleanup below closes every array —
	// pipes pipe2 never created must read as "no descriptor".
	stdin_fds := [2]linux.Fd{-1, -1}
	stdout_fds := [2]linux.Fd{-1, -1}
	stderr_fds := [2]linux.Fd{-1, -1}
	err_fds := [2]linux.Fd{-1, -1}
	if linux.pipe2(&stdin_fds, {.CLOEXEC}) != .NONE ||
	   linux.pipe2(&stdout_fds, {.CLOEXEC}) != .NONE ||
	   linux.pipe2(&stderr_fds, {.CLOEXEC}) != .NONE ||
	   linux.pipe2(&err_fds, {.CLOEXEC}) != .NONE {
		close_pipe_pair(&stdin_fds)
		close_pipe_pair(&stdout_fds)
		close_pipe_pair(&stderr_fds)
		close_pipe_pair(&err_fds)
		return platform.Err(.Internal)
	}
	defer close_pipe_pair(&err_fds) // the read end survives until the exec check below

	parent_pid := linux.getpid()
	pid, errno := linux.fork()
	if errno != .NONE {
		close_pipe_pair(&stdin_fds)
		close_pipe_pair(&stdout_fds)
		close_pipe_pair(&stderr_fds)
		return platform.Err(.Internal)
	}

	if pid == 0 {
		// Child: raw syscalls only — no allocation, no locks (the parent's
		// threads exist only in the parent now).
		_ = linux.setpgid(0, 0)
		// Die with the parent. The ppid check closes the race where the
		// parent died between fork and prctl (the signal would never arm).
		// Raw syscall5, not core's prctl wrapper: the wrapper indexes all
		// four variadic slots unconditionally and panics on fewer
		// arguments (still so on dev-2026-09-nightly) — and a panicking
		// child wedges the fork.
		_ = linux.syscall(
			linux.SYS_prctl,
			cast(uintptr)PR_SET_PDEATHSIG,
			cast(uintptr)linux.Signal.SIGKILL,
			0, 0, 0,
		)
		if linux.getppid() != parent_pid {
			linux.exit(126)
		}
		_, _ = linux.dup2(stdin_fds[0], 0)
		_, _ = linux.dup2(stdout_fds[1], 1)
		_, _ = linux.dup2(stderr_fds[1], 2)
		if dir_fd != linux.AT_FDCWD && linux.fchdir(dir_fd) != .NONE {
			child_report_exec_error(&err_fds, .EACCES)
		}
		linux.execveat(dir_fd, exe, &cargs[0], env)
		child_report_exec_error(&err_fds, .EACCES)
	}

	// Parent: the child owns its ends now. The exec-error pipe's parent
	// write end must close HERE — the read below only sees EOF when every
	// write end is gone, and the parent's own copy would hold it open
	// forever.
	_ = linux.close(stdin_fds[0])
	_ = linux.close(stdout_fds[1])
	_ = linux.close(stderr_fds[1])
	_ = linux.close(err_fds[1])
	err_fds[1] = -1

	// exec-failure pipe: a successful exec closes the write end (CLOEXEC)
	// and this read yields EOF; a failed exec delivers the errno byte and
	// the child has already exited(126) — reap it so nothing zombies.
	err_byte: [1]u8
	errno = .EINTR
	n := 0
	for errno == .EINTR {
		n, errno = linux.read(err_fds[0], err_byte[:])
	}
	if n == 1 {
		info: linux.Sig_Info
		_ = linux.waitid(.PID, linux.Id(pid), &info, {.WEXITED}, nil)
		_ = linux.close(stdin_fds[1])
		_ = linux.close(stdout_fds[0])
		_ = linux.close(stderr_fds[0])
		return platform.Err(.NotFound)
	}

	p.pid = cast(int)pid
	p.state.stdin_w = stdin_fds[1]
	p.state.stdout_r = stdout_fds[0]
	p.state.stderr_r = stderr_fds[0]
	return nil
}

child_report_exec_error :: proc(err_fds: ^[2]linux.Fd, errno: linux.Errno) {
	byte := [1]u8{u8(errno)}
	_, _ = linux.write(err_fds[1], byte[:])
	linux.exit(126)
}

close_pipe_pair :: proc(fds: ^[2]linux.Fd) {
	if fds[0] >= 0 {
		_ = linux.close(fds[0])
	}
	if fds[1] >= 0 {
		_ = linux.close(fds[1])
	}
}

// platform_wait_exit blocks until the child is reaped. Exit code from
// waitid's siginfo; -1 when the death was a signal. EINTR retries
// (SA_RESTART makes it unreachable today; the darwin twin carries the
// same loop so the seams cannot drift apart).
platform_wait_exit :: proc(p: ^Proc) -> int {
	info: linux.Sig_Info
	errno := linux.waitid(.PID, linux.Id(cast(linux.Pid)p.pid), &info, {.WEXITED}, nil)
	for errno == .EINTR {
		errno = linux.waitid(.PID, linux.Id(cast(linux.Pid)p.pid), &info, {.WEXITED}, nil)
	}
	if errno != .NONE {
		return -1
	}
	if info.code == CLD_EXITED {
		return int(info.status)
	}
	return -1
}

// platform_kill_tree signals the child and every descendant. Descendants
// are collected first (walking /proc/<pid>/task/*/children recursively —
// the kernel-maintained list, no racing /proc/PID/* scan), then signaled
// children-first, then the root.
platform_kill_tree :: proc(pid: int, kind: Signal_Kind) {
	sig := linux.Signal.SIGTERM
	if kind == .KILL {
		sig = .SIGKILL
	}
	children := platform.proctree_collect_child_pids(pid, context.temp_allocator)
	for c in children {
		_ = linux.kill(cast(linux.Pid)c, sig)
	}
	_ = linux.kill(cast(linux.Pid)pid, sig)
	delete(children, context.temp_allocator)
}

// platform_child_pids snapshots the descendant pids of a process through
// the kernel-maintained /proc children lists; empty once it is gone.
// The walker itself lives in platform (proctree) — the same tree walk
// its kill path runs.
platform_child_pids :: proc(pid: int, a := context.allocator) -> []int {
	return platform.proctree_collect_child_pids(pid, a)
}

// platform stream accessors (called with p.mu held by the callers).

platform_close_stdin_locked :: proc(p: ^Proc) {
	if p.state.stdin_w >= 0 {
		_ = linux.close(p.state.stdin_w)
		p.state.stdin_w = -1
	}
}

platform_write_stdin_locked :: proc(p: ^Proc, buf: []u8) -> int {
	if p.state.stdin_w < 0 {
		return -1
	}
	n, errno := linux.write(p.state.stdin_w, buf)
	if errno != .NONE {
		return -1
	}
	return n
}

// read_pipe_locked drains one pipe end; EOF (read 0) or error closes the
// fd and reports the pipe done.
read_pipe_locked :: proc(fd: ^linux.Fd, buf: []u8) -> (int, bool) {
	if fd^ < 0 {
		return 0, true
	}
	n, errno := linux.read(fd^, buf)
	if errno == .NONE {
		if n == 0 {
			_ = linux.close(fd^)
			fd^ = -1
			return 0, true
		}
		return n, false
	}
	// A failed read leaves the pipe unusable (the darwin twin closes on
	// n <= 0): close the fd here or every error leaks the descriptor
	// while reporting the stream cleanly done.
	_ = linux.close(fd^)
	fd^ = -1
	return 0, true
}

platform_read_stdout_locked :: proc(p: ^Proc, buf: []u8) -> (int, bool) {
	return read_pipe_locked(&p.state.stdout_r, buf)
}

// --- cgroup v2 memory containment ------------------------------------------

// platform_containment_setup moves the fresh child into a dedicated cgroup
// v2 directory with memory.max = limit, memory.swap.max = 0 (no swap-out
// of the ceiling), and memory.oom.group = 1 (an OOMing member kills the
// whole group — a wedged server must not linger half-alive). Enforcement
// is synchronous in the kernel's charging path, which is the property a
// userspace watchdog cannot offer. Best effort: without a delegated
// subtree the server simply runs uncontained.
platform_containment_setup :: proc(p: ^Proc, limit_mb: int, language: string) -> bool {
	base, ok := delegated_cgroup_base()
	if !ok {
		return false
	}
	dir := strings.concatenate(
		{base, "/", containment_dir_name(language, p.pid)},
		context.temp_allocator,
	)
	if os.make_directory(dir) != nil {
		return false
	}
	limit_bytes := strings.concatenate(
		{util.int_to_dec(limit_mb * 1 << 20, context.temp_allocator), "\n"},
		context.temp_allocator,
	)
	// memory.swap.max = 0 and memory.oom.group = 1 land before the limit:
	// a partial setup never holds a swap-enabled ceiling.
	if !write_control_file(dir, "memory.swap.max", "0\n") ||
	   !write_control_file(dir, "memory.oom.group", "1\n") ||
	   !write_control_file(dir, "memory.max", limit_bytes) {
		_ = os.remove(dir)
		return false
	}
	procs := strings.concatenate(
		{util.int_to_dec(p.pid, context.temp_allocator), "\n"},
		context.temp_allocator,
	)
	if !write_control_file(dir, "cgroup.procs", procs) {
		_ = os.remove(dir)
		return false
	}
	p.state.cgroup_dir = strings.clone(dir, p.state.allocator)
	p.state.is_contained = true
	return true
}

// platform_containment_release removes the cgroup directory once the child
// is gone (rmdir fails while members live — by now they have exited).
platform_containment_release :: proc(p: ^Proc) {
	if p.state.cgroup_dir != "" {
		_ = os.remove(p.state.cgroup_dir)
		delete(p.state.cgroup_dir, p.state.allocator)
		p.state.cgroup_dir = ""
	}
	p.state.is_contained = false
}

platform_contained :: proc(p: ^Proc) -> bool {
	return p.state.is_contained
}

write_control_file :: proc(dir: string, name: string, value: string) -> bool {
	path := strings.concatenate({dir, "/", name}, context.temp_allocator)
	return os.write_entire_file_from_bytes(path, transmute([]u8)value) == nil
}

// containment_dir_name sanitizes the language id into the directory name:
// lowercase ASCII alphanumerics plus -_. survive, every other rune
// collapses to a single '-', so a configured language id cannot escape
// the delegated subtree.
containment_dir_name :: proc(language: string, pid: int) -> string {
	buf := make([dynamic]u8, 0, 32, context.temp_allocator)
	append(&buf, "aubade-ls-")
	for r in language {
		c := 'A'
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' ||
		   r == '-' || r == '_' || r == '.' {
			c = r
		} else if r >= 'A' && r <= 'Z' {
			c = r + ('a' - 'A')
		} else {
			append(&buf, '-')
			continue
		}
		append(&buf, u8(c))
	}
	append(&buf, '-')
	pid_text := util.int_to_dec(pid, context.temp_allocator)
	append(&buf, pid_text)
	out := strings.clone(string(buf[:]), context.temp_allocator)
	delete(buf)
	return out
}

// delegated_cgroup_base returns a writable cgroup v2 subtree: our own
// cgroup first (systemd user delegation), then the unified root (manual
// delegation). Probing writes a scratch memory.max because on
// un-delegated scopes mkdir alone succeeds while control writes deny.
delegated_cgroup_base :: proc() -> (string, bool) {
	candidates := make([dynamic]string, 0, 2, context.temp_allocator)
	defer delete(candidates)
	if own, ok := own_cgroup_path(); ok && own != "" {
		append(
			&candidates,
			strings.concatenate({"/sys/fs/cgroup/", own}, context.temp_allocator),
		)
	}
	append(&candidates, "/sys/fs/cgroup")
	for base in candidates {
		probe := strings.concatenate(
			{base, "/.aubade-probe-", util.int_to_dec(os.get_pid(), context.temp_allocator)},
			context.temp_allocator,
		)
		if os.make_directory(probe) == nil {
			writable := write_control_file(probe, "memory.max", "max\n")
			_ = os.remove(probe)
			if writable {
				return base, true
			}
		}
	}
	return "", false
}

// own_cgroup_path reads this process's cgroup v2 path from
// /proc/self/cgroup (the "0::<path>" line), trimmed of the leading slash.
own_cgroup_path :: proc() -> (string, bool) {
	data, err := os.read_entire_file_from_path("/proc/self/cgroup", context.temp_allocator)
	if err != nil {
		return "", false
	}
	lines, _ := strings.split(string(data), "\n", context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "0::") {
			continue
		}
		path := trimmed[3:]
		if path == "" {
			return "", false
		}
		return strings.trim_prefix(path, "/"), true
	}
	return "", false
}

platform_read_stderr_locked :: proc(p: ^Proc, buf: []u8) -> (int, bool) {
	return read_pipe_locked(&p.state.stderr_r, buf)
}

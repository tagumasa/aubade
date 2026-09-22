#+build linux

// proctree: the process-tree discipline for spawned children (Linux).
// A child spawned through this seam runs in its own process group and
// dies with its group: setpgid at the fork child, group kill at stop,
// Pdeathsig so a crashed parent never strands orphans. core:os can set
// neither flag — this is a raw fork/exec over core:sys/linux (the same
// discipline lsproc carries for language servers; procrun's
// process_group option is the tool-side consumer). The /proc
// children-list tree kill reaches descendants that changed group
// themselves.
//
// The fork child runs raw syscalls only — no allocation, no locks (the
// parent's threads exist only in the parent now).
package platform

import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

PR_SET_PDEATHSIG :: 1
CLD_EXITED :: 1

proctree_signal :: proc(kind: Proctree_Signal) -> linux.Signal {
	sig := linux.Signal.SIGTERM
	if kind == .KILL {
		sig = .SIGKILL
	}
	return sig
}

// proctree_resolve_executable finds command0: a path containing '/' is
// checked directly, a bare name is searched through PATH (first
// executable hit).
proctree_resolve_executable :: proc(command0: string, a: mem.Allocator) -> (cstring, Err) {
	if strings.index_byte(command0, '/') >= 0 {
		c := proctree_to_cstr(command0, a)
		if linux.access(c, linux.X_OK) != .NONE {
			return nil, Err(.NotFound)
		}
		return c, nil
	}
	path_env := os.get_env("PATH", a)
	if path_env == "" {
		return nil, Err(.NotFound)
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
		c := proctree_to_cstr(candidate, a)
		if linux.access(c, linux.X_OK) == .NONE {
			return c, nil
		}
	}
	return nil, Err(.NotFound)
}

// proctree_spawn forks and execs the command in its own process group.
// On success the caller owns pid (== the process group id) and must
// close its sides of the pipes; the child's death is observed through
// proctree_try_wait / proctree_wait_exit.
proctree_spawn :: proc(desc: Proctree_Desc) -> (pid: int, err: Err) {
	a := context.temp_allocator

	exe, rerr := proctree_resolve_executable(desc.command[0], a)
	if rerr != nil {
		return 0, rerr
	}
	cargs := make([]cstring, len(desc.command) + 1, a)
	for arg, i in desc.command {
		cargs[i] = proctree_to_cstr(arg, a)
	}

	env, eerr := proctree_env_cstrings(desc.env, a)
	if eerr != nil {
		return 0, eerr
	}

	dir_flags: linux.Open_Flags: {.NONBLOCK, .DIRECTORY, .LARGEFILE, .CLOEXEC}
	dir_fd := linux.AT_FDCWD
	if desc.working_dir != "" {
		fd, errno := linux.open(proctree_to_cstr(desc.working_dir, a), dir_flags)
		if errno != .NONE {
			return 0, Err(.NotFound)
		}
		dir_fd = fd
	}
	defer if dir_fd != linux.AT_FDCWD {
		_ = linux.close(dir_fd)
	}

	// stderr: the caller's write end when captured, the null device when
	// not — a child whose stderr nobody reads must not fill a pipe and
	// block on write. (stdin is the null device by design: a tool-side
	// command must hit EOF, never steal its parent's descriptor zero.)
	stderr_fd := linux.Fd(-1)
	null_fd := linux.Fd(-1)
	if desc.stderr_w != nil {
		stderr_fd = cast(linux.Fd)os.fd(desc.stderr_w)
	} else {
		// The flag set carries CLOEXEC: the original dies at the exec (the
		// dup2'd destination survives — dup2 clears the flag), so the
		// spawned command carries no stray null-device descriptors.
		fd, errno := linux.open("/dev/null", {.WRONLY, .CLOEXEC})
		if errno != .NONE {
			return 0, Err(.Internal)
		}
		null_fd = fd
		stderr_fd = fd
	}
	defer if null_fd >= 0 {
		_ = linux.close(null_fd)
	}

	// stdin: the null device — a tool-side command must hit EOF, never
	// steal its parent's descriptor zero (the MCP stdio).
	null_r_fd := linux.Fd(-1)
	// CLOEXEC from the start: same rule as the null write end above — the
	// original dies at the exec, the dup2'd destination survives.
	rfd, rerrno := linux.open("/dev/null", {.CLOEXEC})
	if rerrno != .NONE {
		return 0, Err(.Internal)
	}
	null_fd = rfd
	stdin_fd := null_fd
	defer if null_r_fd >= 0 {
		_ = linux.close(null_r_fd)
	}

	// The exec-error pipe: a failed exec delivers an errno byte, a
	// successful one closes the CLOEXEC write end and the parent reads
	// EOF. Initialized to -1 (not the zero value): a zero-value entry is
	// the real fd 0, and the pipe-failure cleanup closes every array —
	// pipes pipe2 never created must read as "no descriptor".
	stdout_fd := cast(linux.Fd)os.fd(desc.stdout_w)
	err_fds := [2]linux.Fd{-1, -1}
	if linux.pipe2(&err_fds, {.CLOEXEC}) != .NONE {
		return 0, Err(.Internal)
	}
	defer close_pipe_pair(&err_fds) // the read end survives until the exec check below

	parent_pid := linux.getpid()
	pid_raw, errno := linux.fork()
	if errno != .NONE {
		return 0, Err(.Internal)
	}

	if pid_raw == 0 {
		// Child: own process group first, then die-with-parent armed when
		// the caller asked for it. The ppid check closes the race where
		// the parent died between fork and prctl (the signal would never
		// arm). Raw syscall5, not core's prctl wrapper: the wrapper
		// indexes all four variadic slots unconditionally and panics on
		// fewer arguments — and a panicking child wedges the fork.
		_ = linux.setpgid(0, 0)
		if desc.pdeathsig {
			_ = linux.syscall(
				linux.SYS_prctl,
				cast(uintptr)PR_SET_PDEATHSIG,
				cast(uintptr)linux.Signal.SIGKILL,
				0, 0, 0,
			)
			if linux.getppid() != parent_pid {
				linux.exit(126)
			}
		}
		_, _ = linux.dup2(stdin_fd, 0)
		_, _ = linux.dup2(stdout_fd, 1)
		_, _ = linux.dup2(stderr_fd, 2)
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
	_ = linux.close(err_fds[1])
	err_fds[1] = -1

	// A successful exec closes the write end (CLOEXEC) and this read
	// yields EOF; a failed exec delivers the errno byte and the child has
	// already exited(126) — reap it so nothing zombies.
	err_byte: [1]u8
	errno = .EINTR
	n := 0
	for errno == .EINTR {
		n, errno = linux.read(err_fds[0], err_byte[:])
	}
	if n == 1 {
		info: linux.Sig_Info
		_ = linux.waitid(.PID, linux.Id(pid_raw), &info, {.WEXITED}, nil)
		return 0, Err(.NotFound)
	}

	return int(pid_raw), nil
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

// proctree_try_wait probes the child without blocking: WNOHANG waitid,
// so a poll loop keeps its drain cadence while waiting. exit_code is -1
// when the death was a signal.
proctree_try_wait :: proc(pid: int) -> (exited: bool, exit_code: int) {
	info: linux.Sig_Info
	errno := linux.waitid(
		.PID,
		linux.Id(pid),
		&info,
		{.WEXITED, .WNOHANG},
		nil,
	)
	if errno == .EINTR {
		return false, -1
	}
	if errno != .NONE {
		// An errno other than EINTR means the pid is not a live child of
		// this process (already reaped elsewhere, or gone).
		return false, -1
	}
	if info._sigchld._pid1 == 0 {
		return false, -1 // WNOHANG: the child is still running
	}
	if info.code == CLD_EXITED {
		return true, int(info._sigchld.status)
	}
	return true, -1
}

// proctree_wait_exit blocks until the child is reaped; -1 when the death
// was a signal. EINTR retries (SA_RESTART makes it unreachable today; the
// darwin twin carries the same loop so the seams cannot drift apart).
proctree_wait_exit :: proc(pid: int) -> int {
	info: linux.Sig_Info
	errno := linux.waitid(.PID, linux.Id(pid), &info, {.WEXITED}, nil)
	for errno == .EINTR {
		errno = linux.waitid(.PID, linux.Id(pid), &info, {.WEXITED}, nil)
	}
	if errno != .NONE {
		return -1
	}
	if info.code == CLD_EXITED {
		return int(info._sigchld.status)
	}
	return -1
}

// proctree_kill_group kills the process group (the child leads it, so
// the group id is the child's pid) and then walks the /proc children
// lists for descendants that changed group themselves.
proctree_kill_group :: proc(pid: int, kind: Proctree_Signal) -> bool {
	sig := proctree_signal(kind)
	_ = linux.kill(cast(linux.Pid)-pid, sig)
	proctree_kill_tree_sig(pid, sig)
	return true
}

// proctree_kill_tree signals the child and every descendant. Descendants
// are collected first (walking /proc/<pid>/task/*/children recursively —
// the kernel-maintained list, no racing /proc/PID/* scan), then signaled
// children-first, then the root.
proctree_kill_tree :: proc(pid: int, kind: Proctree_Signal) {
	proctree_kill_tree_sig(pid, proctree_signal(kind))
}

proctree_kill_tree_sig :: proc(pid: int, sig: linux.Signal) {
	children := proctree_collect_child_pids(pid, context.temp_allocator)
	for c in children {
		_ = linux.kill(cast(linux.Pid)c, sig)
	}
	_ = linux.kill(cast(linux.Pid)pid, sig)
	delete(children, context.temp_allocator)
}

// proctree_int_to_dec renders one decimal integer (the /proc walk's pid
// paths). platform sits below util, so this is a local copy of the small
// helper, not an import.
proctree_int_to_dec :: proc(v: int, a := context.allocator) -> string {
	buf: [24]u8
	if v == 0 {
		return "0"
	}
	neg := v < 0
	u := uint(v)
	if neg {
		u = uint(-v)
	}
	i := len(buf)
	for u > 0 {
		if i == 0 {
			return ""
		}
		i -= 1
		buf[i] = u8('0' + u % 10)
		u /= 10
	}
	if neg {
		if i == 0 {
			return ""
		}
		i -= 1
		buf[i] = '-'
	}
	// The digits live on this frame — clone them out or the string dangles.
	return strings.clone(string(buf[i:]), a)
}

proctree_collect_child_pids :: proc(pid: int, a: mem.Allocator) -> []int {
	out := make([dynamic]int, 0, 4, a)
	seen := make(map[int]bool, 8, a)
	proctree_collect_children_into(pid, &seen, &out, a)
	delete(seen)
	result := make([]int, len(out), a)
	for v, i in out {
		result[i] = v
	}
	delete(out)
	return result
}

proctree_collect_children_into :: proc(pid: int, seen: ^map[int]bool, out: ^[dynamic]int, a: mem.Allocator) {
	if pid in seen^ {
		return
	}
	seen^[pid] = true

	pid_str := proctree_int_to_dec(pid, a)
	task_dir := strings.concatenate({"/proc/", pid_str, "/task"}, a)
	delete(pid_str, a) // concatenate copied the digits; the clone dies here
	entries, derr := os.read_all_directory_by_path(task_dir, a)
	if derr != nil {
		delete(task_dir, a)
		return
	}
	defer {
		for fi in entries {
			os.file_info_delete(fi, a)
		}
		delete(entries, a)
		delete(task_dir, a)
	}

	for fi in entries {
		children_path := strings.concatenate(
			{task_dir, "/", fi.name, "/children"},
			a,
		)
		data, ferr := os.read_entire_file_from_path(children_path, a)
		if ferr != nil {
			delete(children_path, a)
			continue
		}
		fields, _ := strings.fields(string(data), a)
		for field in fields {
			child, ok := strconv.parse_int(field, 10)
			if !ok || int(child) in seen^ {
				continue
			}
			seen^[int(child)] = true
			append(out, int(child))
			proctree_collect_children_into(int(child), seen, out, a)
		}
		delete(fields, a)
		delete(data, a)
		delete(children_path, a)
	}
}

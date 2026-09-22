#+build darwin

// proctree: the process-tree discipline for spawned children (darwin) —
// the twin of proctree_linux.odin over core:sys/posix. The child runs in
// its own process group (setpgid at the fork child) and dies with its
// group (kill(-pgid) at stop), so a backgrounded tree cannot outlive the
// call that spawned it; core:os sets neither property, so this is a raw
// fork/exec. The fork child runs raw libc calls only — no allocation, no
// locks (the parent's threads exist only in the parent now).
//
// Darwin has no /proc, so descendants that changed group themselves
// (setsid) sit beyond the group kill — the same boundary the lsproc
// death-sitter design records for processes that escape their group.
// Orphan containment is not this seam's business on darwin: lsproc arms
// its death sitter for language servers, and procrun's tool commands
// stop with their call.
package platform

import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"

proctree_signal :: proc(kind: Proctree_Signal) -> posix.Signal {
	sig := posix.Signal.SIGTERM
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
		if posix.access(c, {.X_OK}) != .OK {
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
		if posix.access(c, {.X_OK}) == .OK {
			return c, nil
		}
	}
	return nil, Err(.NotFound)
}

// proctree_spawn forks and execs the command in its own process group.
// On success the caller owns pid (== the process group id) and must
// close its sides of the pipes; the child's death is observed through
// proctree_try_wait.
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

	cwd := "."
	if desc.working_dir != "" {
		cwd = desc.working_dir
	}
	cwd_c := proctree_to_cstr(cwd, a)

	// stdin: the null device — a tool-side command must hit EOF, never
	// steal its parent's descriptor zero (the MCP stdio). The wrappers
	// die at procedure exit on the parent side; the child keeps only the
	// raw descriptors it dup2'd.
	stdin_file, nerr := os.open("/dev/null", {.Read})
	if nerr != nil {
		return 0, Err(.Internal)
	}
	defer os.close(stdin_file)

	// stderr: the caller's write end when captured, the null device when
	// not — a child whose stderr nobody reads must not fill a pipe and
	// block on write.
	stderr_file: ^os.File = nil
	if desc.stderr_w == nil {
		f, oerr := os.open("/dev/null", {.Write})
		if oerr != nil {
			return 0, Err(.Internal)
		}
		stderr_file = f
	}
	defer if stderr_file != nil {
		os.close(stderr_file)
	}

	stdin_fd := cast(posix.FD)os.fd(stdin_file)
	stdout_fd := cast(posix.FD)os.fd(desc.stdout_w)
	stderr_fd := cast(posix.FD)os.fd(desc.stderr_w)
	if stderr_file != nil {
		stderr_fd = cast(posix.FD)os.fd(stderr_file)
	}

	// The exec-error pipe: a failed exec delivers an errno byte, a
	// successful one closes the CLOEXEC write end and the parent reads
	// EOF. Initialized to -1 (not the zero value): a zero-value entry is
	// the real fd 0, and the pipe-failure cleanup closes every array —
	// pipes pipe() never created must read as "no descriptor".
	err_fds := [2]posix.FD{-1, -1}
	if posix.pipe(&err_fds) != .OK {
		return 0, Err(.Internal)
	}
	defer proctree_close_fds(&err_fds)

	// Belt-and-braces CLOEXEC marking: core already ships os.pipe and
	// os.open descriptors close-on-exec on POSIX, but this seam's EOF
	// contract must not hang on core's private flag choices — a stray
	// write end kept open past the exec would hold the parent's read end
	// off EOF for as long as the exec'd program lives. Mark every
	// descriptor the child dup2's before the fork: a successful exec drops
	// the originals while the destinations survive (dup2 clears the flag).
	// The read ends stay in procrun's frame and are not this seam's to
	// mark; only write ends gate EOF. The raw err-pipe below is the one
	// set core never marks.
	marked := [3]posix.FD{stdin_fd, stdout_fd, stderr_fd}
	for fd in marked {
		_ = posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	for fd in err_fds {
		_ = posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}

	switch pid := posix.fork(); pid {
	case -1:
		return 0, Err(.Internal)

	case 0:
		// Child: own process group first. Raw libc only from here.
		_ = posix.setpgid(0, 0)
		_ = posix.dup2(stdin_fd, posix.STDIN_FILENO)
		_ = posix.dup2(stdout_fd, posix.STDOUT_FILENO)
		_ = posix.dup2(stderr_fd, posix.STDERR_FILENO)
		if posix.chdir(cwd_c) != .OK {
			proctree_child_abort(&err_fds)
		}
		if posix.execve(exe, &cargs[0], env) == -1 {
			proctree_child_abort(&err_fds)
		}

	case:
		// Parent: the child owns its ends now. The exec-error pipe's
		// parent write end must close HERE — the read below only sees
		// EOF when every write end is gone, and the parent's own copy
		// would hold it open forever.
		_ = posix.close(err_fds[1])
		err_fds[1] = -1

		// A successful exec closes the write end (CLOEXEC) and this read
		// yields EOF; a failed exec delivers the errno byte and the child
		// has already exited(126) — reap it so nothing zombies (the pid
		// is registered with nobody else). EINTR retries, like the Linux
		// twin: an interrupted read must not read as a clean exec.
		err_byte := [1]u8{0}
		n := posix.read(err_fds[0], &err_byte[0], 1)
		for n == -1 && posix.errno() == .EINTR {
			n = posix.read(err_fds[0], &err_byte[0], 1)
		}
		if n == 1 {
			info: posix.siginfo_t
			_ = posix.waitid(.P_PID, cast(posix.id_t)pid, &info, {.EXITED})
			return 0, Err(.NotFound)
		}
		return int(pid), nil
	}
	return 0, Err(.Internal)
}

proctree_child_abort :: proc(err_fds: ^[2]posix.FD) {
	errno := u8(posix.errno())
	_ = posix.write(err_fds[1], &errno, 1)
	posix.exit(126)
}

proctree_close_fds :: proc(fds: ^[2]posix.FD) {
	if fds[0] >= 0 {
		_ = posix.close(fds[0])
	}
	if fds[1] >= 0 {
		_ = posix.close(fds[1])
	}
}

// proctree_try_wait probes the child without blocking (a WNOHANG
// waitpid), so a poll loop keeps its drain cadence while waiting.
// exit_code is -1 when the death was a signal.
proctree_try_wait :: proc(pid: int) -> (exited: bool, exit_code: int) {
	status: i32
	w := posix.waitpid(cast(posix.pid_t)pid, &status, {.NOHANG})
	if w == 0 {
		return false, -1 // NOHANG: the child is still running
	}
	if w == -1 {
		// EINTR reads as still-running (the poll loop re-probes); any
		// other errno means the pid is not a live child of this process
		// (already reaped elsewhere, or gone).
		return false, -1
	}
	if posix.WIFEXITED(status) {
		return true, int(posix.WEXITSTATUS(status))
	}
	return true, -1
}

// proctree_kill_group kills the process group (the child leads it, so
// the group id is the child's pid). Descendants that changed group
// themselves are beyond darwin's raw-syscall reach — the header records
// the boundary.
proctree_kill_group :: proc(pid: int, kind: Proctree_Signal) -> bool {
	_ = posix.kill(cast(posix.pid_t)(-pid), proctree_signal(kind))
	return true
}

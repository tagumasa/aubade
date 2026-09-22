// lsproc: language-server process management. The platform seam is a set
// of small procs (spawn, blocking exit wait, tree kill, containment, stdin
// close) implemented per OS in lsproc_<os>.odin — never a fat interface on
// the provider side. This file owns the neutral parts: the launch
// description, the process record with its exit watcher, and the staged
// stop (stdin EOF nudge -> SIGTERM tree -> SIGKILL tree, monotonic
// deadlines through the injected clock, cancel-token checkpoints at every
// stage boundary and wait slice).
//
// The LSP protocol shutdown (shutdown request + exit notification) is
// spoken by the lsp client BEFORE lsproc_stop: lsproc is the enforcement
// layer that guarantees the child dies even when the server ignores the
// protocol.
package lsproc

import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"

import "src:platform"
import "src:util"

// Launch describes one language-server child.
Launch :: struct {
	command:         []string, // argv; command[0] is resolved through PATH when no '/'
	working_dir:     string, // "" = inherit the caller's
	env:             []string, // KEY=VALUE entries; nil = inherit
	language_id:     string, // containment labeling and logs
	memory_limit_mb: int, // OS-level containment; <= 0 disables
}

// Bound for the platform helpers' own subprocesses (ps, pgrep, kill,
// taskkill): they normally finish in well under a second, and a wedged
// one must cost one timeout, never a stuck stop stage or a jammed
// watchdog thread.
HELPER_RUN_TIMEOUT_MS :: 5_000

// to_cstr clones a string into a NUL-terminated cstring (spawn runs on
// the temp allocator; nothing crosses the fork).
to_cstr :: proc(s: string, a: mem.Allocator) -> cstring {
	buf := make([dynamic]u8, 0, len(s) + 1, a)
	append(&buf, ..transmute([]u8)s)
	append(&buf, 0)
	return cstring(&buf[0])
}

// spawn_env_cstrings materializes the child's environment as a
// NUL-terminated cstring array: the caller's environment when the launch
// spec carries no override, else the override verbatim. The array shape
// (make-with-length, trailing nil terminator) is owned by the platform
// seam both proctree twins share — one declaration for the execve idiom.
// Spawn runs on the temp allocator; nothing crosses the fork.
spawn_env_cstrings :: proc(l: ^Launch, a: mem.Allocator) -> (env: [^]cstring, err: platform.Err) {
	return platform.proctree_env_cstrings(l.env, a)
}

// Signal_Kind selects the tree-kill signal for the platform seam.
Signal_Kind :: enum {
	TERM,
	KILL,
}

// Stop_Stage reports how a staged stop ended (an outcome carrier, not an
// error: Alive_After_Kill is rare and logged by the caller).
Stop_Stage :: enum {
	Exited_Before_Signal, // already gone when stop began, or exited on the stdin EOF nudge
	Exited_After_Term, // the SIGTERM tree worked
	Exited_After_Kill, // the SIGKILL tree worked
	Alive_After_Kill, // gave up (unkillable, e.g. D-state)
	Cancelled, // the caller's token fired
}

// Wait-slice cadence: the exit cond is re-checked against the clock
// deadline and the cancel token at this period (mirrors jsonrpc
// slot_wait's checkpoint idiom).
STOP_SLICE_MS :: i64(25)

// Proc is one owned language-server child: the exit watcher thread, the
// exit broadcast every waiter sees, and the opaque platform state (stream
// handles + containment). All stream access goes through the lsproc_* /
// platform-seam procs — the handle representation is platform-private.
Proc :: struct {
	pid:       int, // 0 until spawn succeeds

	state:     ^Platform_State,

	mu:        sync.Mutex,
	cond:      sync.Cond, // broadcast when the watcher records the exit
	is_exited: bool,
	exit_code: int, // valid when is_exited; -1 = killed by a signal

	watcher:   ^thread.Thread,
	allocator: mem.Allocator,
	clock:     ^platform.Clock,
}

// lsproc_spawn starts the child and its exit watcher. On success the
// caller owns the Proc and must eventually pass it through lsproc_stop
// (or observe its exit) and lsproc_destroy. Containment failures never
// block the start — they are best effort by design.
lsproc_spawn :: proc(l: Launch, clock: ^platform.Clock, a := context.allocator) -> (p: ^Proc, err: platform.Err) {
	// The stdin pipe stays writable right up to the moment a crashed
	// server's end collapses; that write must fail with an errno, not
	// SIGPIPE the whole process. Idempotent and inherited across exec.
	platform.ignore_sigpipe()

	p = new(Proc, a)
	p^ = {
		allocator = a,
		clock = clock,
	}
	p.state = platform_state_new(a)
	launch := l // procedure parameters are immutable; the seam takes a pointer
	err = platform_spawn(&launch, p)
	if err != nil {
		platform_state_destroy(p.state)
		free(p, a)
		return nil, err
	}

	if l.memory_limit_mb > 0 {
		// Best effort: without delegation the server still runs, just
		// without a hard ceiling. The engaged state is observable via
		// lsproc_contained for diagnostics.
		_ = platform_containment_setup(p, l.memory_limit_mb, l.language_id)
	}

	p.watcher = thread.create_and_start_with_data(
		p, watch_entry, self_cleanup = false, name = "lsproc-watch",
	)
	if p.watcher == nil {
		// No watcher means nobody reaps the child — tear it down now.
		platform_kill_tree(p.pid, .KILL)
		_ = platform_wait_exit(p)
		platform_containment_release(p)
		platform_state_destroy(p.state)
		free(p, a)
		return nil, platform.Err(.Internal)
	}
	return p, nil
}

// watch_entry owns the blocking exit wait and the reap. It runs on the
// watcher thread from spawn until the child is gone; containment is
// released here because the cgroup directory becomes removable exactly
// when the last process of the group exits. The release runs BEFORE the
// exit broadcast: lsproc_wait_exit returns on that broadcast, and its
// callers read containment state — they must never observe exited with
// containment still engaged (the release touches only platform state,
// so it needs no p.mu ordering).
watch_entry :: proc(data: rawptr) {
	p := cast(^Proc)data
	code := platform_wait_exit(p)
	platform_containment_release(p)
	sync.mutex_lock(&p.mu)
	p.is_exited = true
	p.exit_code = code
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
}

// lsproc_wait_exit waits for the exit broadcast under a monotonic
// deadline from the injected clock. timeout_ms == 0 polls once;
// timeout_ms < 0 blocks indefinitely (no deadline then — every stop
// caller passes a real grace).
lsproc_wait_exit :: proc(p: ^Proc, timeout_ms: i64, token: ^platform.Cancel_Token = nil) -> (exited: bool, cancelled: bool) {
	deadline := i64(0)
	if timeout_ms > 0 {
		deadline = platform.clock_now(p.clock) + timeout_ms
	}
	sync.mutex_lock(&p.mu)
	for !p.is_exited {
		if token != nil {
			if _, fired := platform.token_check(token); fired {
				sync.mutex_unlock(&p.mu)
				return false, true
			}
		}
		if timeout_ms == 0 {
			break
		}
		if timeout_ms > 0 {
			if platform.clock_now(p.clock) >= deadline {
				break
			}
			// Real-time cond slice by design: the
			// deadline math above reads the injected clock, but the park
			// itself is wall time — only its length bounds wake latency.
			sync.cond_wait_with_timeout(
				&p.cond, &p.mu, time.Duration(STOP_SLICE_MS * 1_000_000),
			)
		} else {
			sync.cond_wait(&p.cond, &p.mu)
		}
	}
	out := p.is_exited
	sync.mutex_unlock(&p.mu)
	return out, false
}

// lsproc_exited snapshots the exit state ((false, 0) while running).
lsproc_exited :: proc(p: ^Proc) -> (exited: bool, exit_code: int) {
	sync.mutex_lock(&p.mu)
	code := p.exit_code
	gone := p.is_exited
	sync.mutex_unlock(&p.mu)
	return gone, code
}

// lsproc_stop enforces the child's death in stages, each bounded by
// grace_ms on the injected clock: the stdin EOF nudge (most servers exit
// when the client side of stdin closes), then a SIGTERM to the whole
// tree, then a SIGKILL to the whole tree. The protocol-side shutdown was
// already attempted by the caller; this never speaks LSP.
lsproc_stop :: proc(p: ^Proc, grace_ms: i64, token: ^platform.Cancel_Token = nil) -> Stop_Stage {
	exited, _ := lsproc_wait_exit(p, 0)
	if exited {
		return .Exited_Before_Signal
	}

	lsproc_close_stdin(p)
	gone, cancelled := lsproc_wait_exit(p, grace_ms, token)
	if cancelled {
		return .Cancelled
	}
	if gone {
		return .Exited_Before_Signal
	}

	platform_kill_tree(p.pid, .TERM)
	gone, cancelled = lsproc_wait_exit(p, grace_ms, token)
	if cancelled {
		return .Cancelled
	}
	if gone {
		return .Exited_After_Term
	}

	platform_kill_tree(p.pid, .KILL)
	gone, cancelled = lsproc_wait_exit(p, grace_ms, token)
	if cancelled {
		return .Cancelled
	}
	if gone {
		return .Exited_After_Kill
	}
	return .Alive_After_Kill
}

// lsproc_destroy tears a STOPPED Proc down: it joins the watcher (the
// watcher's containment release still reads the platform state, so the
// join must come first) and then frees the state — which closes any
// parent-side stream handles still open. Defensive against a live child
// (the caller skipped lsproc_stop): force-kill and a bounded wait first,
// so the join cannot hang on a normal path. complete=false means the
// child refused to die even then: joining the watcher would hang teardown
// forever, so the watcher thread and the Proc are deliberately abandoned
// to process exit — callers holding dependent threads (the langserver
// reader) must abandon those too.
lsproc_destroy :: proc(p: ^Proc) -> (complete: bool) {
	exited, _ := lsproc_exited(p)
	if !exited {
		platform_kill_tree(p.pid, .KILL)
		_, _ = lsproc_wait_exit(p, 2000)
		exited, _ = lsproc_exited(p)
	}
	if !exited {
		util.log_warning("lsproc: child refused to die; abandoning watcher and proc to process exit")
		return false
	}
	if p.watcher != nil {
		thread.join(p.watcher)
		free(p.watcher, p.allocator)
	}
	platform_state_destroy(p.state)
	free(p, p.allocator)
	return true
}

// lsproc_close_stdin drops the parent's write end (the child reads EOF).
// Idempotent; also called by lsproc_stop. Serialized against the exit
// state mutex because stop calls it between wait stages.
lsproc_close_stdin :: proc(p: ^Proc) {
	sync.mutex_lock(&p.mu)
	platform_close_stdin_locked(p)
	sync.mutex_unlock(&p.mu)
}

// lsproc_write_stdin writes request bytes (returns -1 on failure). No
// mutex: a blocking write must not hold off lsproc_stop — the wiring
// serializes stdin writes through the jsonrpc writer, and a write racing
// the stop's close sees EBADF and reports -1.
lsproc_write_stdin :: proc(p: ^Proc, buf: []u8) -> int {
	return platform_write_stdin_locked(p, buf)
}

// lsproc_read_stdout reads reply bytes (blocking; n == 0 reports EOF).
// No mutex, for the same reason as lsproc_write_stdin: the wiring's
// reader thread owns this end until teardown, and the stdout fd is only
// closed by lsproc_destroy after that reader is gone.
lsproc_read_stdout :: proc(p: ^Proc, buf: []u8) -> (n: int, eof: bool) {
	return platform_read_stdout_locked(p, buf)
}

// lsproc_read_stderr drains diagnostic bytes (blocking; n == 0 reports
// EOF). No mutex, for the same reason as the stdout reader: the wiring's
// stderr pump thread owns this end until teardown.
lsproc_read_stderr :: proc(p: ^Proc, buf: []u8) -> (n: int, eof: bool) {
	return platform_read_stderr_locked(p, buf)
}

// lsproc_child_pids snapshots the descendant pids of a process
// (diagnostics and tests). Empty where the platform has no cheap
// enumeration (Windows: taskkill /T walks the tree natively).
lsproc_child_pids :: proc(pid: int, a := context.allocator) -> []int {
	return platform_child_pids(pid, a)
}

// lsproc_contained reports whether OS-level memory containment is engaged
// for this child (diagnostics; false where unavailable by design).
lsproc_contained :: proc(p: ^Proc) -> bool {
	return platform_contained(p)
}

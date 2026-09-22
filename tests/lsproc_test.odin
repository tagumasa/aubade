// lsproc tests against real child processes (cat, sh) — the process
// layer, no LSP. The staged stop covers: EOF-driven graceful exit, a
// TERM-trapping parent whose tree must be SIGKILLed, exit-code reporting,
// spawn failure on an unresolvable binary, and containment as a
// best-effort property (engaged only where the OS delegates it).
package tests

import "core:testing"

import "src:lsproc"
import "src:platform"

lsproc_test_clock :: proc(t: ^testing.T) -> ^platform.Clock {
	clock := new(platform.Clock, context.allocator)
	if clock == nil {
		testing.expectf(t, false, "clock alloc failed")
		return nil
	}
	platform.clock_init(clock, false, context.allocator)
	return clock
}

lsproc_test_clock_free :: proc(clock: ^platform.Clock) {
	platform.clock_destroy(clock)
	free(clock, context.allocator)
}

// read_line reads stdout until a newline arrives (cat writes per line).
lsproc_read_line :: proc(p: ^lsproc.Proc, buf: []u8) -> (line: string, ok: bool) {
	total := 0
	for total < len(buf) {
		n, _ := lsproc.lsproc_read_stdout(p, buf[total:])
		if n <= 0 {
			return string(buf[:total]), false
		}
		total += n
		if buf[total - 1] == '\n' {
			return string(buf[:total]), true
		}
	}
	return string(buf[:total]), true
}

when ODIN_OS == .Linux || ODIN_OS == .Darwin {

	// The full roundtrip: spawn cat by PATH lookup, echo a line through
	// stdin/stdout, then the graceful stop stage — cat exits on the stdin
	// EOF nudge alone, no signal ever sent.
	@(test)
	lsproc_stop_exits_on_stdin_eof :: proc(t: ^testing.T) {
		clock := lsproc_test_clock(t)
		if clock == nil {
			return
		}
		defer lsproc_test_clock_free(clock)

		p, err := lsproc.lsproc_spawn(
			{command = {"cat"}, language_id = "test"},
			clock, context.allocator,
		)
		if err != nil {
			testing.expectf(t, false, "spawn cat: %s", platform.err_message(err))
			return
		}
		defer lsproc.lsproc_destroy(p)

		ping_str := "ping\n"
		ping := transmute([]u8)ping_str
		sent := lsproc.lsproc_write_stdin(p, ping)
		testing.expect_value(t, sent, 5)

		buf: [64]u8
		line, ok := lsproc_read_line(p, buf[:])
		testing.expect(t, ok)
		testing.expectf(t, line == "ping\n", "echo mismatch: %q", line)

		stage := lsproc.lsproc_stop(p, 500)
		testing.expect_value(t, stage, lsproc.Stop_Stage.Exited_Before_Signal)

		exited, code := lsproc.lsproc_exited(p)
		testing.expect(t, exited)
		testing.expect_value(t, code, 0)
	}

	// The escalation path: sh traps SIGTERM and survives stage 2, its
	// sleep child does not (the tree walk found it), and stage 3's SIGKILL
	// tree takes the trapping parent down. Nothing in the tree survives.
	@(test)
	lsproc_stop_escalates_to_kill_tree :: proc(t: ^testing.T) {
		clock := lsproc_test_clock(t)
		if clock == nil {
			return
		}
		defer lsproc_test_clock_free(clock)

		p, err := lsproc.lsproc_spawn(
			{
				command     = {"/bin/sh", "-c", "trap '' TERM; sleep 60; sleep 60"},
				language_id = "test",
			},
			clock, context.allocator,
		)
		if err != nil {
			testing.expectf(t, false, "spawn sh: %s", platform.err_message(err))
			return
		}
		defer lsproc.lsproc_destroy(p)

		// Wait until sh forked its sleep child (an OS fact, not test time
		// logic: bounded polling with a monotonic deadline).
		children := lsproc.lsproc_child_pids(p.pid, context.temp_allocator)
		deadline := platform.mono_ms() + 3000
		for len(children) == 0 && platform.mono_ms() < deadline {
			platform.clock_wait(clock, 5)
			children = lsproc.lsproc_child_pids(p.pid, context.temp_allocator)
		}
		if len(children) == 0 {
			testing.expectf(t, false, "sh never forked a child")
			return
		}

		stage := lsproc.lsproc_stop(p, 150)
		testing.expect_value(t, stage, lsproc.Stop_Stage.Exited_After_Kill)

		exited, _ := lsproc.lsproc_exited(p)
		testing.expect(t, exited)

		// The whole tree is gone: the parent's list is empty (dead pid)
		// and so is the child we observed.
		after_parent := lsproc.lsproc_child_pids(p.pid, context.temp_allocator)
		testing.expect_value(t, len(after_parent), 0)
		after_child := lsproc.lsproc_child_pids(children[0], context.temp_allocator)
		testing.expect_value(t, len(after_child), 0)
	}

	// A dead child turns stdin writes into a reported failure, not a
	// SIGPIPE that kills this whole process (ignore_sigpipe is armed at
	// spawn).
	@(test)
	lsproc_write_after_death_reports_error :: proc(t: ^testing.T) {
		clock := lsproc_test_clock(t)
		if clock == nil {
			return
		}
		defer lsproc_test_clock_free(clock)

		p, err := lsproc.lsproc_spawn(
			{command = {"/bin/sh", "-c", "exit 0"}, language_id = "test"},
			clock, context.allocator,
		)
		if err != nil {
			testing.expectf(t, false, "spawn sh: %s", platform.err_message(err))
			return
		}
		defer lsproc.lsproc_destroy(p)

		exited, _ := lsproc.lsproc_wait_exit(p, 2000)
		testing.expect(t, exited)

		ping_str := "ping\n"
		n := lsproc.lsproc_write_stdin(p, transmute([]u8)ping_str)
		testing.expect_value(t, n, -1)
	}

	// The watcher reports the child's exit code and a second stop is a
	// no-op on an already-dead child.
	@(test)
	lsproc_exit_code_reported :: proc(t: ^testing.T) {
		clock := lsproc_test_clock(t)
		if clock == nil {
			return
		}
		defer lsproc_test_clock_free(clock)

		p, err := lsproc.lsproc_spawn(
			{command = {"/bin/sh", "-c", "exit 7"}, language_id = "test"},
			clock, context.allocator,
		)
		if err != nil {
			testing.expectf(t, false, "spawn sh: %s", platform.err_message(err))
			return
		}
		defer lsproc.lsproc_destroy(p)

		exited, _ := lsproc.lsproc_wait_exit(p, 2000)
		testing.expect(t, exited)
		gone, code := lsproc.lsproc_exited(p)
		testing.expect(t, gone)
		testing.expect_value(t, code, 7)

		stage := lsproc.lsproc_stop(p, 100)
		testing.expect_value(t, stage, lsproc.Stop_Stage.Exited_Before_Signal)
	}

	// Containment is best effort: with a delegated cgroup subtree the
	// child is contained and the watcher's exit path releases it; without
	// delegation the child still runs (containment never blocks a start).
	@(test)
	lsproc_containment_best_effort :: proc(t: ^testing.T) {
		clock := lsproc_test_clock(t)
		if clock == nil {
			return
		}
		defer lsproc_test_clock_free(clock)

		p, err := lsproc.lsproc_spawn(
			{
				command         = {"/bin/sh", "-c", "exit 0"},
				language_id     = "test-language",
				memory_limit_mb = 64,
			},
			clock, context.allocator,
		)
		if err != nil {
			testing.expectf(t, false, "spawn sh: %s", platform.err_message(err))
			return
		}
		defer lsproc.lsproc_destroy(p)

		was_contained := lsproc.lsproc_contained(p)
		exited, _ := lsproc.lsproc_wait_exit(p, 2000)
		testing.expect(t, exited)
		// Either way containment reports released once the child is gone.
		testing.expect(t, !lsproc.lsproc_contained(p))
		_ = was_contained // diagnostic only: the assert above holds on both paths
	}

}

// An unresolvable binary fails the spawn with an error and no Proc.
@(test)
lsproc_spawn_missing_binary_fails :: proc(t: ^testing.T) {
	clock := lsproc_test_clock(t)
	if clock == nil {
		return
	}
	defer lsproc_test_clock_free(clock)

	p, err := lsproc.lsproc_spawn(
		{command = {"aubade-no-such-binary-xyz"}, language_id = "test"},
		clock, context.allocator,
	)
	testing.expect(t, err != nil)
	testing.expect(t, p == nil)
}

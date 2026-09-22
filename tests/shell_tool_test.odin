// Tests for the shell_run tool and the platform procrun runner: capture,
// stream caps, the timeout kill, scrubbed environment inheritance, cwd
// containment, and the nil-safety refusal. The sh-based cases are
// posix-only; Windows covers the runner through type-checking and the
// E2E layer (cmd.exe).
package tests

import "core:encoding/json"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "src:platform"
import "src:safety"
import "src:tools"
import "src:util"

// shell_call runs shell_run with validated args and returns the answer
// text and error flag. Materializing the tool table locally mirrors the
// dispatch path.
shell_call :: proc(t: ^testing.T, a: mem.Allocator, root: string, sc: ^safety.Safety_Checker, args_json: string) -> (text: string, is_error: bool) {
	table := tools.TOOLS
	desc := table[int(tools.Tool_ID.Shell_Run)]
	testing.expect(t, desc.name == "shell_run")

	parsed, perr := json.parse_string(args_json, spec = .JSON, parse_integers = true, allocator = a)
	testing.expectf(t, perr == nil, "test args must parse: %v", perr)
	values, err_msg := tools.validate_args(&desc, parsed, a)
	testing.expectf(t, err_msg == "", "validate: %s", err_msg)

	args := tools.Args{raw = args_json, values = values}
	ctx := tools.Tool_Ctx{allocator = a, safety = sc, project_root = root}
	result := desc.apply(&ctx, &args)
	return tools.result_text(result, a), result.is_error
}

// --- platform.procrun ---------------------------------------------------------

@(test)
procrun_captures_streams_and_exit_code :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	res, err := platform.procrun(platform.Procrun_Opts{
		command        = {"sh", "-c", "printf out; printf err >&2; exit 3"},
		capture_stderr = true,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, res.stdout, "out")
	testing.expect_value(t, res.stderr, "err")
	testing.expect_value(t, res.exit_code, 3)
	testing.expect(t, !res.timed_out)
}

@(test)
procrun_discards_stderr_when_not_captured :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	res, err := platform.procrun(platform.Procrun_Opts{
		command        = {"sh", "-c", "printf out; printf err >&2"},
		capture_stderr = false,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, res.stdout, "out")
	testing.expect_value(t, res.stderr, "")
}

@(test)
procrun_caps_each_stream :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	res, err := platform.procrun(platform.Procrun_Opts{
		command          = {"sh", "-c", "head -c 4096 /dev/zero"},
		capture_stderr   = false,
		max_stream_bytes = 100,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(res.stdout), 100)
}

@(test)
procrun_timeout_kills_runaway_child :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	started := platform.mono_ms()
	res, err := platform.procrun(platform.Procrun_Opts{
		command        = {"sh", "-c", "sleep 5"},
		capture_stderr = false,
		timeout_ms     = 250,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, res.timed_out)
	testing.expect_value(t, res.exit_code, -1)
	testing.expectf(t, platform.mono_ms()-started < 3000, "timeout kill took too long")
}

// A fired cancel token kills the child mid-run at the next poll — the
// checkpoint discipline every blocking wait follows (real-time by design,
// like the timeout test above; the helper thread plays the canceller).
@(test)
procrun_token_kills_mid_run :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	Token_Box :: struct {tok: ^platform.Cancel_Token}
	box := new(Token_Box, context.allocator)
	defer free(box, context.allocator)
	box^ = {tok = root}
	fire_later :: proc(data: rawptr) {
		b := cast(^Token_Box)data
		time.sleep(250 * time.Millisecond)
		platform.token_fire(b.tok, .Cancelled)
	}
	canceller := thread.create_and_start_with_data(box, fire_later, self_cleanup = false)

	started := platform.mono_ms()
	res, err := platform.procrun(platform.Procrun_Opts{
		command        = {"sh", "-c", "sleep 5"},
		capture_stderr = false,
		timeout_ms     = 30_000,
		token          = root,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, res.timed_out)
	testing.expect_value(t, res.exit_code, -1)
	testing.expectf(t, platform.mono_ms()-started < 3000, "token kill took too long")

	thread.join(canceller)
	free(canceller, context.allocator)
}

@(test)
procrun_sets_env_and_working_dir :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	tmp, err := os.make_directory_temp("", "aubade-procrun-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	res, perr := platform.procrun(platform.Procrun_Opts{
		command        = {"/bin/sh", "-c", "printf $FOO; pwd"},
		working_dir    = tmp,
		env            = {"FOO=bar"},
		capture_stderr = false,
	}, context.temp_allocator)
	testing.expect(t, perr == nil)
	testing.expect(t, strings.has_prefix(res.stdout, "bar"))
	testing.expect(t, strings.contains(res.stdout, tmp))
}

// --- shell_run tool ------------------------------------------------------------

@(test)
shell_run_refuses_without_safety_checker :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	text, is_error := shell_call(t, context.temp_allocator, "/tmp", nil, `{"command": "echo hi"}`)
	testing.expect(t, is_error)
	testing.expect(t, strings.contains(text, "requires safety checker"))
}

@(test)
shell_run_blocks_destructive_command :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	sc := new(safety.Safety_Checker, context.allocator)
	defer free(sc, context.allocator)
	defer safety.safety_checker_destroy(sc)
	safety.safety_checker_init(sc, context.allocator)

	text, is_error := shell_call(t, context.temp_allocator, "/tmp", sc, `{"command": "rm -rf /"}`)
	testing.expect(t, is_error)
	testing.expect(t, strings.contains(text, "blocked"))
}

@(test)
shell_run_answer_shape :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	root, err := os.make_directory_temp("", "aubade-shell-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(root)
		delete(root)
	}

	sc := new(safety.Safety_Checker, context.allocator)
	defer free(sc, context.allocator)
	defer safety.safety_checker_destroy(sc)
	safety.safety_checker_init(sc, context.allocator)

	// Wire field order: stdout, stderr (omitted when empty), return_code, cwd.
	text, is_error := shell_call(t, context.temp_allocator, root, sc, `{"command": "echo hi"}`)
	testing.expect(t, !is_error)
	expected := strings.concatenate({
		"{\"stdout\": \"hi\\n\", \"return_code\": 0, \"cwd\": \"", root, "\"}",
	}, context.temp_allocator)
	testing.expect_value(t, text, expected)

	text, is_error = shell_call(t, context.temp_allocator, root, sc,
		`{"command": "echo out; echo err >&2"}`)
	testing.expect(t, !is_error)
	expected = strings.concatenate({
		"{\"stdout\": \"out\\n\", \"stderr\": \"err\\n\", \"return_code\": 0, \"cwd\": \"", root, "\"}",
	}, context.temp_allocator)
	testing.expect_value(t, text, expected)

	text, is_error = shell_call(t, context.temp_allocator, root, sc, `{"command": "exit 7"}`)
	testing.expect(t, !is_error)
	expected = strings.concatenate({
		"{\"stdout\": \"\", \"return_code\": 7, \"cwd\": \"", root, "\"}",
	}, context.temp_allocator)
	testing.expect_value(t, text, expected)

	// capture_stderr=false: no stderr key even when the child writes some.
	text, is_error = shell_call(t, context.temp_allocator, root, sc,
		`{"command": "echo err >&2", "capture_stderr": false}`)
	testing.expect(t, !is_error)
	expected = strings.concatenate({
		"{\"stdout\": \"\", \"return_code\": 0, \"cwd\": \"", root, "\"}",
	}, context.temp_allocator)
	testing.expect_value(t, text, expected)
}

@(test)
shell_run_cwd_containment :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	root, err := os.make_directory_temp("", "aubade-shell-cwd-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	_ = os.make_directory(strings.concatenate({root, "/sub"}, context.temp_allocator), os.Permissions{.Read_User, .Write_User, .Execute_User})

	sc := new(safety.Safety_Checker, context.allocator)
	defer free(sc, context.allocator)
	defer safety.safety_checker_destroy(sc)
	safety.safety_checker_init(sc, context.allocator)

	text, is_error := shell_call(t, context.temp_allocator, root, sc, `{"command": "pwd", "cwd": "sub"}`)
	testing.expect(t, !is_error)
	testing.expect(t, strings.contains(text, strings.concatenate({root, "/sub"}, context.temp_allocator)))

	_, is_error = shell_call(t, context.temp_allocator, root, sc, `{"command": "pwd", "cwd": ".."}`)
	testing.expect(t, is_error)

	_, is_error = shell_call(t, context.temp_allocator, root, sc, `{"command": "pwd", "cwd": "/etc"}`)
	testing.expect(t, is_error)

	text, is_error = shell_call(t, context.temp_allocator, root, sc, `{"command": "pwd", "cwd": "missing"}`)
	testing.expect(t, is_error)
	testing.expect(t, strings.contains(text, "not a valid directory"))

	// The project root itself is a legitimate cwd — both relative and
	// absolute spellings (the hand-rolled prefix check this replaces
	// rejected the root because it never matches its own "root/" prefix).
	text, is_error = shell_call(t, context.temp_allocator, root, sc, `{"command": "pwd", "cwd": "."}`)
	testing.expect(t, !is_error)
	testing.expect(t, strings.contains(text, root))

	abs_json := strings.concatenate({`{"command": "pwd", "cwd": "`, root, `"}`}, context.temp_allocator)
	text, is_error = shell_call(t, context.temp_allocator, root, sc, abs_json)
	testing.expect(t, !is_error)
	testing.expect(t, strings.contains(text, root))

	// A symlink inside the root pointing outside must not smuggle the cwd
	// past the boundary.
	if lerr := os.symlink("/etc", strings.concatenate({root, "/outside"}, context.temp_allocator)); lerr == nil {
		_, is_error = shell_call(t, context.temp_allocator, root, sc, `{"command": "pwd", "cwd": "outside"}`)
		testing.expect(t, is_error)
	}
}

@(test)
shell_run_scrubs_environment :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	old, had := os.lookup_env_alloc("AUBADE_TEST_MARKER", context.temp_allocator)
	os.set_env("AUBADE_TEST_MARKER", "leaky")
	if had {
		defer os.set_env("AUBADE_TEST_MARKER", old)
	} else {
		defer os.unset_env("AUBADE_TEST_MARKER")
	}

	sc := new(safety.Safety_Checker, context.allocator)
	defer free(sc, context.allocator)
	defer safety.safety_checker_destroy(sc)
	safety.safety_checker_init(sc, context.allocator)

	// PATH stays allowed (the spawn itself resolves sh through it) while
	// the unlisted marker variable is dropped from the child environment.
	text, is_error := shell_call(t, context.temp_allocator, "/tmp", sc,
		`{"command": "printenv AUBADE_TEST_MARKER; true"}`)
	testing.expect(t, !is_error)
	testing.expectf(t, !strings.contains(text, "leaky"), text)
}

@(test)
procrun_group_kill_reaches_background_jobs :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	// A backgrounded job must not outlive a timed-out run: the command
	// runs in its own process group and the deadline kill lands on the
	// whole tree. The command prints its background sleeper's pid; the
	// test then waits for /proc/<pid> to disappear.
	res, err := platform.procrun(platform.Procrun_Opts{
		command        = {"sh", "-c", "echo started; sleep 30 & echo $!; wait"},
		capture_stderr = true,
		timeout_ms     = 300,
		process_group  = true,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, res.timed_out, "the run must time out")

	lines := strings.split(strings.trim_space(res.stdout), "\n", context.temp_allocator)
	defer delete(lines, context.temp_allocator)
	testing.expectf(t, len(lines) == 2 && strings.has_prefix(lines[0], "started"), "stdout: %q", res.stdout)
	if len(lines) < 2 {
		return
	}
	pid, parsed := strconv.parse_int(strings.trim_space(lines[1]), 10)
	testing.expectf(t, parsed, "sleeper pid parses: %q", lines[1])
	if !parsed || pid <= 0 {
		return
	}

	// The group kill is reaped asynchronously; give the sleeper a
	// bounded window to disappear, then prove it is gone.
	proc_path := fmt.aprintf("/proc/%d", pid, allocator = context.temp_allocator)
	defer delete(proc_path, context.temp_allocator)
	gone := false
	for _ in 0..<40 {
		if _, kok := util.lstat_kind(proc_path); !kok {
			gone = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, gone, "the backgrounded sleeper must die with the group")
}

@(test)
procrun_group_sweep_kills_stragglers_on_return :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux {
		return
	}
	// Normal-exit parity with the Windows job close: the leader finishes
	// on its own (no timeout fires), and whatever it backgrounded still
	// dies with the call — the group sweep at return.
	res, err := platform.procrun(platform.Procrun_Opts{
		command        = {"sh", "-c", "sleep 30 & echo $!"},
		capture_stderr = true,
		process_group  = true,
	}, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, !res.timed_out)

	pid, parsed := strconv.parse_int(strings.trim_space(res.stdout), 10)
	testing.expectf(t, parsed, "sleeper pid parses: %q", res.stdout)
	if !parsed || pid <= 0 {
		return
	}

	proc_path := fmt.aprintf("/proc/%d", pid, allocator = context.temp_allocator)
	defer delete(proc_path, context.temp_allocator)
	gone := false
	for _ in 0..<40 {
		if _, kok := util.lstat_kind(proc_path); !kok {
			gone = true
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expect(t, gone, "the backgrounded sleeper must die with the call")
}

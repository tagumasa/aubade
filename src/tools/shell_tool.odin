// shell_run: execute a shell command inside the project with the safety
// gates applied first — the shell guard's blocked patterns, sensitive
// write-target detection, a scrubbed environment, containment of the
// working directory, per-stream 10 MiB capture caps, the 120 s safety
// timeout that kills runaway children, and the length limiter on the JSON
// answer. A nil safety checker refuses the call outright — a command is
// never run unguarded.
package tools

import "core:encoding/json"
import "core:os"
import "core:strings"
import "src:platform"
import "src:jsonutil"
import "src:safety"
import "src:util"

SHELL_MAX_OUTPUT_BYTES :: 10 * 1024 * 1024

// The safety timeout: a command that outlives it is killed and reported
// with return code -1.
SHELL_SAFETY_TIMEOUT_MS :: 120_000

shell_run_apply :: proc(ctx: ^Tool_Ctx, args: ^Args) -> Tool_Result {
	command := arg_str(args, "command")
	if command == "" {
		return err_result(ctx, "command is required")
	}

	if ctx.safety == nil {
		return err_result(ctx, "shell_run requires safety checker to be configured")
	}
	if blocked, reason := safety.check_command(ctx.safety, command); blocked {
		return err_result(ctx, strings.concatenate({"safety: command blocked: ", reason}, ctx.allocator))
	}
	if detected, desc := safety.check_sensitive_path(ctx.safety, command); detected {
		return err_result(ctx, strings.concatenate({"command blocked: ", desc}, ctx.allocator))
	}

	cwd := ctx.project_root
	requested := arg_str(args, "cwd")
	if requested != "" {
		// Containment (lexical + symlink) lives in safety — one engine for
		// every consumer. The hand-rolled prefix check this replaces was
		// case-sensitive, separator-blind on Windows, rejected the project
		// root itself, and never looked at symlinks.
		candidate, esc := safety.pathguard_validate_contained_dir(ctx.project_root, requested, ctx.allocator)
		if esc.reason != "" {
			return err_result(ctx, strings.concatenate(
				{"working directory must be within the project root: ", esc.reason}, ctx.allocator,
			))
		}
		if !os.is_directory(candidate) {
			return err_result(ctx, strings.concatenate(
				{"specified working directory is not a valid directory: ", candidate}, ctx.allocator,
			))
		}
		cwd = candidate
	}

	capture_stderr := true
	if arg_has(args, "capture_stderr") {
		capture_stderr = arg_bool(args, "capture_stderr")
	}

	shell := "sh"
	shell_flag := "-c"
	when ODIN_OS == .Windows {
		shell = "cmd.exe"
		shell_flag = "/C"
	}

	// The token is the checkpoint: refuse before spawning, and cap the
	// safety timeout at the call's remaining deadline so a cancelled
	// session's command ends with its deadline, not the full 120 s.
	if ctx.cancel != nil {
		if _, fired := platform.token_check(ctx.cancel); fired {
			return err_result(ctx, "request cancelled before command execution")
		}
	}
	op_timeout := i64(SHELL_SAFETY_TIMEOUT_MS)
	if ctx.cancel != nil && ctx.cancel.deadline > 0 {
		// Real-time read by design (same stance as slot_wait): token
		// deadlines are mono-domain absolute timestamps and this layer
		// holds no injected clock — in production the two sources are
		// identical.
		remaining := ctx.cancel.deadline - platform.mono_ms()
		if remaining <= 0 {
			return err_result(ctx, "request deadline exceeded before command execution")
		}
		if remaining < op_timeout {
			op_timeout = remaining
		}
	}
	run_res, run_err := platform.procrun(platform.Procrun_Opts {
		command = slice_of(shell, shell_flag, command, ctx.allocator),
		working_dir = cwd,
		env = scrubbed_environment(ctx),
		capture_stderr = capture_stderr,
		max_stream_bytes = SHELL_MAX_OUTPUT_BYTES,
		timeout_ms = op_timeout,
		// Mid-run cancellation: a fired token kills the command at the
		// runner's next poll instead of occupying the worker to the deadline.
		token = ctx.cancel,
		// The command runs contained so the whole tree dies with the
		// call — the timeout/cancel stop and the return sweep both land
		// on it: a backgrounded job must not outlive the call that
		// spawned it (POSIX: own process group; Windows: a kill-on-close
		// Job object).
		process_group = true,
	}, ctx.allocator)
	if run_err != nil {
		return err_result(ctx, "command execution failed")
	}

	// The answer object renders {stdout, stderr (omitempty), return_code,
	// cwd} in that declaration order — clients pin the byte shape.
	parts: [4]string
	parts[0] = strings.concatenate({
		"{\"stdout\": ", jsonutil.json_quote(run_res.stdout, ctx.allocator),
		", ",
	}, ctx.allocator)
	parts[1] = ""
	if capture_stderr && run_res.stderr != "" {
		parts[1] = strings.concatenate({
			"\"stderr\": ", jsonutil.json_quote(run_res.stderr, ctx.allocator),
			", ",
		}, ctx.allocator)
	}
	parts[2] = strings.concatenate({
		"\"return_code\": ", util.int_to_dec(run_res.exit_code, ctx.allocator),
		", \"cwd\": ", jsonutil.json_quote(cwd, ctx.allocator),
		"}",
	}, ctx.allocator)
	parts[3] = ""
	body := strings.concatenate(parts[:], ctx.allocator)

	max_chars := util.resolve_max_chars(arg_int(args, "max_answer_chars"), ctx.default_max_chars)
	return text_result(ctx, util.limit_length(body, max_chars, nil, ctx.allocator))
}

// scrubbed_environment returns the child environment with every variable
// the env guard does not allow removed (the list is scratch memory: it is
// consumed by the spawn itself).
scrubbed_environment :: proc(ctx: ^Tool_Ctx) -> []string {
	env, err := os.environ(context.temp_allocator)
	if err != nil || len(env) == 0 {
		return nil
	}
	return safety.scrub_environment(ctx.safety, env, context.temp_allocator)
}


slice_of :: proc(a, b, c: string, allocator := context.allocator) -> []string {
	out := make([]string, 3, allocator)
	out[0] = a
	out[1] = b
	out[2] = c
	return out
}

SHELL_RUN_PARAMS :: []Param_Desc{
	{name = "command", kind = .Str, description = "The shell command to execute.", required = true},
	{name = "cwd", kind = .Str, description = "Working directory (absolute inside the project, or relative to the project root).", required = false},
	{name = "capture_stderr", kind = .Bool, description = "Capture stderr into the result (default true).", required = false},
	{name = "max_answer_chars", kind = .Int, description = "Truncate the answer to at most this many characters (-1 = unlimited).", required = false},
}

// arg_int reads a validated integer parameter (0 when absent).
arg_int :: proc(args: ^Args, name: string) -> int {
	if v, ok := args.values[name]; ok {
		#partial switch x in v {
		case json.Integer:
			return int(x)
		case:
		}
	}
	return 0
}

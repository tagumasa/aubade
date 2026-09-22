// aubade hook [--client <name>] <verb>: session lifecycle hooks for MCP
// clients. Reads the hook payload from stdin and prints the response JSON
// on stdout (nothing when the hook decides not to speak).
package cli

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "src:hooks"
import "src:tools"
import "src:util"

// Hook input is capped at 1 MiB; anything past it is truncated.
HOOK_INPUT_LIMIT :: 1 << 20

// Hook_Verb is one row of the verb table: validation, the usage line,
// and dispatch all walk the same rows. Remind carries the injected
// aubade tool names; the other verbs ignore them.
Hook_Verb :: struct {
	name: string,
	run:  proc(client_name: string, raw: []u8, now_unix: i64, names: hooks.Aubade_Tool_Names, a: mem.Allocator) -> hooks.Hook_Outcome,
}

hook_activate :: proc(client_name: string, raw: []u8, now_unix: i64, names: hooks.Aubade_Tool_Names, a: mem.Allocator) -> hooks.Hook_Outcome {
	return hooks.run_activate(client_name, raw, now_unix, a)
}

hook_cleanup :: proc(client_name: string, raw: []u8, now_unix: i64, names: hooks.Aubade_Tool_Names, a: mem.Allocator) -> hooks.Hook_Outcome {
	return hooks.run_cleanup(client_name, raw, now_unix, a)
}

hook_remind :: proc(client_name: string, raw: []u8, now_unix: i64, names: hooks.Aubade_Tool_Names, a: mem.Allocator) -> hooks.Hook_Outcome {
	return hooks.run_remind(client_name, raw, now_unix, names, a)
}

hook_auto_approve :: proc(client_name: string, raw: []u8, now_unix: i64, names: hooks.Aubade_Tool_Names, a: mem.Allocator) -> hooks.Hook_Outcome {
	return hooks.run_auto_approve(client_name, raw, now_unix, names, a)
}

HOOK_VERBS :: []Hook_Verb{
	{name = "activate",     run = hook_activate},
	{name = "cleanup",      run = hook_cleanup},
	{name = "remind",       run = hook_remind},
	{name = "auto-approve", run = hook_auto_approve},
}

hook_verb_known :: proc(verb: string) -> bool {
	for v in HOOK_VERBS {
		if v.name == verb {
			return true
		}
	}
	return false
}

// hook_usage renders the missing-verb refusal and --help answer — the
// verb alternatives come from the table, one declaration.
hook_usage :: proc(a := context.allocator) -> string {
	names := make([dynamic]string, 0, len(HOOK_VERBS), context.temp_allocator)
	defer delete(names)
	for v in HOOK_VERBS {
		append(&names, v.name)
	}
	return strings.concatenate(
		{"usage: aubade hook [--client ", util.quoted_join(hooks.HOOK_CLIENT_NAMES, "|", "", a), "] ", util.quoted_join(names[:], "|", "", a)},
		a,
	)
}

run_hook_cmd :: proc(args: []string, g: ^Globals, version: string) -> int {
	client := hooks.HOOK_CLIENT_NAMES[0]
	rest := make([dynamic]string, 0, len(args), context.temp_allocator)

	i := 0
	for i < len(args) {
		n := try_global(args, i, g)
		if n < 0 {
			return usage_error("hook", "invalid global flag value")
		}
		if n > 0 {
			i += n
			continue
		}
		arg := args[i]
		switch arg {
		case "--help", "-h":
			// The root table answers --help itself; the hook verb does the
			// same (setup's follow-up hint points here).
			fmt.println(hook_usage(context.temp_allocator))
			return 0
		case "--client":
			if i + 1 >= len(args) {
				return usage_error("hook", "--client requires a value")
			}
			i += 1
			client = args[i]
		case:
			append(&rest, arg)
		}
		i += 1
	}

	if len(rest) != 1 {
		return usage_error("hook", hook_usage(context.temp_allocator))
	}
	verb := rest[0]
	// Validate the verb before draining stdin: an unrecognized verb on a
	// TTY would otherwise block reading terminal stdin until EOF instead
	// of answering the usage error immediately.
	if !hook_verb_known(verb) {
		return usage_error("hook", fmt.aprintf("unknown hook verb %q", verb, allocator = context.temp_allocator))
	}

	raw := read_hook_stdin()
	now_unix := time.time_to_unix(time.now())

	// The canonical aubade tool names come from the tools registry (this
	// layer may import it); the hooks package receives them by injection
	// and stays below the tools layer.
	names := hooks.Aubade_Tool_Names{
		file_search = tools.tool_name(.File_Search),
		file_read   = tools.tool_name(.File_Read),
		symbolic    = tools.symbolic_hook_names(context.temp_allocator),
	}

	out: hooks.Hook_Outcome
	for v in HOOK_VERBS {
		if v.name == verb {
			out = v.run(client, raw, now_unix, names, context.temp_allocator)
			break
		}
	}

	if out.err != "" {
		fmt.eprintf("aubade hook: %s\n", out.err)
		return 1
	}
	if out.stdout != "" {
		fmt.print(out.stdout)
	}
	return 0
}

// read_hook_stdin reads the whole hook payload with the size cap.
read_hook_stdin :: proc() -> []u8 {
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	block: [4096]u8
	for len(buf) <= HOOK_INPUT_LIMIT {
		n, err := os.read(os.stdin, block[:])
		for b in block[:n] {
			append(&buf, b)
		}
		if n == 0 || err == .EOF || err != nil {
			break
		}
	}
	if len(buf) > HOOK_INPUT_LIMIT {
		fmt.eprintln("aubade hook: hook input exceeded 1 MiB limit, truncated")
		return buf[:HOOK_INPUT_LIMIT]
	}
	return buf[:]
}

// Tests for src/hooks — output goldens are byte-exact captures of the
// wire format; a byte drift here is a client-contract regression.
// Counter state is seeded under an isolated
// AUBADE_HOME and time is injected.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:hooks"
import "src:tools"

HOOK_NOW :: i64(1_800_000_000)

// The canonical aubade tool names, exactly as the CLI host injects them
// into the hooks entry points (from the tools registry).
hook_names :: proc() -> hooks.Aubade_Tool_Names {
	return {
		file_search = tools.tool_name(.File_Search),
		file_read   = tools.tool_name(.File_Read),
		symbolic    = tools.symbolic_hook_names(context.temp_allocator),
	}
}

hook_home :: proc(t: ^testing.T) -> (tmp: string, restore: bool, old: string) {
	tmp_dir, err := os.make_directory_temp("", "aubade-hooks-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	prev, had := os.lookup_env_alloc("AUBADE_HOME", context.temp_allocator)
	restore = had
	os.set_env("AUBADE_HOME", tmp_dir)
	return tmp_dir, restore, prev
}

hook_home_release :: proc(tmp: string, restore: bool, old: string) {
	if restore {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}
	_ = os.remove_all(tmp)
	delete(tmp)
}

// seed_counter writes hook_data/<sid>/tool_use_counter.json verbatim.
seed_counter :: proc(home, sid, body: string) {
	dir, _ := filepath.join([]string{home, "hook_data", sid}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	path, _ := filepath.join([]string{dir, "tool_use_counter.json"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(path, body, os.Permissions{.Read_User, .Write_User})
}

// read_counter_file returns the persisted counter bytes ("" when missing).
read_counter_file :: proc(home, sid: string) -> string {
	path, _ := filepath.join(
		[]string{home, "hook_data", sid, "tool_use_counter.json"},
		context.temp_allocator,
	)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

hook_json :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

hook_value :: proc(s: string) -> json.Value {
	v, _ := json.parse_bytes(transmute([]u8)s, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	return v
}

@(test)
hook_activate_goldens :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	payload := "{\"session_id\":\"abc-123\",\"cwd\":\"/tmp\"}"

	out := hooks.run_activate("claudecode", hook_json(payload), HOOK_NOW, context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout,
		"{\"hookSpecificOutput\":{\"additionalContext\":\"**IMPORTANT**: Activate the current working directory as project using Aubade's tools if not already done. If you haven't read Aubade Instructions Manual yet, do so. Follow this instruction before doing anything else.\",\"hookEventName\":\"SessionStart\"}}\n")

	out = hooks.run_activate("codex", hook_json(payload), HOOK_NOW, context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect(t, out.stdout == "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\"}}\n")
}

@(test)
hook_auto_approve_goldens :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	payload := "{\"session_id\":\"abc-123\",\"tool_name\":\"mcp__aubade__symbol_find\",\"permission_mode\":\"acceptEdits\"}"

	out := hooks.run_auto_approve("claudecode", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout,
		"{\"hookSpecificOutput\":{\"additionalContext\":\"\",\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"Auto-approved: Aubade tool call while client is in acceptEdits mode.\"}}\n")

	out = hooks.run_auto_approve("codex", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout,
		"{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"permissionDecisionReason\":\"Auto-approved: Aubade tool call while client is in acceptEdits mode.\"}}\n")

	// Non-symbolic aubade tools and other permission modes stay silent.
	out = hooks.run_auto_approve(
		"claudecode",
		hook_json("{\"session_id\":\"abc-123\",\"tool_name\":\"mcp__aubade__onboarding_check\",\"permission_mode\":\"acceptEdits\"}"),
		HOOK_NOW, hook_names(), context.temp_allocator,
	)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout, "")

	out = hooks.run_auto_approve(
		"claudecode",
		hook_json("{\"session_id\":\"abc-123\",\"tool_name\":\"mcp__aubade__symbol_find\",\"permission_mode\":\"default\"}"),
		HOOK_NOW, hook_names(), context.temp_allocator,
	)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout, "")
}

@(test)
hook_remind_grep_deny_golden :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	seed_counter(
		home, "abc-123",
		"{\"n_recent_read_file_uses\":0,\"n_recent_grep_uses\":3,\"n_recent_non_symbolic_uses\":3," +
		"\"last_grep_use_timestamp\":1799999990,\"last_non_symbolic_use_timestamp\":1799999990}",
	)

	payload := "{\"session_id\":\"abc-123\",\"tool_name\":\"grep\",\"tool_input\":{\"path_pattern\":\"x\"}}"
	out := hooks.run_remind("claudecode", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout,
		"{\"hookSpecificOutput\":{\"additionalContext\":\"You were using many grep calls recently. Consider using Aubade's symbolic mcp tools instead for more code-centric search. You can continue using grep now if needed, the counter was reset.\",\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Too many consecutive grep calls without using symbolic tools. You can continue using grep now if needed, the counter was reset.\"}}\n")

	// The counter resets and records the deny time (reference JSON shape).
	saved := read_counter_file(home, "abc-123")
	expected := fmt_counter_after_deny()
	testing.expect(t, saved == expected, "saved counter mismatch (see log)")
}

@(test)
hook_remind_read_deny_golden :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	seed_counter(
		home, "abc-123",
		"{\"n_recent_read_file_uses\":3,\"n_recent_grep_uses\":0,\"n_recent_non_symbolic_uses\":3," +
		"\"last_read_file_use_timestamp\":1799999990,\"last_non_symbolic_use_timestamp\":1799999990}",
	)

	payload := "{\"session_id\":\"abc-123\",\"tool_name\":\"read\",\"tool_input\":{\"file_path\":\"/x/main.go\"}}"
	out := hooks.run_remind("claudecode", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout,
		"{\"hookSpecificOutput\":{\"additionalContext\":\"You were using many read file calls recently. Consider using Aubade's symbolic mcp tools instead for more targeted reads. You can continue using read now if needed, the counter was reset.\",\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Too many consecutive read calls without using symbolic tools. You can continue using read now if needed, the counter was reset.\"}}\n")
}

@(test)
hook_remind_non_symbolic_deny_golden :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	// The current tool reads a non-code file: neither the read nor the grep
	// counter grows, but the mixed non-symbolic state is over threshold.
	seed_counter(
		home, "abc-123",
		"{\"n_recent_read_file_uses\":0,\"n_recent_grep_uses\":0,\"n_recent_non_symbolic_uses\":4," +
		"\"last_non_symbolic_use_timestamp\":1799999990}",
	)

	payload := "{\"session_id\":\"abc-123\",\"tool_name\":\"read\",\"tool_input\":{\"file_path\":\"/x/notes.txt\"}}"
	out := hooks.run_remind("claudecode", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout,
		"{\"hookSpecificOutput\":{\"additionalContext\":\"You were alternating between grep and read file calls recently without using Aubade's symbolic mcp tools. Consider using symbolic search and targeted symbol reads instead for more code-centric exploration. You can continue using these tools now if needed, the counter was reset.\",\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Too many consecutive non-symbolic tool calls (mixed grep and read). You can continue using these tools now if needed, the counter was reset.\"}}\n")
}

fmt_counter_after_deny :: proc() -> string {
	return "{\"n_recent_read_file_uses\":0,\"n_recent_grep_uses\":0,\"n_recent_non_symbolic_uses\":0,\"last_deny_timestamp\":1800000000}"
}

@(test)
hook_remind_counts_and_resets :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	// Codex shell command: rg counts as grep, no deny below threshold.
	seed_counter(
		home, "abc-123",
		"{\"n_recent_read_file_uses\":0,\"n_recent_grep_uses\":1,\"n_recent_non_symbolic_uses\":1," +
		"\"last_grep_use_timestamp\":1799999990,\"last_non_symbolic_use_timestamp\":1799999990}",
	)
	payload := "{\"session_id\":\"abc-123\",\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"rg pattern .\"}}"
	out := hooks.run_remind("codex", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout, "")
	testing.expect(
		t,
		read_counter_file(home, "abc-123") ==
		("{\"n_recent_read_file_uses\":0,\"n_recent_grep_uses\":2,\"n_recent_non_symbolic_uses\":2," +
		"\"last_grep_use_timestamp\":1800000000,\"last_non_symbolic_use_timestamp\":1800000000}"),
		"codex shell grep counter mismatch",
	)

	// A symbolic aubade tool resets everything (reference omits the null
	// optional timestamps).
	payload = "{\"session_id\":\"abc-123\",\"tool_name\":\"mcp__aubade__symbol_find\"}"
	out = hooks.run_remind("claudecode", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout, "")
	testing.expect(
		t,
		read_counter_file(home, "abc-123") ==
		"{\"n_recent_read_file_uses\":0,\"n_recent_grep_uses\":0,\"n_recent_non_symbolic_uses\":0}",
		"symbolic reset counter mismatch",
	)
}

@(test)
hook_remind_deny_interval_suppressed :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	// A deny 10 s ago: the hook stays quiet and the counter is untouched.
	seed_counter(
		home, "abc-123",
		"{\"n_recent_read_file_uses\":3,\"n_recent_grep_uses\":3,\"n_recent_non_symbolic_uses\":4," +
		"\"last_read_file_use_timestamp\":1799999990,\"last_grep_use_timestamp\":1799999990," +
		"\"last_non_symbolic_use_timestamp\":1799999990,\"last_deny_timestamp\":1799999990}",
	)
	seed_bytes := read_counter_file(home, "abc-123")

	payload := "{\"session_id\":\"abc-123\",\"tool_name\":\"grep\"}"
	out := hooks.run_remind("claudecode", hook_json(payload), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout, "")
	testing.expect_value(t, read_counter_file(home, "abc-123"), seed_bytes)
}

@(test)
hook_cleanup_removes_session_dir :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	seed_counter(home, "abc-123", "{}")
	out := hooks.run_cleanup("claudecode", hook_json("{\"session_id\":\"abc-123\"}"), HOOK_NOW, context.temp_allocator)
	testing.expect_value(t, out.err, "")
	testing.expect_value(t, out.stdout, "")

	dir, _ := filepath.join([]string{home, "hook_data", "abc-123"}, context.temp_allocator)
	testing.expect(t, !os.is_directory(dir), "cleanup must remove the session dir")
}

@(test)
hook_input_errors :: proc(t: ^testing.T) {
	home, restore, old := hook_home(t)
	defer hook_home_release(home, restore, old)

	// Bad JSON.
	out := hooks.run_activate("claudecode", hook_json("{nope"), HOOK_NOW, context.temp_allocator)
	testing.expect(t, out.err != "")

	// Missing session id.
	out = hooks.run_activate("claudecode", hook_json("{\"cwd\":\"/x\"}"), HOOK_NOW, context.temp_allocator)
	testing.expect(t, strings.contains(out.err, "session ID is required"))

	// Invalid session id (path separator).
	out = hooks.run_remind(
		"claudecode",
		hook_json("{\"session_id\":\"a/b\",\"tool_name\":\"grep\"}"),
		HOOK_NOW, hook_names(), context.temp_allocator,
	)
	testing.expect(t, strings.contains(out.err, "invalid session ID"))

	// Missing tool name.
	out = hooks.run_remind("claudecode", hook_json("{\"session_id\":\"abc\"}"), HOOK_NOW, hook_names(), context.temp_allocator)
	testing.expect(t, strings.contains(out.err, "tool name is required"))

	// Unknown client.
	out = hooks.run_activate("nonsense", hook_json("{\"session_id\":\"abc\"}"), HOOK_NOW, context.temp_allocator)
	testing.expect(t, strings.contains(out.err, "unknown hook client"))
}

@(test)
hook_symbolic_classification :: proc(t: ^testing.T) {
	// Odin tool names through client mangling.
	testing.expect(t, hooks.is_aubade_symbolic_tool("mcp__aubade__symbol_find", hook_names()))
	testing.expect(t, hooks.is_aubade_symbolic_tool("mcp__aubade__symbol_replace_body", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("mcp__aubade__file_read", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("mcp__aubade__file_search", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("mcp__aubade__file_find", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("mcp__aubade__langserver_restart", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("mcp__aubade__onboarding_check", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("mcp__aubade__memory_list", hook_names()))
	// The marker capability probes count as working tools by category —
	// they are aubade's own read-only tools answering fixed text.
	testing.expect(t, hooks.is_aubade_symbolic_tool("mcp__aubade__marker_symbolic_read", hook_names()))
	testing.expect(t, hooks.is_aubade_symbolic_tool("mcp__aubade__marker_can_edit", hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool("grep", hook_names()))

	// Claude Code exact-name classification follows the rename.
	testing.expect(t, hooks.is_grep_tool(.Claude_Code, "file_search", nil, hook_names()))
	testing.expect(t, !hooks.is_grep_tool(.Claude_Code, "symbol_find", nil, hook_names()))
	testing.expect(t, hooks.is_read_file_tool(.Claude_Code, "file_read", nil, hook_names()))
	testing.expect(t, !hooks.is_read_file_tool(.Claude_Code, "file_search", nil, hook_names()))

	// MCP-mangled names (Claude Code and ZCode report MCP tools as
	// mcp__<server>__<tool>): demangling yields the bare name the
	// equality branches compare against.
	testing.expect(t, hooks.demangle_mcp_name("mcp__aubade__file_search") == "file_search")
	testing.expect(t, hooks.demangle_mcp_name("mcp__aubade__symbol_find") == "symbol_find")
	testing.expect(t, hooks.demangle_mcp_name("grep") == "grep")
	testing.expect(t, hooks.demangle_mcp_name("mcp__x") == "mcp__x")
	testing.expect(t, hooks.is_grep_tool(.Claude_Code, hooks.demangle_mcp_name("mcp__aubade__file_search"), nil, hook_names()))
	testing.expect(t, hooks.is_read_file_tool(.Claude_Code, hooks.demangle_mcp_name("mcp__aubade__file_read"), nil, hook_names()))
	testing.expect(t, !hooks.is_grep_tool(.Claude_Code, hooks.demangle_mcp_name("mcp__github__search_repositories"), nil, hook_names()))

	// codex shell classification.
	testing.expect(t, hooks.is_grep_tool(.Codex, "shell", hook_value("{\"command\":\"git grep foo\"}"), hook_names()))
	testing.expect(t, hooks.is_grep_tool(.Codex, "shell", hook_value("{\"command\":\"rg x\"}"), hook_names()))
	testing.expect(t, !hooks.is_grep_tool(.Codex, "shell", hook_value("{\"command\":\"cat x.go\"}"), hook_names()))
	testing.expect(t, hooks.is_read_file_tool(.Codex, "shell", hook_value("{\"command\":\"cat x.go\"}"), hook_names()))
}

@(test)
hooks_parse_demangles_mcp_names :: proc(t: ^testing.T) {
	// The parse layer keeps the raw (mangled, lowercased) name — the
	// symbolic classifier matches the server segment in it — and fills
	// tool_name_plain for the equality classifiers.
	input := hooks.Hook_Input{value = hook_value("{\"tool_name\":\"mcp__aubade__File_Search\"}")}
	err := hooks.parse_pre_tool_use(&input)
	testing.expect(t, err == "")
	testing.expect(t, input.tool_name == "mcp__aubade__file_search")
	testing.expect(t, input.tool_name_plain == "file_search")
	testing.expect(t, hooks.is_grep_tool(.Claude_Code, input.tool_name_plain, input.tool_input, hook_names()))
	testing.expect(t, !hooks.is_aubade_symbolic_tool(input.tool_name, hook_names())) // non-symbolic stays non-symbolic, mangled or plain
}

@(test)
hooks_parse_error_names_the_kind :: proc(t: ^testing.T) {
	// The parse failure message names the parser's error kind (the core
	// parser reports a typed vocabulary, no offset): the operator can
	// tell a truncated payload from a structural one.
	bad := "{\"session_id\": \"abc"
	// parse_hook runs on a scratch arena like every production caller: the
	// core parser's error path strands its partial value on the passed
	// allocator, which the arena teardown absorbs.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	_, err := hooks.parse_hook(.Claude_Code, transmute([]u8)bad, mem.dynamic_arena_allocator(&arena))
	testing.expectf(
		t,
		strings.has_prefix(err, "parsing hook input JSON: ") && len(err) > len("parsing hook input JSON: "),
		"error names its kind: %q",
		err,
	)
}

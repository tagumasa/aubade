// Apply-level tests for the svc-backed tool families: real tool applies
// against a channel-transport daemon pair, through the same
// materialized-table pattern the dispatch chain uses (constant struct
// slices tear when read directly under the test runner).
package tests

import "core:os"
import "core:path/filepath"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:config"
import "src:platform"
import "src:store"
import "src:tools"

// tool_run validates and applies one tool call; the answer text and
// error flag come back for assertions. args_json borrows the temp
// allocator; the result borrows `a`.
tool_run :: proc(t: ^testing.T, pair: ^Daemon_Pair, name: string, args_json: string, a: mem.Allocator) -> (string, bool) {
	table := tools.TOOLS
	tid, found := tools.find_by_name(name)
	if !found {
		testing.expectf(t, false, "tool %s not found", name)
		return "", true
	}
	desc := table[int(tid)]

	args_value := parse_obj(args_json)
	values, err_msg := tools.validate_args(&desc, args_value, a)
	if err_msg != "" {
		return err_msg, true
	}
	args := tools.Args{raw = args_json, values = values}

	caps := tools.Caps{available = {.Project, .Svc, .Editor, .Memories, .Tracker, .Shadow, .Web, .Shell}}
	// The pair harness folds with no config stack — the same live-set
	// shape a session without layers announces.
	visible := tools.fold_visibility(caps.available, false, nil, nil)
	ctx := tools.Tool_Ctx{
		allocator    = a,
		deadline_ms  = platform.mono_ms() + 10_000,
		caps         = &caps,
		svc_conn     = pair.conn,
		project_root = pair.tmp,
		visible      = visible,
	}
	result := desc.apply(&ctx, &args)

	parts := make([dynamic]string, 0, 2, a)
	for c in result.contents {
		if c.kind == .Text && c.text != "" {
			append(&parts, c.text)
		}
	}
	out, _ := strings.join(parts[:], "\n", a)
	delete(parts)
	return out, result.is_error
}

@(test)
tools_file_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Write answers with the fixed success string.
	out, is_err := tool_run(t, pair, "file_write", `{"relative_path": "notes/a.md", "content": "# Hi\nbody\n"}`, a)
	testing.expect(t, !is_err)
	testing.expect_value(t, out, "File created: notes/a.md.")

	out2, is_err2 := tool_run(t, pair, "file_read", `{"relative_path": "notes/a.md"}`, a)
	testing.expect(t, !is_err2)
	testing.expect_value(t, out2, "# Hi\nbody\n")

	// Line slicing.
	out3, _ := tool_run(t, pair, "file_read", `{"relative_path": "notes/a.md", "start_line": 1, "end_line": 1}`, a)
	testing.expect_value(t, out3, "body")

	// The max-answer gate withholds content and explains.
	out4, _ := tool_run(t, pair, "file_read", `{"relative_path": "notes/a.md", "max_answer_chars": 4}`, a)
	testing.expect(t, strings.contains(out4, "The answer is too long (10 characters)"))

	// Directory listing renders as JSON with dirs and files.
	svc_symbol_write_file(t, pair.tmp, "src/main.go", "package main\n")
	out5, is_err5 := tool_run(t, pair, "file_list_dir", `{"relative_path": "", "recursive": false}`, a)
	testing.expect(t, !is_err5)
	testing.expect(t, strings.contains(out5, `"dirs"`))
	testing.expect(t, strings.contains(out5, `"src"`))
	testing.expect(t, strings.contains(out5, `"notes"`))

	// Literal replace answers OK.
	out6, is_err6 := tool_run(t, pair, "file_replace", `{"relative_path": "notes/a.md", "needle": "Hi", "repl": "Hello", "mode": "literal"}`, a)
	testing.expect(t, !is_err6)
	testing.expect_value(t, out6, "OK")

	// Replace mode is enum-checked at validation.
	_, bad_mode_err := tool_run(t, pair, "file_replace", `{"relative_path": "notes/a.md", "needle": "x", "repl": "y", "mode": "wildcard"}`, a)
	testing.expect(t, bad_mode_err)

	// A daemon-side rejection weaves the wire code into the answer, so the
	// model can tell an invalid-params refusal from an internal failure.
	escape_out, escape_err := tool_run(t, pair, "file_write", `{"relative_path": "../outside.txt", "content": "x"}`, a)
	testing.expect(t, escape_err)
	testing.expect(t, strings.contains(escape_out, "[code -32602]"))

	// Move then delete round-trip.
	_, move_err := tool_run(t, pair, "file_move", `{"source_relative_path": "notes/a.md", "target_relative_path": "notes/b.md"}`, a)
	testing.expect(t, !move_err)
	moved, _ := tool_run(t, pair, "file_read", `{"relative_path": "notes/b.md"}`, a)
	testing.expect(t, strings.contains(moved, "Hello"))
	_, del_err := tool_run(t, pair, "file_delete", `{"relative_path": "notes/b.md"}`, a)
	testing.expect(t, !del_err)
	gone, gone_err := tool_run(t, pair, "file_read", `{"relative_path": "notes/b.md"}`, a)
	testing.expect(t, gone_err)
	testing.expect(t, strings.contains(gone, "not found"))
}

@(test)
tools_ast_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	out, is_err := tool_run(t, pair, "ast_parse", `{"lang": "go", "code": "package main\n"}`, a)
	testing.expect(t, !is_err)
	testing.expect_value(t, out, "(source_file (package_clause (package_identifier \"main\")))")

	code := "\"package main\\n\\nfunc alpha() {}\\n\""
	q := "\"(function_declaration name: (identifier) @name)\""
	qargs := strings.concatenate({`{"lang": "go", "code": `, code, `, "query": `, q, `}`}, context.temp_allocator)
	out2, is_err2 := tool_run(t, pair, "ast_query", qargs, a)
	testing.expect(t, !is_err2)
	testing.expect(t, strings.contains(out2, "Match 1 (pattern 0):"))
	testing.expect(t, strings.contains(out2, "@name: \"alpha\""))

	// A matching query with no hits answers with the fixed string.
	noq := strings.concatenate({`{"lang": "go", "code": `, code, `, "query": "(import_spec) @imp"}`}, context.temp_allocator)
	out3, _ := tool_run(t, pair, "ast_query", noq, a)
	testing.expect_value(t, out3, "No matches found.")

	// Syntax errors surface as error results.
	_, q_err := tool_run(t, pair, "ast_query", `{"lang": "go", "code": "package main\n", "query": "((("}`, a)
	testing.expect(t, q_err)
}

@(test)
tools_symbol_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	svc_symbol_write_file(
		t, pair.tmp, "gen.go",
		"package main\n\nfunc alpha() int {\n\treturn 1\n}\n\nfunc beta() int {\n\treturn 2\n}\n",
	)

	out, is_err := tool_run(t, pair, "symbol_list", `{"relative_path": "gen.go"}`, a)
	testing.expect(t, !is_err)
	testing.expect(t, strings.contains(out, `"kind"`))
	testing.expect(t, strings.contains(out, "alpha"))

	found, found_err := tool_run(t, pair, "symbol_find", `{"name_path_pattern": "alpha"}`, a)
	testing.expect(t, !found_err)
	testing.expect(t, strings.contains(found, "alpha"))

	body := "\"func alpha() int {\\n\\treturn 42\\n}\""
	rb, rb_err := tool_run(
		t, pair, "symbol_replace_body",
		strings.concatenate({`{"name_path": "alpha", "relative_path": "gen.go", "body": `, body, `}`}, context.temp_allocator),
		a,
	)
	testing.expect(t, !rb_err)
	testing.expect_value(t, rb, "OK")

	after, _ := tool_run(t, pair, "file_read", `{"relative_path": "gen.go"}`, a)
	testing.expect(t, strings.contains(after, "return 42"))

	ins := "\"func prior() {}\""
	ib, ib_err := tool_run(
		t, pair, "symbol_insert_before",
		strings.concatenate({`{"name_path": "alpha", "relative_path": "gen.go", "body": `, ins, `}`}, context.temp_allocator),
		a,
	)
	testing.expect(t, !ib_err)
	testing.expect_value(t, ib, "OK")

	mv, mv_err := tool_run(
		t, pair, "symbol_move",
		`{"name_path": "beta", "source_relative_path": "gen.go", "target_relative_path": "gen.go", "target_position": "alpha", "mode": "move"}`,
		a,
	)
	testing.expect(t, !mv_err)
	testing.expect(t, strings.contains(mv, "Successfully moved symbol \"beta\" from gen.go to gen.go"))

	doc, doc_err := tool_run(
		t, pair, "symbol_insert_docstring",
		`{"name_path": "alpha", "relative_path": "gen.go", "comment": "// does things."}`,
		a,
	)
	testing.expect(t, !doc_err)
	testing.expect_value(t, doc, "OK")
}

@(test)
tools_onboarding_family_apply :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	caps := tools.Caps{}
	ctx := tools.Tool_Ctx{allocator = a, caps = &caps}
	table := tools.TOOLS

	values, verr := tools.validate_args(&table[int(tools.Tool_ID.Onboarding_Read_Instructions)], parse_obj(`{"session_id": "s1"}`), a)
	testing.expect_value(t, verr, "")
	args := tools.Args{values = values}
	result := table[int(tools.Tool_ID.Onboarding_Read_Instructions)].apply(&ctx, &args)
	testing.expect(t, !result.is_error)
	testing.expect(t, len(result.contents) == 1)
	if len(result.contents) == 1 {
		text := result.contents[0].text
		testing.expect(t, strings.contains(text, "Aubade Instructions Manual"), text)
		testing.expect(t, strings.contains(text, "0-based"), text)
		testing.expect(t, strings.contains(text, "You have hereby read the 'Aubade Instructions Manual'"), text)
		// Hostless context: no parent link, so the project-facts section stays out.
		testing.expect(t, !strings.contains(text, "Project facts (this session)"), text)
	}

	values2, verr2 := tools.validate_args(&table[int(tools.Tool_ID.Onboarding_Run)], parse_obj(`{}`), a)
	testing.expect_value(t, verr2, "")
	args2 := tools.Args{values = values2}
	result2 := table[int(tools.Tool_ID.Onboarding_Run)].apply(&ctx, &args2)
	testing.expect(t, !result2.is_error)
	if len(result2.contents) == 1 {
		testing.expect(t, strings.contains(result2.contents[0].text, "viewing the project for the first time"))
		testing.expect(t, strings.contains(result2.contents[0].text, "memory_write"))
	}
}

@(test)
tools_table_visibility :: proc(t: ^testing.T) {
	// Names are unique across the table.
	table := tools.TOOLS
	seen := make(map[string]bool, len(table))
	defer delete(seen)
	for i in 0..<len(table) {
		testing.expectf(t, !seen[table[i].name], "duplicate tool name %s", table[i].name)
		seen[table[i].name] = true
	}

	// The svc-backed families appear with the parent link and vanish
	// without it; read_only strips every editing tool.
	with_svc := tools.visibility_set({.Project, .Svc, .Editor})
	testing.expect(t, tools.Tool_ID.File_Read in with_svc)
	testing.expect(t, tools.Tool_ID.Symbol_Move in with_svc)
	testing.expect(t, tools.Tool_ID.Ast_Query in with_svc)
	without_svc := tools.visibility_set({.Project})
	testing.expect(t, tools.Tool_ID.File_Read not_in without_svc)
	testing.expect(t, tools.Tool_ID.Symbol_Move not_in without_svc)
	// ast tools need only the svc link.
	ast_only := tools.visibility_set({.Svc})
	testing.expect(t, tools.Tool_ID.Ast_Parse in ast_only)
	testing.expect(t, tools.Tool_ID.File_Read not_in ast_only)

	read_only := tools.visibility_set({.Project, .Svc, .Editor}, true)
	testing.expect(t, tools.Tool_ID.File_Read in read_only)
	testing.expect(t, tools.Tool_ID.File_Write not_in read_only)
	testing.expect(t, tools.Tool_ID.Symbol_Replace_Body not_in read_only)
	testing.expect(t, tools.Tool_ID.Onboarding_Read_Instructions in read_only)

	// The langserver family's query half is default-visible; the
	// management half stays outside the base until a config layer
	// includes it (fold_test covers the inclusion itself).
	testing.expect(t, tools.Tool_ID.Langserver_List in with_svc)
	testing.expect(t, tools.Tool_ID.Langserver_Reload not_in with_svc)
	testing.expect(t, tools.Tool_ID.Langserver_Find_Calls in with_svc)
}

@(test)
tools_langserver_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// An unconfigured project lists nothing and answers the hint — whose
	// primary route is config_set (always visible, applies live).
	out, is_err := tool_run(t, pair, "langserver_list", `{}`, a)
	testing.expect(t, !is_err)
	testing.expect(t, strings.contains(out, "config_set"))
	testing.expect(t, strings.contains(out, "langserver_start"))

	// The argumentless restart cold-resets the manager.
	out2, is_err2 := tool_run(t, pair, "langserver_restart", `{}`, a)
	testing.expect(t, !is_err2)
	testing.expect(t, strings.contains(out2, "restart on demand"))

	// reload against the unconfigured project reports zeroes.
	out2b, is_err2b := tool_run(t, pair, "langserver_reload", `{}`, a)
	testing.expect(t, !is_err2b)
	testing.expect(t, strings.contains(out2b, "language server settings reloaded"))

	// start: language is a required parameter (validation, isError text).
	out3, is_err3 := tool_run(t, pair, "langserver_start", `{}`, a)
	testing.expect(t, is_err3)
	testing.expect(t, strings.contains(out3, "missing required parameter: language"))

	// start: an unregistered language surfaces the daemon's refusal.
	out4, is_err4 := tool_run(t, pair, "langserver_start", `{"language": "nosuchlang"}`, a)
	testing.expect(t, is_err4)
	testing.expect(t, strings.contains(out4, "no language server is registered for language: nosuchlang"))

	// start: the missing-binary refusal carries the install guidance with
	// the consent instruction (the agent installs, but only after asking).
	out4b, is_err4b := tool_run(t, pair, "langserver_start", `{"language": "crystal"}`, a)
	testing.expect(t, is_err4b)
	testing.expect(t, strings.contains(out4b, "is not installed"))
	testing.expect(t, strings.contains(out4b, "Ask the user for consent before installing"))
	testing.expect(t, strings.contains(out4b, "langserver_start"))
	testing.expect(t, strings.contains(out4b, "config_set"), "the custom-path route must name the config write tool")

	// call hierarchy: the direction enum is enforced at validation.
	out5, is_err5 := tool_run(
		t, pair, "langserver_find_calls",
		`{"relative_path": "a.go", "line": 0, "col": 0, "direction": "sideways"}`, a,
	)
	testing.expect(t, is_err5)
	testing.expect(t, strings.contains(out5, "must be one of the allowed values"))

	// diagnostics: a missing file is the daemon's NotFound with the wire
	// code woven in.
	out6, is_err6 := tool_run(t, pair, "langserver_get_diagnostics", `{"relative_path": "gone/a.go"}`, a)
	testing.expect(t, is_err6)
	testing.expect(t, strings.contains(out6, "path not found"))
	testing.expect(t, strings.contains(out6, "[code -32601]"))
}

@(test)
tools_memory_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Onboarding reads as not performed while no project memory exists.
	ob, ob_err := tool_run(t, pair, "onboarding_check", `{}`, a)
	testing.expect(t, !ob_err)
	testing.expect(t, strings.contains(ob, "Onboarding not performed yet"))

	// The manual's project facts report the missing onboarding, the LS
	// state, and no tracker line while nothing is open.
	m0, m0_err := tool_run(t, pair, "onboarding_read_instructions", `{}`, a)
	testing.expect(t, !m0_err)
	testing.expect(t, strings.contains(m0, "Project facts (this session)"), m0)
	testing.expect(t, strings.contains(m0, "No project memories yet"), m0)
	testing.expect(t, strings.contains(m0, "Language servers:"), m0)
	testing.expect(t, !strings.contains(m0, "Tracker: "), m0)

	// Write answers with the fixed success string.
	w, w_err := tool_run(
		t, pair, "memory_write",
		`{"memory_name": "auth/login", "content": "# login\n"}`, a,
	)
	testing.expect(t, !w_err)
	testing.expect_value(t, w, "Memory auth/login written.")

	// Read roundtrip plus the not-found hint for missing memories.
	r, r_err := tool_run(t, pair, "memory_read", `{"memory_name": "auth/login"}`, a)
	testing.expect(t, !r_err)
	testing.expect_value(t, r, "# login\n")
	miss, miss_err := tool_run(t, pair, "memory_read", `{"memory_name": "absent"}`, a)
	testing.expect(t, !miss_err)
	testing.expect(t, strings.contains(miss, "consider creating it with the `memory_write` tool"))

	// The listing renders the face's JSON (only non-empty buckets).
	l, l_err := tool_run(t, pair, "memory_list", `{}`, a)
	testing.expect(t, !l_err)
	testing.expect(t, strings.contains(l, `"auth/login"`))

	// Rename propagates the mem: reference into other memories.
	_, _ = tool_run(t, pair, "memory_write", `{"memory_name": "reader", "content": "see mem:auth/login here"}`, a)
	rn, rn_err := tool_run(
		t, pair, "memory_rename",
		`{"old_name": "auth/login", "new_name": "auth/session"}`, a,
	)
	testing.expect(t, !rn_err)
	testing.expect_value(t, rn, "Memory renamed from auth/login to auth/session. Updated 1 cross-reference(s) in other memories.")
	after, _ := tool_run(t, pair, "memory_read", `{"memory_name": "reader"}`, a)
	testing.expect_value(t, after, "see mem:auth/session here")

	// Replace refuses ambiguity and succeeds single-shot.
	_, amb_err := tool_run(
		t, pair, "memory_replace",
		`{"memory_name": "reader", "needle": "e", "repl": "E", "mode": "literal"}`, a,
	)
	testing.expect(t, amb_err)
	one, one_err := tool_run(
		t, pair, "memory_replace",
		`{"memory_name": "reader", "needle": "see", "repl": "saw", "mode": "literal"}`, a,
	)
	testing.expect(t, !one_err)
	testing.expect_value(t, one, "Memory reader edited successfully.")

	// Delete then not-found wording.
	d, d_err := tool_run(t, pair, "memory_delete", `{"memory_name": "reader"}`, a)
	testing.expect(t, !d_err)
	testing.expect_value(t, d, "Memory reader deleted.")
	d2, d2_err := tool_run(t, pair, "memory_delete", `{"memory_name": "reader"}`, a)
	testing.expect(t, !d2_err)
	testing.expect_value(t, d2, "Memory reader not found.")

	// Onboarding now reports the project memory count.
	ob2, ob2_err := tool_run(t, pair, "onboarding_check", `{}`, a)
	testing.expect(t, !ob2_err)
	testing.expect(t, strings.contains(ob2, "Onboarding was already performed: 1 project memories"))

	// The manual's project facts now list the surviving memory by name.
	m1, m1_err := tool_run(t, pair, "onboarding_read_instructions", `{}`, a)
	testing.expect(t, !m1_err)
	testing.expect(t, strings.contains(m1, "Project memories (1):"), m1)
	testing.expect(t, strings.contains(m1, "auth/session"), m1)

	// An open incident rides into the facts as the tracker summary line.
	_, inc_err := tool_run(
		t, pair, "incident_create",
		`{"title": "manual probe", "description": "exercises the manual's tracker fact line"}`,
		a,
	)
	testing.expect(t, !inc_err)
	m2, m2_err := tool_run(t, pair, "onboarding_read_instructions", `{}`, a)
	testing.expect(t, !m2_err)
	testing.expect(t, strings.contains(m2, "Tracker: 1 open"), m2)
}

@(test)
tools_tracker_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// "current" refuses before any sprint exists (no side effects).
	_, sp_err := tool_run(
		t, pair, "incident_create",
		`{"title": "x", "description": "y", "sprint": "current"}`, a,
	)
	testing.expect(t, sp_err)

	// Sprint lifecycle: start with a goal and the must list, file into it,
	// verify, defer, close with stats.
	started, st_err := tool_run(
		t, pair, "sprint_start",
		`{"name": "auth round", "goal": "Fix the cookie lifetime problems.", "must": ["T1", "T2"]}`, a,
	)
	testing.expect(t, !st_err)
	testing.expect_value(t, started, "Started SPR-001 \"auth round\" (goal: Fix the cookie lifetime problems.), must: 2 tasks")

	// The first finding is filed to the BACKLOG but INSIDE the sprint
	// window — the statistics count the filing window, so it is in the
	// cohort whatever its membership later is.
	created, cerr := tool_run(
		t, pair, "incident_create",
		`{"title": "login drops the session cookie", "description": "src/auth/login.go:42 drops the cookie when the redirect fires.", "priority": "high", "labels": ["auth", "bug"], "created_by": "tester"}`,
		a,
	)
	testing.expect(t, !cerr)
	testing.expect_value(t, created, "Created INC-001 [high] \"login drops the session cookie\" (reported, backlog)")

	created2, c2err := tool_run(
		t, pair, "incident_create",
		`{"title": "second finding", "description": "another body with detail", "sprint": "current"}`, a,
	)
	testing.expect(t, !c2err)
	testing.expect_value(t, created2, "Created INC-002 [medium] \"second finding\" (reported, SPR-001)")

	// Detail and list renders flow through as text.
	got, g_err := tool_run(t, pair, "incident_get", `{"id": "INC-001"}`, a)
	testing.expect(t, !g_err)
	testing.expect(t, strings.contains(got, "login drops the session cookie"))
	listed, l_err := tool_run(t, pair, "incident_list", `{"status": ["open"]}`, a)
	testing.expect(t, !l_err)
	testing.expect(t, strings.contains(listed, "INC-001"))
	testing.expect(t, strings.contains(listed, "INC-002"))

	// Verify, then the composite update ack with the status transition.
	verified, v_err := tool_run(
		t, pair, "incident_verify",
		`{"id": "INC-001", "verdict": "confirmed", "reason": "the drop is real", "evidence": "src/auth/login.go:42: cookie.Reset()"}`,
		a,
	)
	testing.expect(t, !v_err)
	testing.expect_value(t, verified, "Verified INC-001: confirmed — the drop is real")

	// Move the incident into the sprint (membership is work grouping —
	// the close stats already count it through its in-window
	// filing), then record the root cause — the
	// root_cause field moves the status itself; a direct
	// confirmed→root_caused status change is illegal.
	moved, mv_err := tool_run(
		t, pair, "incident_update",
		`{"id": "INC-001", "sprint": "current"}`,
		a,
	)
	testing.expect(t, !mv_err)
	testing.expect_value(t, moved, "Updated INC-001 (sprint)")

	updated, u_err := tool_run(
		t, pair, "incident_update",
		`{"id": "INC-001", "root_cause": "the redirect clears the cookie jar", "note": "found it", "assignee": "agent"}`,
		a,
	)
	testing.expect(t, !u_err)
	testing.expect_value(t, updated, "Updated INC-001 (root cause recorded; assignee; note appended)")

	// Resolved is refused on the generic path; the old execution-state
	// walk is gone — resolve lands straight from root_caused.
	_, r_err := tool_run(t, pair, "incident_update", `{"id": "INC-001", "status": "resolved"}`, a)
	testing.expect(t, r_err)
	_, f_err := tool_run(t, pair, "incident_update", `{"id": "INC-001", "status": "fixing"}`, a)
	testing.expect(t, f_err) // the vocabulary left with the rewrite
	resolved, res_err := tool_run(
		t, pair, "incident_resolve",
		`{"id": "INC-001", "resolution": "fixed", "evidence": "commit deadbee + suite green"}`, a,
	)
	testing.expect(t, !res_err)
	testing.expect_value(t, resolved, "Resolved INC-001 as fixed: commit deadbee + suite green")

	// Delete tombstones with the duplicate link wording.
	deleted, d_err := tool_run(
		t, pair, "incident_delete",
		`{"id": "INC-002", "reason": "duplicate of the real finding", "duplicate_of": "INC-001"}`, a,
	)
	testing.expect(t, !d_err)
	testing.expect_value(t, deleted, "Deleted INC-002 (duplicate → INC-001) — hidden from lists and stats, history kept")

	// Round work state: T1 verifies (output required — the refusal proves
	// the gate), T2 stays unverified so close refuses until a typed defer
	// covers it.
	_, no_out := tool_run(
		t, pair, "sprint_record_verification",
		`{"task": "T1", "definition": "just test", "outcome": "passed"}`, a,
	)
	testing.expect(t, no_out)
	rec, rec_err := tool_run(
		t, pair, "sprint_record_verification",
		`{"task": "T1", "definition": "just test", "outcome": "passed", "output": "603 tests green, 0 leak lines", "session": "sess-1"}`, a,
	)
	testing.expect(t, !rec_err)
	testing.expect_value(t, rec, "Recorded SPR-001 verification for T1: passed (just test)")

	_, cl_refuse := tool_run(t, pair, "sprint_close", `{"outcome": "early"}`, a)
	testing.expect(t, cl_refuse) // T2 uncovered

	defer_note, dn_err := tool_run(
		t, pair, "sprint_update",
		`{"id": "current", "note": "ship without the second hardening pass?", "defer_type": "question", "task": "T2"}`, a,
	)
	testing.expect(t, !dn_err)
	testing.expect_value(t, defer_note, "Updated SPR-001 (defer DEF-001 (question))")

	// Close reports the filed cohort's outcomes plus the round's work
	// state; export refreshes the stored report row. The second finding is
	// deleted, so the cohort is the first alone: confirmed and resolved.
	closed, cl_err := tool_run(t, pair, "sprint_close", `{"outcome": "one fixed, one duplicate"}`, a)
	testing.expect(t, !cl_err)
	testing.expect_value(t, closed, "Closed SPR-001 \"auth round\": filed 1 — confirmed 1, resolved 1\nmust: 1/2 verified\ndefers: 1 filed (1 open questions)")

	exported, e_err := tool_run(t, pair, "tracker_export", `{}`, a)
	testing.expect(t, !e_err)
	testing.expect_value(t, exported, "Exported 1 sprint reports to the tracker store")

	// The export path must not add anything to the project tree: reports
	// live as sprint_reports rows in the store, not per-sprint files.
	sprints_dir, _ := filepath.join([]string{pair.tmp, ".aubade", "tracker", "sprints"}, context.temp_allocator)
	testing.expect(t, !os.exists(sprints_dir), "tracker export must not create a sprints directory")

	db_path, _ := filepath.join([]string{pair.tmp, ".aubade", "aubade.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	db, derr := store.db_open(db_path, context.allocator)
	if derr != nil {
		testing.expectf(t, false, "open store: %v", derr)
		return
	}
	defer store.db_close(db)
	report, rfound, gerr := store.sprint_report_get(db, "SPR-001", context.allocator)
	defer delete(report, context.allocator)
	testing.expectf(t, gerr == nil && rfound, "stored report row: found=%v err=%v", rfound, gerr)
	if rfound {
		testing.expect(t, strings.contains(report, "login drops the session cookie"))
		// One population: both section headers name the same set — findings
		// filed during the sprint window — and the ack's "filed 1" count
		// matches this list (the deleted finding is excluded).
		testing.expect(t, strings.contains(report, "## Statistics — findings filed during the sprint window"))
		testing.expect(t, strings.contains(report, "## Findings filed during the sprint window (the population of the statistics above)"))
		// The round's work state rides along: the must-task block with the
		// verification evidence and the typed-defer roll-up.
		testing.expect(t, strings.contains(report, "must tasks:"))
		testing.expect(t, strings.contains(report, "- T1: passed (just test,"))
		testing.expect(t, strings.contains(report, "603 tests green, 0 leak lines"))
		testing.expect(t, strings.contains(report, "defers:\n- DEF-001 question (task T2): ship without the second hardening pass?"))
	}
}

@(test)
tools_config_get_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	out, is_err := tool_run(t, pair, "config_get", "{}", a)
	testing.expect(t, !is_err)
	testing.expect(t, strings.contains(out, "Aubade version: "), "version line missing")
	testing.expect(t, strings.contains(out, "Active project: "), "project line missing")
	testing.expect(t, strings.contains(out, "Active context: (none)"), "context line missing")
	testing.expect(t, strings.contains(out, "Active modes: (none)"), "modes line missing")
	testing.expect(t, strings.contains(out, "Active tools (after all exclusions from the project, context, and modes):"), "active tools header missing")
	// The pair harness folds with every family capability: config_get and
	// the tracker family must sit in the active groups.
	testing.expect(t, strings.contains(out, "config: config_get"), "config_get must be active")
	testing.expect(t, strings.contains(out, "tracker: incident_create"), "incident_create must be active")
	// The web family needs a capability the harness withholds.
	testing.expect(t, strings.contains(out, "Available but not active tools:"), "inactive tools header missing")

	// The schema reference rides only behind include_schema — the default
	// answer stays lean.
	testing.expect(t, !strings.contains(out, "Project configuration reference"), "default must omit the schema")

	schema, s_err := tool_run(t, pair, "config_get", `{"include_schema": true}`, a)
	testing.expect(t, !s_err, "include_schema run must succeed")
	testing.expect(t, strings.contains(schema, "Project configuration reference"), "schema header missing")
	testing.expect(t, strings.contains(schema, "\"language_server_options\": {},"), "schema must document language_server_options")
	testing.expect(t, strings.contains(schema, "\"language_server_commands\": {},"), "schema must document language_server_commands")
	testing.expect(t, strings.contains(schema, "project.local.jsonc"), "schema must name the local override file")
}

@(test)
tools_shadow_family_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Snapshot an empty workspace, then a workspace with one file: the
	// second hash differs, log lists both newest-first, and the diff and
	// patch name the file. Revert_file then removes the file (it did not
	// exist at the first snapshot) and restore confirms.
	out, is_err := tool_run(t, pair, "shadow_snapshot", "{\"message\": \"first\"}", a)
	testing.expect(t, !is_err, out)
	prefix := "Snapshot created: "
	if !strings.has_prefix(out, prefix) {
		testing.expectf(t, false, "snapshot output missing prefix: %s", out)
		return
	}
	h1 := out[len(prefix):]

	seed := strings.concatenate({pair.tmp, "/a.txt"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(seed, "hello\n"); werr != nil {
		testing.expectf(t, false, "seed failed")
		return
	}

	out2, is_err2 := tool_run(t, pair, "shadow_snapshot", "{\"message\": \"second\"}", a)
	testing.expect(t, !is_err2, out2)
	h2 := out2[len(prefix):]
	testing.expect(t, h2 != h1, "changed workspace makes a new snapshot")

	// An unchanged workspace returns HEAD as-is.
	out2b, is_err2b := tool_run(t, pair, "shadow_snapshot", "{}", a)
	testing.expect(t, !is_err2b, out2b)
	testing.expect(t, out2b[len(prefix):] == h2, "unchanged snapshot returns HEAD")

	log_out, log_err := tool_run(t, pair, "shadow_log", "{\"count\": 5}", a)
	testing.expect(t, !log_err, log_out)
	testing.expect(t, strings.contains(log_out, h1) && strings.contains(log_out, h2), log_out)
	testing.expect(t, strings.index(log_out, h2) < strings.index(log_out, h1), "newest first")

	diff_out, diff_err := tool_run(t, pair, "shadow_diff", strings.concatenate({"{\"from\": \"", h1, "\", \"to\": \"", h2, "\"}"}, a), a)
	testing.expect(t, !diff_err, diff_out)
	testing.expect(t, strings.contains(diff_out, "a.txt"), diff_out)

	patch_out, patch_err := tool_run(t, pair, "shadow_patch", strings.concatenate({"{\"from\": \"", h1, "\", \"to\": \"", h2, "\"}"}, a), a)
	testing.expect(t, !patch_err, patch_out)
	testing.expect(t, strings.contains(patch_out, "a.txt"), patch_out)

	revert_out, revert_err := tool_run(t, pair, "shadow_revert_file", strings.concatenate({"{\"hash\": \"", h1, "\", \"file_path\": \"a.txt\"}"}, a), a)
	testing.expect(t, !revert_err, revert_out)
	testing.expect(t, revert_out == strings.concatenate({"File a.txt reverted to snapshot ", h1}, a), revert_out)
	if _, rerr := os.read_entire_file_from_path(seed, context.temp_allocator); rerr == nil {
		testing.expectf(t, false, "a.txt should be gone after revert to a snapshot without it")
		return
	}

	restore_out, restore_err := tool_run(t, pair, "shadow_restore", strings.concatenate({"{\"hash\": \"", h2, "\"}"}, a), a)
	testing.expect(t, !restore_err, restore_out)
	testing.expect(t, restore_out == strings.concatenate({"Workspace restored to snapshot ", h2}, a), restore_out)
	back, _ := os.read_entire_file_from_path(seed, context.temp_allocator)
	testing.expect(t, string(back) == "hello\n", "restore brought the content back")

	// A malformed hash is refused with the fixed wording.
	bad_out, bad_err := tool_run(t, pair, "shadow_diff", "{\"from\": \"../../etc\", \"to\": \"abc1234\"}", a)
	testing.expect(t, bad_err, bad_out)
	testing.expect(t, strings.contains(bad_out, "invalid git hash"), bad_out)
}

@(test)
tools_config_write_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	cfg_path := strings.concatenate({pair.tmp, "/.aubade/project.jsonc"}, context.temp_allocator)

	// A member-scoped upsert creates the file, validates, and applies live.
	out, is_err := tool_run(
		t, pair, "config_set",
		`{"key": "language_server_options", "member": "odin", "value": "{\"collections\": []}"}`,
		a,
	)
	testing.expect(t, !is_err, out)
	testing.expect(t, strings.contains(out, "language_server_options.odin"), out)
	testing.expect(t, strings.contains(out, "inserted"), out)
	testing.expect(t, strings.contains(out, "applied live"), out)
	data, derr := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect(t, derr == nil, "the write must create the file")
	if derr == nil {
		testing.expect(t, strings.contains(string(data), "\"odin\": {\"collections\": []}"), string(data))
	}

	// The same value again: unchanged, no apply noise.
	out2, is_err2 := tool_run(
		t, pair, "config_set",
		`{"key": "language_server_options", "member": "odin", "value": "{\"collections\": []}"}`,
		a,
	)
	testing.expect(t, !is_err2, out2)
	testing.expect(t, strings.contains(out2, "unchanged"), out2)

	before, _ := os.read_entire_file_from_path(cfg_path, context.temp_allocator)

	// Unknown keys are refused with the file untouched.
	out3, is_err3 := tool_run(t, pair, "config_set", `{"key": "nonsense_key", "value": "1"}`, a)
	testing.expect(t, is_err3)
	testing.expect(t, strings.contains(out3, "unknown project configuration key"), out3)
	after3, _ := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect_value(t, string(after3), string(before))

	// A value the loader would reject is refused with the file untouched.
	out4, is_err4 := tool_run(t, pair, "config_set", `{"key": "language_servers", "value": "\"odin\""}`, a)
	testing.expect(t, is_err4)
	testing.expect(t, strings.contains(out4, "would not load"), out4)
	after4, _ := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect_value(t, string(after4), string(before))

	// member is only valid for the map-valued keys.
	out5, is_err5 := tool_run(
		t, pair, "config_set",
		`{"key": "read_only", "member": "odin", "value": "true"}`,
		a,
	)
	testing.expect(t, is_err5)
	testing.expect(t, strings.contains(out5, "member is only valid"), out5)

	// A local override is surfaced: project.local.jsonc replaces the key
	// whole, so the answer must say the write is shadowed.
	local_path := strings.concatenate({pair.tmp, "/.aubade/project.local.jsonc"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(local_path, "{\"language_servers\": [{\"name\": \"odin\"}]}"); werr != nil {
		testing.expectf(t, false, "local fixture failed")
		return
	}
	out6, is_err6 := tool_run(t, pair, "config_set", `{"key": "language_servers", "value": "[{\"name\": \"odin\"}, {\"name\": \"go\"}]"}`, a)
	testing.expect(t, !is_err6, out6)
	testing.expect(t, strings.contains(out6, "inserted"), out6)
	testing.expect(t, strings.contains(out6, "project.local.jsonc also sets this key"), out6)

	// Member removal takes the entry out and leaves the file loadable;
	// removing it again is an absent no-op.
	out7, is_err7 := tool_run(t, pair, "config_delete", `{"key": "language_server_options", "member": "odin"}`, a)
	testing.expect(t, !is_err7, out7)
	testing.expect(t, strings.contains(out7, "removed"), out7)
	data7, _ := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data7), "collections"), string(data7))
	testing.expect(t, config.validate_project_data(data7, context.temp_allocator) == nil, "the file must still load")

	out8, is_err8 := tool_run(t, pair, "config_delete", `{"key": "language_server_options", "member": "odin"}`, a)
	testing.expect(t, !is_err8, out8)
	testing.expect(t, strings.contains(out8, "absent"), out8)

	// A next-session-only key says so instead of claiming a live apply.
	out9, is_err9 := tool_run(t, pair, "config_set", `{"key": "read_only", "value": "true"}`, a)
	testing.expect(t, !is_err9, out9)
	testing.expect(t, strings.contains(out9, "takes effect at the next session"), out9)
}

@(test)
tools_config_write_language_server_paths :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	cfg_path := strings.concatenate({pair.tmp, "/.aubade/project.jsonc"}, context.temp_allocator)

	// The {name, path} entry form validates and lands in the file.
	out, is_err := tool_run(
		t, pair, "config_set",
		`{"key": "language_servers", "value": "[{\"name\": \"odin\", \"path\": \"/abs/ols\"}, {\"name\": \"go\"}]"}`,
		a,
	)
	testing.expect(t, !is_err, out)
	testing.expect(t, strings.contains(out, "applied live"), out)
	data, derr := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect(t, derr == nil, "the write must create the file")
	if derr == nil {
		testing.expect(t, strings.contains(string(data), "/abs/ols"), string(data))
		testing.expect(t, config.validate_project_data(data, context.temp_allocator) == nil, "the file must still load")
	}

	// A malformed entry (unknown field) is refused with the file untouched.
	before, _ := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	out2, is_err2 := tool_run(
		t, pair, "config_set",
		`{"key": "language_servers", "value": "[{\"name\": \"odin\", \"where\": \"/abs/ols\"}]"}`,
		a,
	)
	testing.expect(t, is_err2)
	testing.expect(t, strings.contains(out2, "would not load"), out2)
	after2, _ := os.read_entire_file_from_path(cfg_path, context.temp_allocator)
	testing.expect_value(t, string(after2), string(before))
}

@(test)
tools_file_read_outline_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	svc_symbol_write_file(t, pair.tmp, "app.json", "{\"name\":\"demo\",\"ver\":2}\n")

	// Outline mode: the key tree replaces a grep probe.
	out, is_err := tool_run(t, pair, "file_read_outline", `{"relative_path": "app.json"}`, a)
	testing.expect(t, !is_err, out)
	testing.expectf(t, strings.contains(out, "name: \"demo\" (L0)"), out)
	testing.expectf(t, strings.contains(out, "ver: 2 (L0)"), out)

	// Extraction mode leads with the reached line range.
	out, is_err = tool_run(t, pair, "file_read_outline", `{"relative_path": "app.json", "path": ".ver"}`, a)
	testing.expect(t, !is_err, out)
	testing.expectf(t, strings.has_prefix(out, "(L0-L0)"), out)
	testing.expectf(t, strings.contains(out, "2"), out)

	// A miss surfaces the available keys — one retry self-corrects.
	out, is_err = tool_run(t, pair, "file_read_outline", `{"relative_path": "app.json", "path": ".nope"}`, a)
	testing.expect(t, is_err)
	testing.expectf(t, strings.contains(out, "available: name, ver"), out)
}

@(test)
tools_file_search_pages_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	svc_symbol_write_file(t, pair.tmp, "b.txt", "MATCH b\n")
	svc_symbol_write_file(t, pair.tmp, "a.txt", "MATCH a1\nMATCH a2\n")

	// A capped page names the next offset.
	page1, err1 := tool_run(t, pair, "file_search", `{"substring_pattern": "MATCH", "limit": 1}`, a)
	testing.expect(t, !err1, page1)
	testing.expectf(t, strings.contains(page1, "[showing matches 1-1 of 3 — pass offset=1 for the next page]"), page1)

	// The final page carries no resume line.
	rest, err2 := tool_run(t, pair, "file_search", `{"substring_pattern": "MATCH", "offset": 1}`, a)
	testing.expect(t, !err2, rest)
	testing.expectf(t, !strings.contains(rest, "pass offset="), rest)

	// Past the end says so instead of answering an empty object.
	past, _ := tool_run(t, pair, "file_search", `{"substring_pattern": "MATCH", "offset": 5}`, a)
	testing.expectf(t, strings.contains(past, "[no matches at or past offset 5 (total 3)]"), past)

	// Negative values fail before any walk runs.
	_, neg := tool_run(t, pair, "file_search", `{"substring_pattern": "MATCH", "offset": -1}`, a)
	testing.expect(t, neg)
}

@(test)
tools_symbol_find_pages_apply :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Two same-name symbols whose file names disagree with write order:
	// the page order is (path, line), not discovery order.
	svc_symbol_write_file(t, pair.tmp, "b_second.go", "package main\n\nfunc Paged() {}\n")
	svc_symbol_write_file(t, pair.tmp, "a_first.go", "package main\n\nfunc Paged() {}\n")

	// symbol_list fills the index as a side effect, so find is deterministic.
	_, lerr1 := tool_run(t, pair, "symbol_list", `{"relative_path": "a_first.go"}`, a)
	testing.expect(t, !lerr1)
	_, lerr2 := tool_run(t, pair, "symbol_list", `{"relative_path": "b_second.go"}`, a)
	testing.expect(t, !lerr2)

	page1, err1 := tool_run(t, pair, "symbol_find", `{"name_path_pattern": "Paged", "limit": 1}`, a)
	testing.expect(t, !err1, page1)
	testing.expectf(t, strings.contains(page1, "a_first.go"), page1)
	testing.expectf(t, strings.contains(page1, "[showing symbols 1-1 of 2 — pass offset=1 for the next page]"), page1)

	rest, err2 := tool_run(t, pair, "symbol_find", `{"name_path_pattern": "Paged", "offset": 1}`, a)
	testing.expect(t, !err2, rest)
	testing.expectf(t, strings.contains(rest, "b_second.go"), rest)
	testing.expectf(t, !strings.contains(rest, "pass offset="), rest)

	// Negative values fail validation before the index is read.
	_, neg := tool_run(t, pair, "symbol_find", `{"name_path_pattern": "Paged", "limit": -3}`, a)
	testing.expect(t, neg)
}

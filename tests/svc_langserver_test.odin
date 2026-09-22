// Contract tests for the svc.langserver/* lifecycle face over the
// channel transport. The daemon pair runs the production registry and
// manager; the languages exercised (crystal/elm/zig) have no binaries
// on the test machine, so every path here is a deterministic refusal —
// no real language server is ever spawned. These tests never call
// testing.fail_now: it aborts without running defers, and a live daemon
// pair left behind wedges the runner (expectf + early return keeps
// pair_shutdown on the defer stack).
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:svc"
import "src:symbol"

// json_int_of is json_int_field without the found flag (renderer
// assertions always expect the key).
json_int_of :: proc(v: json.Value, key: string) -> i64 {
	n, _ := json_int_field(v, key)
	return n
}

@(test)
svc_langserver_lifecycle_contract :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// language is required on the wire.
	nolang := svc.client_langserver_start(pair.conn, "", alloc, deadline)
	testing.expect_value(t, nolang.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, nolang.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(nolang.err_message, "language is required"))

	// An unregistered language names the language in the refusal.
	unknown := svc.client_langserver_start(pair.conn, "nosuchlang", alloc, deadline)
	testing.expect_value(t, unknown.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, unknown.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(unknown.err_message, "no language server is registered for language: nosuchlang"))

	// A registered language whose server binary is missing fails the
	// runtime check with the install hint.
	missing := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(missing.err_message, "is not installed"))

	// Stopping a language that was never started is a NotFound that
	// names the language.
	stop := svc.client_langserver_stop(pair.conn, "elm", alloc, deadline)
	testing.expect_value(t, stop.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, stop.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(stop.err_message, "no running language server for language: elm"))

	// Restart with an unknown language refuses before the manager.
	rbad := svc.client_langserver_restart(pair.conn, "nosuchlang", alloc, deadline)
	testing.expect_value(t, rbad.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, rbad.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(rbad.err_message, "no language server is registered for language: nosuchlang"))

	// Restart with a missing-binary language surfaces the install hint
	// (a distinct language: the failed start above put crystal on its
	// 30s cooldown, and zig has not been tried yet).
	rmiss := svc.client_langserver_restart(pair.conn, "zig", alloc, deadline)
	testing.expect_value(t, rmiss.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, rmiss.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(rmiss.err_message, "is not installed"))

	// The argumentless restart cold-resets the manager: with nothing
	// running it succeeds.
	rot := svc.client_langserver_restart(pair.conn, "", alloc, deadline)
	testing.expect_value(t, rot.call_err, jsonrpc.Call_Err.None)

	// The cold reset must not latch the manager's shutdown flag: a start
	// afterwards still reaches the registry runtime check (NotFound with
	// the install hint — elm was never started, so no cooldown applies).
	post := svc.client_langserver_start(pair.conn, "elm", alloc, deadline)
	testing.expect_value(t, post.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, post.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(post.err_message, "is not installed"))

// An unconfigured project lists nothing and answers the
// configuration hint instead of the whole registry.
	list := svc.client_langserver_list(pair.conn, alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.None)
	hint, hok := json_str_field(list.result, "message")
	testing.expectf(t, hok, "list message missing")
	testing.expect(t, strings.contains(hint, "langserver_start"))
	_, items_present := jsonutil.obj_get(list.result, "items")
	testing.expect_value(t, items_present, false)
}

@(test)
svc_langserver_start_uses_configured_command :: proc(t: ^testing.T) {
	pair := test_daemon_with_project(
		t,
		false,
		`{"language_server_commands": {"crystal": ["/no/such/crystalline-fp"]}}`,
	)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// The configured command wins over the built-in probe: the refusal
	// names the configured path, not the registry's install hint.
	res := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, res.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, res.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(res.err_message, "configured language server command"))
	testing.expect(t, strings.contains(res.err_message, "/no/such/crystalline-fp"))
}

@(test)
svc_langserver_reload_applies_live_settings :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// The pair starts with no project config: list answers the hint.
	before := svc.client_langserver_list(pair.conn, alloc, deadline)
	_, had_items := jsonutil.obj_get(before.result, "items")
	testing.expect_value(t, had_items, false)

	// Arm crystal's failure cooldown under the (empty) old settings.
	arm := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, arm.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect(t, strings.contains(arm.err_message, "is not installed"))

	// A config written after the daemon started reaches the LIVE manager
	// through reload: the allowlist swap shows in list, the command
	// override swap in the next start refusal.
	write_config_file(
		t,
		platform.project_config_path(
			strings.concatenate({pair.tmp, "/.aubade"}, context.temp_allocator),
			context.temp_allocator,
		),
		`{
	"language_servers": [{"name": "crystal"}, {"name": "elm"}],
	"language_server_commands": {"crystal": ["/no/such/crystalline-rld"], "elm": ["/no/such/elm-rld"]}
}`,
	)
	rl := svc.client_langserver_reload(pair.conn, alloc, deadline)
	testing.expect_value(t, rl.call_err, jsonrpc.Call_Err.None)
	if rl.call_err == .None {
		testing.expect_value(t, json_int_of(rl.result, "overrides"), 2)
		testing.expect_value(t, json_int_of(rl.result, "stopped"), 0)
	}

	after := svc.client_langserver_list(pair.conn, alloc, deadline)
	items, has_items := jsonutil.obj_get(after.result, "items")
	testing.expectf(t, has_items, "list must show the reloaded allowlist")
	if has_items {
		arr, is_arr := jsonutil.as_array(items)
		testing.expectf(t, is_arr, "list items must be an array")
		testing.expect_value(t, len(arr), 2)
		if is_arr && len(arr) == 2 {
			first_lang, ok := json_str_field(arr[0], "language")
			testing.expectf(t, ok, "first item language missing")
			testing.expect(t, first_lang == "crystal" || first_lang == "elm")
		}
	}

	res := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, res.call_err, jsonrpc.Call_Err.Error_Response)
	// Method_Not_Found (not Retryable) doubles as proof that the reload's
	// cold reset cleared the cooldown the armed start above left behind.
	testing.expect_value(t, res.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(res.err_message, "/no/such/crystalline-rld"))

	// A corrupt config refuses the reload without touching anything: the
	// previous overrides still answer (elm has no cooldown yet).
	write_config_file(
		t,
		platform.project_config_path(
			strings.concatenate({pair.tmp, "/.aubade"}, context.temp_allocator),
			context.temp_allocator,
		),
		`{"language_servers": [`,
	)
	bad := svc.client_langserver_reload(pair.conn, alloc, deadline)
	testing.expect_value(t, bad.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(bad.err_message, "were not applied"))

	survivor := svc.client_langserver_start(pair.conn, "elm", alloc, deadline)
	testing.expect_value(t, survivor.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect(t, strings.contains(survivor.err_message, "/no/such/elm-rld"))
}

@(test)
read_only_daemon_refuses_langserver_lifecycle :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)
	pair.daemon.cfg.read_only = true

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Lifecycle control mutates daemon-shared processes: refused at the
	// boundary in read-only sessions.
	s := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, s.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, s.err_code, jsonrpc.Err_Code.Invalid_Request)

	p := svc.client_langserver_stop(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, p.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, p.err_code, jsonrpc.Err_Code.Invalid_Request)

	r := svc.client_langserver_restart(pair.conn, "", alloc, deadline)
	testing.expect_value(t, r.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, r.err_code, jsonrpc.Err_Code.Invalid_Request)

	rl := svc.client_langserver_reload(pair.conn, alloc, deadline)
	testing.expect_value(t, rl.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, rl.err_code, jsonrpc.Err_Code.Invalid_Request)

	// The status list still serves the read-only project.
	list := svc.client_langserver_list(pair.conn, alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.None)
	hint, hok := json_str_field(list.result, "message")
	testing.expectf(t, hok, "list message missing under read-only")
	testing.expect(t, strings.contains(hint, "langserver_start"))
}

@(test)
svc_langserver_request_contract :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// relative_path is required on the wire.
	d := svc.client_langserver_diagnostics(pair.conn, "", alloc, deadline)
	testing.expect_value(t, d.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, d.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(d.err_message, "relative_path is required"))

	// A missing file is a NotFound that names the path.
	d2 := svc.client_langserver_diagnostics(pair.conn, "gone/x.go", alloc, deadline)
	testing.expect_value(t, d2.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, d2.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(d2.err_message, "path not found"))

	// A file whose language server is uninstalled surfaces the install
	// hint through the on-demand start.
	svc_symbol_write_file(t, pair.tmp, "x.cr", "x = 1\n")
	d3 := svc.client_langserver_diagnostics(pair.conn, "x.cr", alloc, deadline)
	testing.expect_value(t, d3.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, d3.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(d3.err_message, "is not installed"))

	// Param validation precedes server resolution: a bad direction is
	// refused without touching the (uninstalled) server.
	ch := svc.client_langserver_call_hierarchy(pair.conn, "x.cr", 1, 1, "sideways", alloc, deadline)
	testing.expect_value(t, ch.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, ch.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(ch.err_message, "invalid direction"))

	// Missing range coordinates are likewise a caller error.
	params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&params, "relative_path", jsonutil.json_string("x.cr"))
	_, ecode, emsg, ecerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_LANGSERVER_CODE_ACTIONS, json.Value(json.Object(params)), alloc, deadline,
	)
	testing.expect_value(t, ecerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, ecode, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(emsg, "start_line, start_col, end_line, and end_col are required"))
}

@(test)
svc_langserver_result_renderers :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Diagnostics: severity by name, flattened positions, optional
	// source/code, and unknown severities render empty.
	raw, _ := json.parse_string(
		`[{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":9}},"severity":2,"message":"unused variable x","source":"testls","code":"W0913"},{"range":{"start":{"line":5,"character":0},"end":{"line":5,"character":3}},"severity":7,"message":"weird"}]`,
		spec = .JSON, parse_integers = true, allocator = a,
	)
	diag := svc.langserver_diagnostics_json(raw, a)
	darr, dok := jsonutil.as_array(diag)
	testing.expectf(t, dok && len(darr) == 2, "diagnostics array: ok=%v len=%d", dok, len(darr))
	if dok && len(darr) == 2 {
		first := darr[0]
		sev, _ := json_str_field(first, "severity")
		msg, _ := json_str_field(first, "message")
		src, _ := json_str_field(first, "source")
		testing.expect_value(t, sev, "warning")
		testing.expect_value(t, msg, "unused variable x")
		testing.expect_value(t, src, "testls")
		testing.expect_value(t, json_int_of(first, "start_line"), 2)
		testing.expect_value(t, json_int_of(first, "start_col"), 4)
		testing.expect_value(t, json_int_of(first, "end_line"), 2)
		testing.expect_value(t, json_int_of(first, "end_col"), 9)
		sev2, _ := json_str_field(darr[1], "severity")
		testing.expect_value(t, sev2, "")
	}
	// A non-array input renders as an empty array.
	empty := svc.langserver_diagnostics_json({}, a)
	earr, eok := jsonutil.as_array(empty)
	testing.expectf(t, eok && len(earr) == 0, "empty diagnostics: ok=%v len=%d", eok, len(earr))

	// Text edits: new_text plus the flattened range.
	edits := []lsp.Text_Edit{{
		range      = {start = {line = 1, character = 0}, end = {line = 1, character = 5}},
		new_text = "hello",
	}}
	ej := svc.langserver_text_edits_json(edits, a)
	earr2, eok2 := jsonutil.as_array(ej)
	testing.expectf(t, eok2 && len(earr2) == 1, "edits array: ok=%v len=%d", eok2, len(earr2))
	if eok2 && len(earr2) == 1 {
		txt, _ := json_str_field(earr2[0], "new_text")
		testing.expect_value(t, txt, "hello")
		testing.expect_value(t, json_int_of(earr2[0], "start_line"), 1)
		testing.expect_value(t, json_int_of(earr2[0], "end_col"), 5)
	}

	// Inlay hints: position flattened to line/column.
	hints := []lsp.Inlay_Hint{{pos = {line = 3, character = 2}, label = "x int", tooltip = "type"}}
	hj := svc.langserver_inlay_hints_json(hints, a)
	harr, hok := jsonutil.as_array(hj)
	testing.expectf(t, hok && len(harr) == 1, "hints array: ok=%v len=%d", hok, len(harr))
	if hok && len(harr) == 1 {
		label, _ := json_str_field(harr[0], "label")
		testing.expect_value(t, label, "x int")
		if pos_v, pok := jsonutil.obj_get(harr[0], "position"); pok {
			testing.expect_value(t, json_int_of(pos_v, "line"), 3)
			testing.expect_value(t, json_int_of(pos_v, "column"), 2)
		} else {
			testing.expectf(t, false, "hint position missing")
		}
	}

	// Call edges: endpoint naming, kind by name, and call-site ranges.
	// A second edge whose endpoint resolved outside the project root
	// (empty rel_path) must be dropped from the rendered array.
	item := lsp.Call_Item{
		name = "g",
		kind = .Function,
		rel_path = "caller.go",
		range = {start = {line = 6, character = 1}, end = {line = 6, character = 4}},
		selection_range = {start = {line = 6, character = 1}, end = {line = 6, character = 2}},
	}
	outside := lsp.Call_Item{
		name = "Abs",
		kind = .Function,
		range = {start = {line = 2, character = 0}, end = {line = 2, character = 3}},
		selection_range = {start = {line = 2, character = 0}, end = {line = 2, character = 1}},
	}
	frs := []symbol.Range{{start = {line = 8, character = 0}, end = {line = 8, character = 3}}}
	edges := []lsp.Call_Edge{{item = item, from_ranges = frs}, {item = outside}}
	cj := svc.langserver_call_edges_json(edges, a)
	carr, cok := jsonutil.as_array(cj)
	testing.expectf(t, cok && len(carr) == 1, "edges array: ok=%v len=%d", cok, len(carr))
	if cok && len(carr) == 1 {
		name, _ := json_str_field(carr[0], "name")
		kind, _ := json_str_field(carr[0], "kind")
		rel, _ := json_str_field(carr[0], "relative_path")
		testing.expect_value(t, name, "g")
		testing.expect_value(t, kind, "Function")
		testing.expect_value(t, rel, "caller.go")
		testing.expect_value(t, json_int_of(carr[0], "line"), 6)
		testing.expect_value(t, json_int_of(carr[0], "selection_col"), 1)
		if fr_v, fok := jsonutil.obj_get(carr[0], "from_ranges"); fok {
			fr_arr, fr_ok := jsonutil.as_array(fr_v)
			testing.expectf(t, fr_ok && len(fr_arr) == 1, "from_ranges: ok=%v len=%d", fr_ok, len(fr_arr))
			if fr_ok && len(fr_arr) == 1 {
				testing.expect_value(t, json_int_of(fr_arr[0], "start_line"), 8)
			}
		} else {
			testing.expectf(t, false, "from_ranges missing")
		}
	}
}

@(test)
svc_langserver_entry_path_overrides :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// An entry's path pins the binary's OS location: absolute is used
	// verbatim, relative anchors at the project root, a path-less entry
	// keeps normal resolution, and a full argv in language_server_commands
	// wins for the same language.
	when ODIN_OS == .Windows {
		write_config_file(
			t,
			platform.project_config_path(
				strings.concatenate({pair.tmp, "/.aubade"}, context.temp_allocator),
				context.temp_allocator,
			),
			`{
	"language_servers": [
		{"name": "crystal", "path": "C:\\no\\such\\crystalline-abs"},
		{"name": "elm", "path": "nested/elm-rel"},
		{"name": "zig"},
		{"name": "python", "path": "C:\\no\\such\\python-loses"}
	],
	"language_server_commands": {"python": ["C:\\no\\such\\python-wins"]}
}`,
		)
	} else {
		write_config_file(
			t,
			platform.project_config_path(
				strings.concatenate({pair.tmp, "/.aubade"}, context.temp_allocator),
				context.temp_allocator,
			),
			`{
	"language_servers": [
		{"name": "crystal", "path": "/no/such/crystalline-abs"},
		{"name": "elm", "path": "nested/elm-rel"},
		{"name": "zig"},
		{"name": "python", "path": "/no/such/python-loses"}
	],
	"language_server_commands": {"python": ["/no/such/python-wins"]}
}`,
		)
	}
	rl := svc.client_langserver_reload(pair.conn, alloc, deadline)
	testing.expect_value(t, rl.call_err, jsonrpc.Call_Err.None)
	if rl.call_err == .None {
		testing.expect_value(t, json_int_of(rl.result, "overrides"), 3)
	}

	abs := svc.client_langserver_start(pair.conn, "crystal", alloc, deadline)
	testing.expect_value(t, abs.call_err, jsonrpc.Call_Err.Error_Response)
	when ODIN_OS == .Windows {
		testing.expect(t, strings.contains(abs.err_message, "\\no\\such\\crystalline-abs"))
	} else {
		testing.expect(t, strings.contains(abs.err_message, "/no/such/crystalline-abs"))
	}

	rel := svc.client_langserver_start(pair.conn, "elm", alloc, deadline)
	testing.expect_value(t, rel.call_err, jsonrpc.Call_Err.Error_Response)
	when ODIN_OS == .Windows {
		testing.expect(
			t,
			strings.contains(rel.err_message, strings.concatenate({pair.tmp, "\\nested\\elm-rel"}, alloc)),
		)
	} else {
		testing.expect(
			t,
			strings.contains(rel.err_message, strings.concatenate({pair.tmp, "/nested/elm-rel"}, alloc)),
		)
	}

	wins := svc.client_langserver_start(pair.conn, "python", alloc, deadline)
	testing.expect_value(t, wins.call_err, jsonrpc.Call_Err.Error_Response)
	when ODIN_OS == .Windows {
		testing.expect(t, strings.contains(wins.err_message, "\\no\\such\\python-wins"))
	} else {
		testing.expect(t, strings.contains(wins.err_message, "/no/such/python-wins"))
	}
	testing.expect(t, !strings.contains(wins.err_message, "python-loses"))
}

// tools package tests: Param_Desc -> JSON Schema projection (MCP 2025-11
// default dialect), argument validation, capability-based visibility, and
// the dispatch chain (unknown tool, not-visible, invalid args, apply via a
// synchronous fake pool, cancellation before start).
package tests

import "core:encoding/json"
import "core:strings"
import "core:mem"
import "core:slice"
import "core:testing"
import "core:thread"
import "src:config"
import "src:editor"
import "src:hooks"
import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:regex"
import "src:rpc"
import "src:svc"
import "src:tools"
import "src:tracker"
import "src:web"

// --- schema projection -------------------------------------------------------

@(test)
schema_projection :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	desc := tools.Tool_Desc{
		name  = "x",
		title = "X",
		params = []tools.Param_Desc{
			{name = "path", kind = .Str, description = "a path", required = true},
			{name = "limit", kind = .Int, required = false},
			{name = "flavor", kind = .Str, required = true, enum_vals = []string{"a", "b"}},
		},
	}
	schema := tools.schema_for_tool(&desc, a)

	testing.expect_value(t, obj_str(schema, "$schema"), tools.SCHEMA_DIALECT)
	testing.expect_value(t, obj_str(schema, "type"), "object")

	props, props_ok := jsonutil.obj_get(schema, "properties")
	testing.expect(t, props_ok)
	path_prop, path_ok := jsonutil.obj_get(props, "path")
	testing.expect(t, path_ok)
	testing.expect_value(t, obj_str(path_prop, "type"), "string")
	testing.expect_value(t, obj_str(path_prop, "description"), "a path")

	limit_prop, _ := jsonutil.obj_get(props, "limit")
	testing.expect_value(t, obj_str(limit_prop, "type"), "integer")

	flavor_prop, _ := jsonutil.obj_get(props, "flavor")
	enum_val, enum_ok := jsonutil.obj_get(flavor_prop, "enum")
	testing.expect(t, enum_ok)
	enum_arr, is_arr := jsonutil.as_array(enum_val)
	testing.expect(t, is_arr && len(enum_arr) == 2)
	v0, v1 := "", ""
	#partial switch e in enum_arr[0] {
	case string: v0 = e
	}
	#partial switch e in enum_arr[1] {
	case string: v1 = e
	}
	testing.expect_value(t, v0, "a")
	testing.expect_value(t, v1, "b")

	req, req_ok := jsonutil.obj_get(schema, "required")
	testing.expect(t, req_ok)
	req_arr, _ := jsonutil.as_array(req)
	testing.expect_value(t, len(req_arr), 2)
	r0, r1 := "", ""
	#partial switch e in req_arr[0] {
	case string: r0 = e
	}
	#partial switch e in req_arr[1] {
	case string: r1 = e
	}
	testing.expect_value(t, r0, "path")
	testing.expect_value(t, r1, "flavor")
}

// --- validation ---------------------------------------------------------------

// The param table is built in-frame exactly like schema_projection's: a
// helper returning its own frame literal dangles (the frame dies at the
// return), so the table is assembled where it is used.

parse_obj :: proc(s: string) -> json.Value {
	v, err := json.parse_string(s, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	if err != nil {
		return nil
	}
	return v
}

@(test)
validate_args_table :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)
	desc := tools.Tool_Desc{
		name = "x",
		params = []tools.Param_Desc{
			{name = "path", kind = .Str, required = true},
			{name = "count", kind = .Int, required = false},
			{name = "deep", kind = .Bool, required = false},
			{name = "tags", kind = .Str_Array, required = false},
		},
	}

	// Happy path: required present, extras ignored.
	values, msg := tools.validate_args(&desc, parse_obj(`{"path": "p", "extra": 1}`), a)
	testing.expect_value(t, msg, "")
	testing.expect(t, values != nil)
	if v, ok := values["path"]; ok {
		testing.expect_value(t, jsonutil.value_str(v), "p")
	}

	// Missing required parameter.
	_, msg = tools.validate_args(&desc, parse_obj(`{}`), a)
	testing.expectf(t, msg != "", "missing required must fail")
	testing.expect(t, strings.contains(msg, "path"), msg)

	// Wrong kind.
	_, msg = tools.validate_args(&desc, parse_obj(`{"path": 7}`), a)
	testing.expectf(t, msg != "", "wrong kind must fail")

	// Bool param.
	_, msg = tools.validate_args(&desc, parse_obj(`{"path": "p", "deep": true}`), a)
	testing.expect_value(t, msg, "")

	// String array param with a non-string member.
	_, msg = tools.validate_args(&desc, parse_obj(`{"path": "p", "tags": ["ok", 3]}`), a)
	testing.expectf(t, msg != "", "non-string member must fail")

	// Nil arguments object behaves as {} (missing required).
	_, msg = tools.validate_args(&desc, nil, a)
	testing.expectf(t, msg != "", "nil args with required params must fail")
}

// --- visibility ---------------------------------------------------------------

@(test)
visibility_by_caps :: proc(t: ^testing.T) {
	// The onboarding family needs no capability: always visible.
	testing.expect(t, tools.visible(.Onboarding_Check, {}))
	testing.expect(t, tools.visible(.Onboarding_Check, {.Svc}))
	testing.expect(t, tools.visible(.Onboarding_Read_Instructions, {}))
	testing.expect(t, tools.visible(.Onboarding_Run, {}))

	set := tools.visibility_set({})
	testing.expect_value(t, card(set), 3)
	testing.expect(t, .Onboarding_Check in set)
	testing.expect(t, .Onboarding_Read_Instructions in set)
	testing.expect(t, .Onboarding_Run in set)
}

// --- dispatch -----------------------------------------------------------------

// Rec_Entry mirrors the host-side cancel-registry contract: the register
// callback stores the token under the id key, cancel fires it, deregister
// frees both — nothing may be left behind for a completed call.
Rec_Entry :: struct {
	key:   string, // owned clone ("n<num>" / "s<text>")
	token: ^platform.Cancel_Token,
	fired: bool,
}

// Rec_Audit records one measurement-stage visit for the assertions
// below (the port fires after the apply with the response size).
Rec_Audit :: struct {
	tool:         string, // owned clone
	ok:           bool,
	duration_ms:  i64,
	result_bytes: int,
}

Dispatch_Rec :: struct {
	responses: [dynamic]string,
	resp_is_error: [dynamic]bool,
	errors:    [dynamic]string,
	err_codes: [dynamic]jsonrpc.Err_Code,
	entries:   [dynamic]Rec_Entry,
	queued:    [dynamic]^tools.Call_Task, // deferred-pool mode
	audits:    [dynamic]Rec_Audit,
}

rec_audit :: proc(user: rawptr, tool: string, ok: bool, duration_ms: i64, result_bytes: int) {
	rec := cast(^Dispatch_Rec)user
	append(&rec.audits, Rec_Audit{tool = strings.clone(tool, context.allocator), ok = ok, duration_ms = duration_ms, result_bytes = result_bytes})
}

rec_response :: proc(user: rawptr, id: jsonrpc.Id, id_set: bool, is_error: bool, text: string) {
	rec := cast(^Dispatch_Rec)user
	// Clone: text lives in the request arena, freed when run_task returns.
	append(&rec.responses, strings.clone(text, context.allocator))
	append(&rec.resp_is_error, is_error)
}

rec_error :: proc(user: rawptr, id: jsonrpc.Id, id_set: bool, code: jsonrpc.Err_Code, msg: string) {
	rec := cast(^Dispatch_Rec)user
	append(&rec.errors, strings.clone(msg, context.allocator))
	append(&rec.err_codes, code)
}

rec_submit :: proc(user: rawptr, task: ^tools.Call_Task) {
	// Synchronous fake pool.
	tools.run_task(task)
}

rec_defer_submit :: proc(user: rawptr, task: ^tools.Call_Task) {
	rec := cast(^Dispatch_Rec)user
	append(&rec.queued, task)
}

rec_register :: proc(user: rawptr, id: jsonrpc.Id, token: ^platform.Cancel_Token) {
	rec := cast(^Dispatch_Rec)user
	entry: Rec_Entry = {key = rec_id_key(id), token = token}
	append(&rec.entries, entry)
}

rec_deregister :: proc(user: rawptr, id: jsonrpc.Id, token: ^platform.Cancel_Token) {
	rec := cast(^Dispatch_Rec)user
	key := rec_id_key(id)
	for i := 0; i < len(rec.entries); i += 1 {
		if rec.entries[i].key == key {
			delete(rec.entries[i].key, context.allocator)
			ordered_remove(&rec.entries, i)
			break
		}
	}
	delete(key, context.allocator)
}

// rec_fire emulates the host's on_cancel: fire the token registered under
// the key.
rec_fire :: proc(rec: ^Dispatch_Rec, key: string) {
	for i := 0; i < len(rec.entries); i += 1 {
		if rec.entries[i].key == key && rec.entries[i].token != nil {
			rec.entries[i].fired = true
			platform.token_fire(rec.entries[i].token, .Cancelled)
		}
	}
}

// rec_id_key mirrors the session host's key scheme: "n<num>" for numeric
// ids, "s<text>" for string ids (full clone, no truncation).
rec_id_key :: proc(id: jsonrpc.Id) -> string {
	switch v in id {
	case i64:
		buf: [32]u8
		buf[0] = 'n'
		n := rec_i64_to_buf(v, buf[1:])
		return rec_clone(string(buf[:1 + n]))
	case string:
		out := make([]u8, len(v) + 1, context.allocator)
		out[0] = 's'
		for i := 0; i < len(v); i += 1 {
			out[1 + i] = v[i]
		}
		return string(out)
	}
	return "?"
}

rec_clone :: proc(s: string) -> string {
	out := make([]u8, len(s), context.allocator)
	for i := 0; i < len(s); i += 1 {
		out[i] = s[i]
	}
	return string(out)
}

rec_i64_to_buf :: proc(v: i64, buf: []u8) -> int {
	neg := v < 0
	uv := u64(v) if !neg else -u64(v)
	digits: [24]u8
	n := 0
	if uv == 0 {
		digits[0] = '0'
		n = 1
	}
	for uv > 0 {
		digits[n] = u8('0' + uv % 10)
		uv /= 10
		n += 1
	}
	out := 0
	if neg && out < len(buf) {
		buf[out] = '-'
		out += 1
	}
	for j := n - 1; j >= 0 && out < len(buf); j -= 1 {
		buf[out] = digits[j]
		out += 1
	}
	return out
}

rec_new :: proc() -> ^Dispatch_Rec {
	rec := new(Dispatch_Rec, context.allocator)
	rec^ = {}
	return rec
}

rec_free :: proc(rec: ^Dispatch_Rec) {
	for s in rec.responses {
		delete(s)
	}
	for s in rec.errors {
		delete(s)
	}
	for e in rec.entries {
		delete(e.key, context.allocator)
	}
	for a in rec.audits {
		delete(a.tool)
	}
	delete(rec.responses)
	delete(rec.resp_is_error)
	delete(rec.errors)
	delete(rec.err_codes)
	delete(rec.entries)
	delete(rec.queued) // queued tasks are freed by run_task itself
	delete(rec.audits)
	free(rec, context.allocator)
}

dispatch_setup :: proc(
	rec: ^Dispatch_Rec,
	root: ^platform.Cancel_Token,
	caps: bit_set[tools.Cap],
	clock: ^platform.Clock,
	timeout_ms: i64,
	deferred_pool: bool,
) -> tools.Dispatch_Host {
	submit: proc(user: rawptr, task: ^tools.Call_Task) = rec_submit
	if deferred_pool {
		submit = rec_defer_submit
	}
	return {
		user            = rec,
		submit          = submit,
		send_response   = rec_response,
		send_error      = rec_error,
		register        = rec_register,
		deregister      = rec_deregister,
		audit           = rec_audit,
		available_caps  = caps,
		visible         = tools.visibility_set(caps),
		root            = root,
		clock           = clock,
		tool_timeout_ms = timeout_ms,
		retry_poll_ms   = tools.RETRY_POLL_MS,
		session         = nil,
		allocator       = context.allocator,
		cancel_alloc    = context.allocator,
	}
}

@(test)
dispatch_chain :: proc(t: ^testing.T) {
	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	defer platform.clock_destroy(clock)
	platform.clock_init(clock, false, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	rec := rec_new()
	defer rec_free(rec)
	host := dispatch_setup(rec, root, {}, clock, 1000, false)

	// Unknown tool -> immediate -32602.
	tools.dispatch_call(&host, "nope", nil, "", 1, true)
	if len(rec.errors) != 1 {
		testing.expectf(t, false, "unknown tool must answer one error")
		return
	}
	testing.expect_value(t, rec.err_codes[0], jsonrpc.Err_Code.Invalid_Params)

	// The registered tool runs through the fake pool and answers; the
	// cancel registry saw register and deregister (net zero entries).
	tools.dispatch_call(&host, "onboarding_check", nil, "{}", 2, true)
	if len(rec.responses) != 1 {
		testing.expectf(t, false, "the call must answer one response")
		return
	}
	// No parent link in this host: the memory-backed check skips.
	testing.expectf(t, strings.contains(rec.responses[0], "skipping onboarding check"), rec.responses[0])
	testing.expect_value(t, len(rec.entries), 0)

	// The measurement stage fired exactly once, after the apply, with
	// the response size of the answer it just sent.
	if len(rec.audits) != 1 {
		testing.expectf(t, false, "the audit stage must fire exactly once")
		return
	}
	testing.expect_value(t, rec.audits[0].tool, "onboarding_check")
	testing.expect_value(t, rec.audits[0].ok, true)
	testing.expect_value(t, rec.audits[0].result_bytes, len(rec.responses[0]))

	// A cancelled root answers -32800 before execution.
	platform.token_fire(root, .Shutdown)
	tools.dispatch_call(&host, "onboarding_check", nil, "{}", 3, true)
	testing.expect_value(t, len(rec.errors), 2)
	testing.expect_value(t, rec.err_codes[1], jsonrpc.Err_Code.Request_Cancelled)
}

@(test)
dispatch_gates_on_the_folded_set :: proc(t: ^testing.T) {
	// tools/call gates on the same fold_visibility output tools/list
	// serves: a read_only fold hides a can_edit tool even though the raw
	// caps satisfy it, and an unset fold fails closed.
	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	defer platform.clock_destroy(clock)
	platform.clock_init(clock, false, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	rec := rec_new()
	defer rec_free(rec)
	host := dispatch_setup(rec, root, {.Project, .Svc, .Editor}, clock, 0, false)
	host.visible = tools.visibility_set({.Project, .Svc}, true)

	tools.dispatch_call(&host, "file_write", nil, "{}", 1, true)
	testing.expect_value(t, len(rec.errors), 1)
	testing.expect_value(t, rec.err_codes[0], jsonrpc.Err_Code.Invalid_Params)
	testing.expectf(t, strings.contains(rec.errors[0], "not available"), rec.errors[0])

	// Fail closed: a host that forgets to refresh the fold hides
	// everything, including tools the caps would allow.
	host.visible = {}
	tools.dispatch_call(&host, "onboarding_check", nil, "{}", 2, true)
	testing.expect_value(t, len(rec.errors), 2)
	testing.expect_value(t, rec.err_codes[1], jsonrpc.Err_Code.Invalid_Params)
}

@(test)
dispatch_cancel_registry_contract :: proc(t: ^testing.T) {
	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	defer platform.clock_destroy(clock)
	platform.clock_init(clock, false, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	rec := rec_new()
	defer rec_free(rec)
	host := dispatch_setup(rec, root, {}, clock, 0, true)

	// String id, deferred pool: the task is registered but not started.
	tools.dispatch_call(&host, "onboarding_check", nil, "{}", "call-1", true)
	testing.expect_value(t, len(rec.entries), 1)
	testing.expect_value(t, len(rec.queued), 1)

	// Cancel fires the registered token; the queued task then answers
	// -32800 before execution and deregisters (entry freed, key gone).
	if len(rec.entries) == 0 {
		testing.expectf(t, false, "dispatch_call registered no entry")
		return
	}
	rec_fire(rec, "scall-1")
	testing.expect(t, rec.entries[0].fired)
	for task in rec.queued {
		tools.run_task(task)
	}
	testing.expect_value(t, len(rec.errors), 1)
	testing.expect_value(t, rec.err_codes[0], jsonrpc.Err_Code.Request_Cancelled)
	testing.expect_value(t, len(rec.entries), 0)
}

@(test)
dispatch_deadline_fires_through_clock :: proc(t: ^testing.T) {
	// Virtual clock: the deadline timer is armed at now+timeout and fired
	// by clock_advance — proving tool_timeout_ms is enforced by the Clock,
	// not inert data on the token.
	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	defer platform.clock_destroy(clock)
	platform.clock_init(clock, true, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	rec := rec_new()
	defer rec_free(rec)
	host := dispatch_setup(rec, root, {}, clock, 100, true)

	tools.dispatch_call(&host, "onboarding_check", nil, "{}", 5, true)
	testing.expect_value(t, len(rec.queued), 1)

	platform.clock_advance(clock, 200) // -> .Deadline fires the task token
	for task in rec.queued {
		tools.run_task(task)
	}
	testing.expect_value(t, len(rec.errors), 1)
	testing.expect_value(t, rec.err_codes[0], jsonrpc.Err_Code.Request_Cancelled)
	testing.expect_value(t, len(rec.entries), 0)
}

// --- shell answer quoting -----------------------------------------------------

@(test)
tools_json_quote_invalid_utf8_and_escapes :: proc(t: ^testing.T) {
	// Broken bytes must become U+FFFD replacements, not raw invalid JSON;
	// C0 controls escape as \u00XX, quotes/backslashes as two-char escapes,
	// and multi-byte runes re-encode through all UTF-8 widths.
	// Byte-exact literals: the input carries raw invalid UTF-8 (FF FE) and
	// the want-string the U+FFFD (EF BF BD) replacements and re-encoded
	// multi-byte runes.
	got := jsonutil.json_quote(
		"\xff\xfeok\"\\\x0a\x01\xc3\xa9\xf0\x9f\x98\x80",
		context.allocator,
	)
	want := "\"\xef\xbf\xbd\xef\xbf\xbdok\\\"\\\\\\n\\u0001\xc3\xa9\xf0\x9f\x98\x80\""
	testing.expect_value(t, got, want)
	delete(got)
}

@(test)
tools_json_quote_c0_control_hex_digits :: proc(t: ^testing.T) {
	// C0 controls without a named escape render as \u00XX with lowercase
	// hex digits: nibbles >= 10 must land on 'a'..'f', not the ASCII run
	// past '9' (which emitted invalid literals like \u00; for VT).
	got := jsonutil.json_quote("\x0b\x1b\x1f", context.allocator)
	want := "\"\\u000b\\u001b\\u001f\""
	testing.expect_value(t, got, want)
	delete(got)
}

// --- the retry stage -----------------------------------------------------------

// retry_probe_calls counts the fake parent's answers (ODIN_TEST_THREADS=1
// keeps the suite serial, so the package-level counter is race-free).
retry_probe_calls: int

// h_retry_probe answers svc.symbol/list with the typed retryable server
// error twice, then succeeds — the wire shape the daemon's err_to_jsonrpc
// produces for a cooldown-gated language-server start.
h_retry_probe :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	_ = conn
	_ = env
	retry_probe_calls += 1
	if retry_probe_calls <= 2 {
		return {
			is_error   = true,
			err_code   = .Server_Retryable,
			err_message = "language server failed recently; retrying after the cooldown",
		}, .Respond
	}
	v, _ := json.parse_string(`{"symbols": []}`, spec = .JSON, allocator = arena)
	return {result = v}, .Respond
}

// h_retry_stuck answers every call with the retryable error: an editing
// tool must answer it without a single re-apply.
h_retry_stuck :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	_ = conn
	_ = env
	_ = arena
	retry_probe_calls += 1
	return {
		is_error   = true,
		err_code   = .Server_Retryable,
		err_message = "language server failed recently; retrying after the cooldown",
	}, .Respond
}

// retry_pair builds a child conn against a fake parent serving `handler`
// for one method. BOTH conns get a reader thread: conn_call's reply only
// arrives if the client side is pumped too. Caller closes with
// retry_pair_shutdown.
Retry_Pair :: struct {
	client:  ^jsonrpc.Conn,
	server:  ^jsonrpc.Conn,
	e_client: ^rpc.Chan_Endpoint,
	e_server: ^rpc.Chan_Endpoint,
	client_reader: ^thread.Thread,
	server_reader: ^thread.Thread,
	client_box:   ^Conn_Box,
	server_box:   ^Conn_Box,
}

retry_conn_pump :: proc(conn: ^jsonrpc.Conn) -> (^thread.Thread, ^Conn_Box) {
	box := new(Conn_Box, context.allocator)
	box^ = {conn = conn}
	th := thread.create_and_start_with_data(box, conn_reader_entry, self_cleanup = false)
	return th, box
}

retry_pair_init :: proc(t: ^testing.T, method: string, handler: jsonrpc.Handler) -> ^Retry_Pair {
	e_client, e_server := rpc.channel_pair(context.allocator)
	if e_client == nil {
		testing.expectf(t, false, "channel_pair failed")
		return nil
	}
	server := new(jsonrpc.Conn, context.allocator)
	jsonrpc.conn_init(server, rpc.to_reader(&e_server.stream, jsonrpc.RPC_MAX_FRAME), rpc.to_writer(&e_server.stream), context.allocator)
	jsonrpc.conn_register(server, method, handler)
	server_reader, server_box := retry_conn_pump(server)

	client := new(jsonrpc.Conn, context.allocator)
	jsonrpc.conn_init(client, rpc.to_reader(&e_client.stream, jsonrpc.RPC_MAX_FRAME), rpc.to_writer(&e_client.stream), context.allocator)
	client_reader, client_box := retry_conn_pump(client)

	p := new(Retry_Pair, context.allocator)
	p^ = {
		client        = client,
		server        = server,
		e_client      = e_client,
		e_server      = e_server,
		client_reader = client_reader,
		server_reader = server_reader,
		client_box    = client_box,
		server_box    = server_box,
	}
	return p
}

retry_pair_shutdown :: proc(p: ^Retry_Pair) {
	// Mark both conns closed first, then close both streams BEFORE any
	// join: each reader is blocked on the peer's outgoing chan, and only
	// closing both directions wakes both readers (joining with one stream
	// still open deadlocks on the reader that feeds from it).
	jsonrpc.conn_close(p.client)
	jsonrpc.conn_close(p.server)
	p.e_client.stream.close(&p.e_client.stream)
	p.e_server.stream.close(&p.e_server.stream)
	if p.client_reader != nil {
		thread.join(p.client_reader)
		free(p.client_reader, context.allocator)
	}
	free(p.client_box, context.allocator)
	if p.server_reader != nil {
		thread.join(p.server_reader)
		free(p.server_reader, context.allocator)
	}
	free(p.server_box, context.allocator)

	rpc.channel_endpoint_destroy(p.e_server)
	rpc.channel_endpoint_destroy(p.e_client)
	jsonrpc.conn_destroy(p.client)
	jsonrpc.conn_destroy(p.server)
	free(p.client, context.allocator)
	free(p.server, context.allocator)
	free(p, context.allocator)
}

@(test)
dispatch_retries_retryable_read_only_calls :: proc(t: ^testing.T) {
	pair := retry_pair_init(t, svc.METHOD_SYMBOL_LIST, h_retry_probe)
	if pair == nil {
		return
	}
	defer retry_pair_shutdown(pair)

	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	defer platform.clock_destroy(clock)
	platform.clock_init(clock, false, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	rec := rec_new()
	defer rec_free(rec)
	host := dispatch_setup(rec, root, {.Project, .Svc, .Editor}, clock, 0, false)
	host.svc_conn = pair.client
	host.retry_poll_ms = 0 // retry without waiting: the fake answers inline

	retry_probe_calls = 0
	args_v, _ := json.parse_string(`{"relative_path": ""}`, spec = .JSON, allocator = context.temp_allocator)
	tools.dispatch_call(&host, "symbol_list", args_v, `{"relative_path": ""}`, 1, true)

	// Two retryable refusals, then the third apply carries the answer.
	// Guard the indexing: a bounds panic would skip the defers and take
	// the whole runner down with the pair's threads.
	testing.expect_value(t, len(rec.responses), 1)
	if len(rec.responses) == 0 {
		return
	}
	testing.expect_value(t, rec.resp_is_error[0], false)
	testing.expectf(t, strings.contains(rec.responses[0], "symbols"), rec.responses[0])
	testing.expect_value(t, retry_probe_calls, 3)
	// The measurement stage saw the final (successful) outcome.
	testing.expect_value(t, len(rec.audits), 1)
	if len(rec.audits) == 1 {
		testing.expect_value(t, rec.audits[0].ok, true)
	}
}

@(test)
dispatch_never_retries_editing_tools :: proc(t: ^testing.T) {
	pair := retry_pair_init(t, svc.METHOD_FILE_WRITE, h_retry_stuck)
	if pair == nil {
		return
	}
	defer retry_pair_shutdown(pair)

	clock := new(platform.Clock, context.allocator)
	defer free(clock, context.allocator)
	defer platform.clock_destroy(clock)
	platform.clock_init(clock, false, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)

	rec := rec_new()
	defer rec_free(rec)
	host := dispatch_setup(rec, root, {.Project, .Svc, .Editor}, clock, 0, false)
	host.svc_conn = pair.client
	host.retry_poll_ms = 0

	retry_probe_calls = 0
	args_v, _ := json.parse_string(`{"relative_path": "x.txt", "content": "hi"}`, spec = .JSON, allocator = context.temp_allocator)
	tools.dispatch_call(&host, "file_write", args_v, `{"relative_path": "x.txt", "content": "hi"}`, 1, true)

	// One apply, one refusal: non-idempotent tools answer retryable
	// errors as-is, with the typed code woven into the text.
	testing.expect_value(t, len(rec.responses), 1)
	if len(rec.responses) == 0 {
		return
	}
	testing.expect_value(t, rec.resp_is_error[0], true)
	testing.expectf(t, strings.contains(rec.responses[0], "[code -32000]"), rec.responses[0])
	testing.expect_value(t, retry_probe_calls, 1)
}

// --- the onboarding banner -----------------------------------------------------

// h_banner_memories answers the memory list probe: empty buckets while
// `h_banner_memories_empty` is true, one project memory once flipped.
h_banner_memories_empty: bool

h_banner_memories :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	_ = conn
	_ = env
	body := `{"memories": ["progress/notes"], "read_only_memories": []}`
	if h_banner_memories_empty {
		body = `{"memories": [], "read_only_memories": []}`
	}
	v, _ := json.parse_string(body, spec = .JSON, allocator = arena)
	return {result = v}, .Respond
}

h_banner_symbols :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	_ = conn
	_ = env
	v, _ := json.parse_string(`{"symbols": []}`, spec = .JSON, allocator = arena)
	return {result = v}, .Respond
}

banner_host_setup :: proc(rec: ^Dispatch_Rec, state: ^tools.Banner_State, pair: ^Retry_Pair) -> tools.Dispatch_Host {
	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, false, context.allocator)

	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)

	host := dispatch_setup(rec, root, {.Project, .Svc, .Editor, .Memories}, clock, 0, false)
	host.svc_conn = pair.client
	host.retry_poll_ms = 0
	host.banner = state
	return host
}

banner_host_cleanup :: proc(host: ^tools.Dispatch_Host) {
	platform.token_destroy(host.root, context.allocator)
	platform.clock_destroy(host.clock)
	free(host.clock, context.allocator)
}

@(test)
dispatch_onboarding_banner_once_per_session :: proc(t: ^testing.T) {
	pair := retry_pair_init(t, svc.METHOD_SYMBOL_LIST, h_banner_symbols)
	if pair == nil {
		return
	}
	defer retry_pair_shutdown(pair)
	jsonrpc.conn_register(pair.server, svc.METHOD_MEMORY_LIST, h_banner_memories)
	h_banner_memories_empty = true

	rec := rec_new()
	defer rec_free(rec)
	state: tools.Banner_State
	host := banner_host_setup(rec, &state, pair)
	defer banner_host_cleanup(&host)

	// An onboarding-family answer first: it is not banner-eligible and
	// does not consume the session's one shot.
	tools.dispatch_call(&host, "onboarding_check", nil, "{}", 1, true)
	if len(rec.responses) == 0 {
		return
	}
	testing.expectf(t, strings.contains(rec.responses[0], "Onboarding not performed yet"), rec.responses[0])
	testing.expectf(t, !strings.contains(rec.responses[0], "WARNING: Project onboarding"), rec.responses[0])
	testing.expect_value(t, state.is_decided, false)

	// The first eligible call carries the warning prefix...
	args_v, _ := json.parse_string(`{"relative_path": ""}`, spec = .JSON, allocator = context.temp_allocator)
	tools.dispatch_call(&host, "symbol_list", args_v, `{"relative_path": ""}`, 2, true)
	if len(rec.responses) < 2 {
		return
	}
	testing.expectf(t, strings.contains(rec.responses[1], "WARNING: Project onboarding"), rec.responses[1])
	testing.expectf(t, strings.contains(rec.responses[1], "symbols"), rec.responses[1])

	// ...and the second does not: once per session.
	tools.dispatch_call(&host, "symbol_list", args_v, `{"relative_path": ""}`, 3, true)
	if len(rec.responses) < 3 {
		return
	}
	testing.expectf(t, !strings.contains(rec.responses[2], "WARNING: Project onboarding"), rec.responses[2])
}

@(test)
dispatch_onboarding_banner_silent_when_done :: proc(t: ^testing.T) {
	pair := retry_pair_init(t, svc.METHOD_SYMBOL_LIST, h_banner_symbols)
	if pair == nil {
		return
	}
	defer retry_pair_shutdown(pair)
	jsonrpc.conn_register(pair.server, svc.METHOD_MEMORY_LIST, h_banner_memories)
	h_banner_memories_empty = false // a project memory exists: onboarding done

	rec := rec_new()
	defer rec_free(rec)
	state: tools.Banner_State
	host := banner_host_setup(rec, &state, pair)
	defer banner_host_cleanup(&host)

	args_v, _ := json.parse_string(`{"relative_path": ""}`, spec = .JSON, allocator = context.temp_allocator)
	tools.dispatch_call(&host, "symbol_list", args_v, `{"relative_path": ""}`, 1, true)
	if len(rec.responses) == 0 {
		return
	}
	testing.expectf(t, !strings.contains(rec.responses[0], "WARNING: Project onboarding"), rec.responses[0])
}

// The real table's enum-valued params must carry their values — a
// compiler constant-data bug once emptied web_search's inline range
// literal (every non-empty range value was then rejected by the
// validator); the test guards that class.
@(test)
web_search_range_enum_intact :: proc(t: ^testing.T) {
	table := tools.TOOLS
	ws_idx := -1
	for i in 0..<len(table) {
		if table[i].name == "web_search" {
			ws_idx = i
		}
	}
	testing.expectf(t, ws_idx >= 0, "web_search in the table")
	if ws_idx < 0 {
		return
	}
	ws := table[ws_idx]
	rng: []string = nil
	for p in ws.params {
		if p.name == "range" {
			rng = p.enum_vals
		}
	}
	testing.expect(t, len(rng) == 4, "range enum values present")
	if len(rng) == 4 {
		testing.expect(t, rng[0] == "d" && rng[1] == "w" && rng[2] == "m" && rng[3] == "y", "range values are d/w/m/y")
	}
	_, msg := tools.validate_args(&ws, parse_obj(`{"query": "q", "range": "d"}`), context.temp_allocator)
	testing.expect_value(t, msg, "")
}

@(test)
visible_names_sorted_with_markers :: proc(t: ^testing.T) {
	id_read, ok1 := tools.find_by_name("file_read")
	id_find, ok2 := tools.find_by_name("symbol_find")
	id_marker, ok3 := tools.find_by_name("marker_symbolic_read")
	testing.expect(t, ok1 && ok2 && ok3)
	if !ok1 || !ok2 || !ok3 {
		return
	}
	vis := tools.Visibility{id_read, id_find, id_marker}
	names, markers := tools.visible_names(vis, context.allocator)
	defer delete(names, context.allocator)
	defer delete(markers, context.allocator)
	testing.expect_value(t, len(names), 3)
	if len(names) == 3 {
		testing.expect_value(t, names[0], "file_read")
		testing.expect_value(t, names[1], "marker_symbolic_read")
		testing.expect_value(t, names[2], "symbol_find")
	}
	testing.expect_value(t, len(markers), 1)
	if len(markers) == 1 {
		testing.expect_value(t, markers[0], "ToolMarkerSymbolicRead")
	}
}

@(test)
symbol_find_description_states_matching_rule :: proc(t: ^testing.T) {
	id, ok := tools.find_by_name("symbol_find")
	testing.expect(t, ok)
	if !ok {
		return
	}
	// Materialize the constant table before indexing (the compiler
	// rejects variable indexing straight into constant data).
	table := tools.TOOLS
	desc := table[int(id)]
	// The matching rule must be visible to the model at the tool surface:
	// exact by default, glob through `*`, and the anchored name-path form.
	testing.expectf(
		t,
		strings.contains(desc.description, "exact match by default"),
		"description must state exact-by-default, got: %s",
		desc.description,
	)
	testing.expectf(
		t,
		strings.contains(desc.description, "glob"),
		"description must state the glob rule, got: %s",
		desc.description,
	)
}

@(test)
symbol_find_dead_code_shape :: proc(t: ^testing.T) {
	id, ok := tools.find_by_name("symbol_find_dead_code")
	testing.expect(t, ok)
	if !ok {
		return
	}
	table := tools.TOOLS
	desc := table[int(id)]
	testing.expect_value(t, desc.can_edit, false)
	testing.expect(t, desc.needs == {tools.Cap.Project, tools.Cap.Svc}, "needs Project+Svc")

	// Param kinds validate: strings, string array, ints.
	_, msg := tools.validate_args(&desc, parse_obj(`{"path_prefix": "src", "entry_prefixes": ["test_", "main"], "limit": 50}`), context.temp_allocator)
	testing.expect_value(t, msg, "")
	_, msg = tools.validate_args(&desc, parse_obj(`{"entry_prefixes": "test_"}`), context.temp_allocator)
	testing.expect(t, msg != "", "string entry_prefixes must be rejected")

	// The candidate framing must be visible at the tool surface — the
	// tool reports for review, it does not verdict.
	testing.expectf(
		t,
		strings.contains(desc.description, "unused inside this project"),
		"description must frame the answer as project-scoped review candidates, got: %s",
		desc.description,
	)
	// The default entry-prefix set includes the process entry name.
	testing.expectf(
		t,
		strings.contains(desc.description, "\"main\""),
		"description must state the main entry prefix, got: %s",
		desc.description,
	)
}

@(test)
ast_find_duplicates_shape :: proc(t: ^testing.T) {
	id, ok := tools.find_by_name("ast_find_duplicates")
	testing.expect(t, ok)
	if !ok {
		return
	}
	table := tools.TOOLS
	desc := table[int(id)]
	testing.expect_value(t, desc.can_edit, false)
	testing.expect(t, desc.needs == {tools.Cap.Project, tools.Cap.Svc}, "needs Project+Svc")

	// Param kinds validate: strings and ints.
	_, msg := tools.validate_args(&desc, parse_obj(`{"path_prefix": "src", "min_nodes": 40, "limit": 25}`), context.temp_allocator)
	testing.expect_value(t, msg, "")
	_, msg = tools.validate_args(&desc, parse_obj(`{"min_nodes": "ten"}`), context.temp_allocator)
	testing.expect(t, msg != "", "string min_nodes must be rejected")

	// The exactness contract must be visible at the tool surface: the two
	// kinds and the maximal-clone rule.
	testing.expectf(
		t,
		strings.contains(desc.description, "renamed"),
		"description must state the renamed kind, got: %s",
		desc.description,
	)
	testing.expectf(
		t,
		strings.contains(desc.description, "maximal clones"),
		"description must state the maximal-clone rule, got: %s",
		desc.description,
	)
}

// --- schema enum hints vs domain vocabularies ---------------------------------
//
// Param_Desc.enum_vals must be compile-time constants, so a schema hint
// array cannot derive from the domain's to_string procs. This test is the
// detection side instead: every hint set must neither over- nor
// under-advertise the vocabulary the parent actually accepts — a hint the
// domain rejects, or a domain value the schema hides, fails here.

expect_hint_set :: proc(t: ^testing.T, $E: typeid, to_string: proc(E) -> string, hints: []string, what: string) {
	for h in hints {
		known := false
		for e in E {
			if to_string(e) == h {
				known = true
				break
			}
		}
		testing.expectf(t, known, "%s schema hint %q is not a domain value", what, h)
	}
	for e in E {
		testing.expectf(t, slice.contains(hints, to_string(e)), "%s value %q is missing from the schema hints", what, to_string(e))
	}
}

@(test)
schema_enum_hints_match_domain_vocabularies :: proc(t: ^testing.T) {
	expect_hint_set(t, tracker.Priority, tracker.priority_string, tools.INCIDENT_PRIORITY_MODES, "priority")
	expect_hint_set(t, tracker.Verdict, tracker.verdict_string, tools.INCIDENT_VERDICT_MODES, "verdict")
	expect_hint_set(t, tracker.FP_Pattern, tracker.fp_pattern_string, tools.INCIDENT_FP_MODES, "fp_pattern")
	expect_hint_set(t, tracker.Resolution, tracker.resolution_string, tools.INCIDENT_RESOLUTION_MODES, "resolution")
	expect_hint_set(t, tracker.Defer_Kind, tracker.defer_kind_string, tools.SPRINT_DEFER_MODES, "defer_type")
	expect_hint_set(t, tracker.Verif_Outcome, tracker.verif_outcome_string, tools.SPRINT_VERIF_OUTCOME_MODES, "verif outcome")
	expect_hint_set(t, regex.Replace_Mode, regex.replace_mode_string, tools.FILE_REPLACE_MODES, "file replace mode")
	expect_hint_set(t, regex.Replace_Mode, regex.replace_mode_string, tools.MEMORY_REPLACE_MODES, "memory replace mode")
	expect_hint_set(t, lsp.Call_Direction, lsp.call_direction_string, tools.LANGSERVER_DIRECTIONS, "call direction")
	expect_hint_set(t, editor.Move_Mode, editor.move_mode_string, tools.SYMBOL_MOVE_MODES, "symbol move mode")

	// The web range hints face a table, not an enum — same two directions.
	for h in tools.WEB_SEARCH_RANGES {
		known := false
		for r in web.RANGE_CODES {
			if r.code == h {
				known = true
				break
			}
		}
		testing.expectf(t, known, "range schema hint %q is not a RANGE_CODES value", h)
	}
	for r in web.RANGE_CODES {
		testing.expectf(t, slice.contains(tools.WEB_SEARCH_RANGES, r.code), "range code %q is missing from the schema hints", r.code)
	}
}

// The builtin contexts and modes exclude tools by namespaced name;
// fold_visibility warns and SKIPS an unknown name, so a stale exclusion
// silently stops excluding — this binding fails on a tool rename (config
// cannot import the tools layer; the test imports both).
@(test)
builtin_exclusions_name_real_tools :: proc(t: ^testing.T) {
	for ctx in config.BUILTIN_CONTEXTS {
		for name in ctx.inclusion.excluded_tools {
			known := false
			for desc in tools.TOOLS {
				if desc.name == name {
					known = true
					break
				}
			}
			testing.expectf(t, known, "context %q excludes unknown tool %q", ctx.name, name)
		}
	}
	for mode in config.BUILTIN_MODES {
		for name in mode.inclusion.excluded_tools {
			known := false
			for desc in tools.TOOLS {
				if desc.name == name {
					known = true
					break
				}
			}
			testing.expectf(t, known, "mode %q excludes unknown tool %q", mode.name, name)
		}
	}
}

// The hooks classifier consumes the tools registry's working-tool set by
// injection (hooks cannot import the tools layer): this checks the
// injection contract against the registry itself — every registered tool,
// mangled the way a client reports it, classifies exactly as the derived
// set says, and no exclusion row goes stale (an excluded category that
// matches no tool is dead data).
@(test)
hooks_symbolic_set_matches_tool_registry :: proc(t: ^testing.T) {
	names := hooks.Aubade_Tool_Names{
		file_search = tools.tool_name(.File_Search),
		file_read   = tools.tool_name(.File_Read),
		symbolic    = tools.symbolic_hook_names(context.temp_allocator),
	}
	symbolic := make(map[string]bool, len(names.symbolic))
	defer delete(symbolic)
	for name in names.symbolic {
		symbolic[name] = true
	}
	for desc in tools.TOOLS {
		mangled := strings.concatenate({"mcp__aubade__", desc.name}, context.temp_allocator)
		_, in_set := symbolic[desc.name]
		testing.expectf(
			t,
			hooks.is_aubade_symbolic_tool(mangled, names) == in_set,
			"tool %q: the classifier and the injected set disagree",
			desc.name,
		)
	}
	for cat in tools.SYMBOLIC_HOOK_EXCLUDED_CATEGORIES {
		matched := false
		for desc in tools.TOOLS {
			if desc.category == cat {
				matched = true
				break
			}
		}
		testing.expectf(t, matched, "excluded category %v matches no tool", cat)
	}
}

// The tracker tool schemas' enum hints are copied wire spellings of the
// tracker enums (Param_Desc tables are compile-time constants, so they
// cannot derive from the enums): this pins every copy to its enum — a
// new member or a renamed spelling fails here instead of silently
// leaving the schema's vocabulary behind the validation's.
@(test)
tools_tracker_enum_tables_match_enums :: proc(t: ^testing.T) {
	expect_vocab :: proc(t: ^testing.T, table: []string, $E: typeid, to_string: proc(E) -> string, what: string) {
		i := 0
		for e in E {
			testing.expectf(
				t,
				i < len(table) && table[i] == to_string(e),
				"%s spelling %d: the schema enum hints and the enum disagree",
				what, i,
			)
			i += 1
		}
		testing.expectf(t, i == len(table), "%s: the schema lists %d spellings, the enum has %d", what, len(table), i)
	}
	expect_vocab(t, tools.INCIDENT_PRIORITY_MODES, tracker.Priority, tracker.priority_string, "incident priority")
	expect_vocab(t, tools.INCIDENT_VERDICT_MODES, tracker.Verdict, tracker.verdict_string, "incident verdict")
	expect_vocab(t, tools.INCIDENT_FP_MODES, tracker.FP_Pattern, tracker.fp_pattern_string, "fp pattern")
	expect_vocab(t, tools.INCIDENT_RESOLUTION_MODES, tracker.Resolution, tracker.resolution_string, "resolution")
	expect_vocab(t, tools.SPRINT_DEFER_MODES, tracker.Defer_Kind, tracker.defer_kind_string, "defer type")
	expect_vocab(t, tools.SPRINT_VERIF_OUTCOME_MODES, tracker.Verif_Outcome, tracker.verif_outcome_string, "verif outcome")
}

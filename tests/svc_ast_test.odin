// Contract tests for the ast svc face over the channel transport: the
// daemon-side handlers parse the tool argument shapes and answer with
// structured parse/query results; display shaping stays in the tool
// layer. These tests never call testing.fail_now: it aborts without
// running defers, and a live daemon pair left behind wedges the runner
// (expectf + early return keeps pair_shutdown on the defer stack).
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:svc"

json_array_elems :: proc(v: json.Value) -> ([]json.Value, bool) {
	return jsonutil.as_array(v)
}

@(test)
svc_ast_parse_sexpr :: proc(t: ^testing.T) {
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

	call := svc.client_ast_parse(pair.conn, "go", "package main\n", 0, alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	sexpr, ok := json_str_field(call.result, "sexpr")
	testing.expectf(t, ok, "sexpr missing")
	testing.expect_value(t, sexpr, "(source_file (package_clause (package_identifier \"main\")))")

	// A positive max_answer_chars bounds the rendering; the parens stay
	// balanced (every aborted node still closes on the way out).
	code := "package main\n\nfunc hello() {}\n"
	cut := svc.client_ast_parse(pair.conn, "go", code, 24, alloc, deadline)
	testing.expect_value(t, cut.call_err, jsonrpc.Call_Err.None)
	cut_sexpr, ok2 := json_str_field(cut.result, "sexpr")
	testing.expectf(t, ok2, "cut sexpr missing")
	if len(cut_sexpr) > 24+128 {
		testing.expectf(t, false, "sexpr not bounded: %d bytes", len(cut_sexpr))
	}
	bal := 0
	for c in cut_sexpr {
		if c == '(' {
			bal += 1
		} else if c == ')' {
			bal -= 1
		}
	}
	testing.expect_value(t, bal, 0)
}

@(test)
svc_ast_parse_errors :: proc(t: ^testing.T) {
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

	// Unknown language is a caller error.
	bad := svc.client_ast_parse(pair.conn, "abap", "x", 0, alloc, deadline)
	testing.expect_value(t, bad.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(bad.err_message, "unsupported language: abap"))

	// Oversize source is refused with the cap in the message.
	big := strings.clone("x", alloc)
	for len(big) <= svc.AST_MAX_CODE_BYTES {
		big = strings.concatenate({big, big, big, big}, alloc)
	}
	over := svc.client_ast_parse(pair.conn, "go", big, 0, alloc, deadline)
	testing.expect_value(t, over.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, over.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(over.err_message, "code is too large"))

	// lang is required on the wire.
	nolang := svc.client_ast_parse(pair.conn, "", "package main\n", 0, alloc, deadline)
	testing.expect_value(t, nolang.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, nolang.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(nolang.err_message, "lang is required"))
}

@(test)
svc_ast_query_matches :: proc(t: ^testing.T) {
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

	code := "package main\n\nfunc alpha() {}\n\nfunc beta() {}\n"
	call := svc.client_ast_query(pair.conn, "go", code, "(function_declaration name: (identifier) @name) @fn", alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)

	matches_v, ok := jsonutil.obj_get(call.result, "matches")
	testing.expectf(t, ok, "matches missing")
	matches, aok := json_array_elems(matches_v)
	if !aok || len(matches) != 2 {
		testing.expectf(t, false, "expected a 2-match array, ok=%v len=%d", aok, len(matches))
		return
	}

	pattern, _ := json_int_field(matches[0], "pattern")
	testing.expect_value(t, pattern, 0)
	caps_v, cok := jsonutil.obj_get(matches[0], "captures")
	testing.expectf(t, cok, "captures missing")
	caps, ok2 := json_array_elems(caps_v)
	if !ok2 || len(caps) != 2 {
		testing.expectf(t, false, "expected a 2-capture array, ok=%v len=%d", ok2, len(caps))
		return
	}

	// Capture order: outer @fn first, inner @name second; byte ranges
	// point into the source.
	fn_name, _ := json_str_field(caps[0], "name")
	fn_text, _ := json_str_field(caps[0], "text")
	testing.expect_value(t, fn_name, "fn")
	testing.expect(t, fn_text == "func alpha() {}")
	name_name, _ := json_str_field(caps[1], "name")
	name_text, _ := json_str_field(caps[1], "text")
	testing.expect_value(t, name_name, "name")
	testing.expect_value(t, name_text, "alpha")
	start, _ := json_int_field(caps[1], "start_byte")
	end, _ := json_int_field(caps[1], "end_byte")
	testing.expect(t, start < end)
	if start >= 0 && end > start && end <= i64(len(code)) {
		testing.expect_value(t, code[int(start):int(end)], "alpha")
	} else {
		testing.expectf(t, false, "capture range out of bounds: %d:%d", start, end)
	}

	// A valid pattern that matches nothing answers an empty array — the
	// "No matches found." wording belongs to the tool layer.
	none := svc.client_ast_query(pair.conn, "go", code, "(import_spec) @imp", alloc, deadline)
	testing.expect_value(t, none.call_err, jsonrpc.Call_Err.None)
	none_matches_v, nok := jsonutil.obj_get(none.result, "matches")
	testing.expectf(t, nok, "matches missing on empty result")
	none_matches, nok2 := json_array_elems(none_matches_v)
	testing.expectf(t, nok2, "matches not an array on empty result")
	testing.expect_value(t, len(none_matches), 0)
}

@(test)
svc_ast_query_errors :: proc(t: ^testing.T) {
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

	// Query syntax errors surface as caller errors.
	bad := svc.client_ast_query(pair.conn, "go", "package main\n", "(((", alloc, deadline)
	testing.expect_value(t, bad.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(bad.err_message, "query syntax error"))

	// Oversize query text is refused with the cap in the message.
	big_q := strings.clone("(identifier)", alloc)
	for len(big_q) <= svc.AST_MAX_QUERY_BYTES {
		big_q = strings.concatenate({big_q, big_q, big_q, big_q}, alloc)
	}
	over := svc.client_ast_query(pair.conn, "go", "package main\n", big_q, alloc, deadline)
	testing.expect_value(t, over.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, over.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(over.err_message, "query is too large"))

	// An empty query is rejected before the ts layer (an empty query
	// string compiles to zero patterns there, but the tool treats it as
	// an error).
	empty := svc.client_ast_query(pair.conn, "go", "package main\n", "", alloc, deadline)
	testing.expect_value(t, empty.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, empty.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(empty.err_message, "query is required"))

	// An absent query param is the same caller error (the typed proxy
	// always sends it, so this needs a raw call).
	params := jsonutil.json_object(2, alloc)
	jsonutil.obj_set(&params, "lang", jsonutil.json_string("go"))
	jsonutil.obj_set(&params, "code", jsonutil.json_string("package main\n"))
	_, ecode, emsg, ecerr := jsonrpc.conn_call(
		pair.conn, svc.METHOD_AST_QUERY, json.Value(json.Object(params)), alloc, deadline,
	)
	testing.expect_value(t, ecerr, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, ecode, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(emsg, "query is required"))
}

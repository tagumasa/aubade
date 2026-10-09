// lspserver relay tests: the definition/references/declaration face over
// the same synchronous pipe harness as the face tests (shared host fakes,
// pipes, and frame helpers — see lspserver_face_test.odin), the relay
// diagnostics republish, the dynamic registration round trips (driven with
// one helper thread answering over the pipe — no sleeps), and the host
// half (push handlers, per-language state, the starter pass) against a
// channel-pair fake daemon in the svc_test retry-pair mold.
package tests

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:platform"
import "src:rpc"
import "src:safety"
import "src:session"
import "src:symbol"
import "src:svc"

// --- face-side readers ------------------------------------------------------

// lsprelay_result_locations digs the Location[] array out of a relay reply.
lsprelay_result_locations :: proc(t: ^testing.T, body: string) -> []json.Value {
	testing.expectf(t, body != "", "relay request produced no reply")
	if body == "" {
		return nil
	}
	testing.expectf(t, lspface_reply_code(t, body) == 0, "relay request answered an error: %s", body)
	v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "relay reply did not parse: %s", body)
	if perr != nil {
		return nil
	}
	result, ok := jsonutil.obj_get(v, "result")
	testing.expect(t, ok, "relay reply carries no result")
	if !ok {
		return nil
	}
	items, is_arr := jsonutil.as_array(result)
	testing.expect(t, is_arr, "relay result is not an array")
	return items
}

// lsprelay_location_at reads one Location's uri and range.
lsprelay_location_at :: proc(t: ^testing.T, items: []json.Value, i: int) -> (uri: string, sl, sc, el, ec: i64) {
	testing.expectf(t, i < len(items), "location %d missing (%d answered)", i, len(items))
	if i >= len(items) {
		return
	}
	uri_v, ok := jsonutil.obj_get(items[i], "uri")
	testing.expect(t, ok, "location carries no uri")
	uri = jsonutil.value_str(uri_v)
	rng, rok := jsonutil.obj_get(items[i], "range")
	testing.expect(t, rok, "location carries no range")
	if !rok {
		return
	}
	start, _ := jsonutil.obj_get(rng, "start")
	end, _ := jsonutil.obj_get(rng, "end")
	sl = jsonutil.obj_get_int(start, "line")
	sc = jsonutil.obj_get_int(start, "character")
	el = jsonutil.obj_get_int(end, "line")
	ec = jsonutil.obj_get_int(end, "character")
	return
}

lsprelay_member_str :: proc(v: json.Value, key: string) -> string {
	if m, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.value_str(m)
	}
	return ""
}

// relayhost_read_publish pops one frame off the host pair's down pipe and
// returns the publishDiagnostics params (the lsppub_read_publish shape, on
// the host pair).
relayhost_read_publish :: proc(t: ^testing.T, p: ^Relayhost_Pair) -> json.Value {
	testing.expectf(t, len(p.down.buf) > 0, "expected a publish notification; the pipe is empty")
	if len(p.down.buf) == 0 {
		return nil
	}
	body, rerr := jsonrpc.read_frame(&p.recv, context.temp_allocator)
	testing.expectf(t, rerr == .None, "read_frame from the down pipe failed: %v", rerr)
	if rerr != .None {
		return nil
	}
	v, perr := json.parse_bytes(body, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "publish notification did not parse: %s", string(body))
	if perr != nil {
		return nil
	}
	method_v, has_method := jsonutil.obj_get(v, "method")
	testing.expectf(
		t,
		has_method && jsonutil.value_str(method_v) == lsp.METHOD_PUBLISH_DIAGNOSTICS,
		"expected a publishDiagnostics notification, got: %s",
		string(body),
	)
	params, has_params := jsonutil.obj_get(v, "params")
	testing.expect(t, has_params, "publish notification carries no params")
	return params
}

// --- tests: the relay requests ----------------------------------------------

@(test)
lsprelay_definition_roundtrip_utf16 :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n\nfunc main() {}\n"}`)

	locs := make([]lspserver.Relay_Location, 1, context.temp_allocator)
	locs[0] = {uri = "file:///w/prog.go", line = 2, col = 5, has_end = true, end_line = 2, end_col = 9}
	lspface_set_relay_result(&p.host, locs)
	defer lspface_clear_relay_result(&p.host)

	body := lspface_request(t, p, "2", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/prog.go"},"position":{"line":1,"character":0}`)
	items := lsprelay_result_locations(t, body)
	testing.expectf(t, len(items) == 1, "definition must answer one location, got %d", len(items))
	if len(items) == 1 {
		uri, sl, sc, el, ec := lsprelay_location_at(t, items, 0)
		testing.expectf(t, uri == "file:///w/prog.go", "the uri passes through, got %s", uri)
		testing.expectf(t, sl == 2 && sc == 5 && el == 2 && ec == 9, "the definition range must pass through utf-16 columns, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
	// The utf-16 connection's request position reached the host unchanged.
	testing.expect(t, p.host.relay_calls == 1, "the host must be called once")
	if p.host.relay_calls == 1 {
		r := p.host.relay_reqs[0]
		testing.expectf(t, r.kind == .Definition && r.line == 1 && r.col_utf16 == 0 && !r.include_declaration, "the host must see the raw request position")
	}
}

@(test)
lsprelay_utf8_request_position_converts :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// utf-8 connection: the wire character is a byte column and must reach
	// the host as a UTF-16 column. Bytes: x[0] ' '[1] ':'[2] '='[3] ' '[4]
	// '"'[5] h[6] é[7,8] l l o '"[12] \n[13] — byte 7 sits at the 'é'
	// start, whose UTF-16 column is 7 (the rune before it is one unit).
	lspface_default_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":1,"text":"x := \"héllo\"\ny := 1\n"}`)

	body := lspface_request(t, p, "2", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/prog.thing"},"position":{"line":0,"character":7}`)
	lsprelay_result_locations(t, body)
	testing.expect(t, p.host.relay_calls == 1, "the host must be called once")
	if p.host.relay_calls == 1 {
		testing.expectf(t, p.host.relay_reqs[0].col_utf16 == 7, "byte column 7 must convert to utf-16 column 7, got %d", p.host.relay_reqs[0].col_utf16)
	}

	// A byte column past the multi-byte rune (the closing quote at byte
	// 12) lands on utf-16 column 11.
	body2 := lspface_request(t, p, "3", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/prog.thing"},"position":{"line":0,"character":12}`)
	lsprelay_result_locations(t, body2)
	testing.expectf(t, p.host.relay_calls == 2, "the second request must reach the host, got %d calls", p.host.relay_calls)
	if p.host.relay_calls == 2 {
		testing.expectf(t, p.host.relay_reqs[1].col_utf16 == 11, "byte column 12 must convert to utf-16 column 11, got %d", p.host.relay_reqs[1].col_utf16)
	}
}

@(test)
lsprelay_answer_converts_to_utf8_and_drops_unserved :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// utf-8 connection: the answer's UTF-16 columns convert through the
	// TARGET file's bytes. "fn  héllo": f0 n1 ' '2 ' '3 h4 é[5,6] l7 l8
	// o9 — utf-16 col 5 is byte 5 (é), col 6 rounds past the rune to
	// byte 7.
	lspface_default_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	lspface_set_text(&p.host, "file:///w/target.go", "fn  héllo\n")

	locs := make([]lspserver.Relay_Location, 3, context.temp_allocator)
	locs[0] = {uri = "file:///w/target.go", line = 0, col = 5, has_end = true, end_line = 0, end_col = 4}
	locs[1] = {uri = "file:///w/target.go", line = 0, col = 6, has_end = false}
	locs[2] = {uri = "file:///w/unserved.go", line = 0, col = 1, has_end = false}
	lspface_set_relay_result(&p.host, locs)
	defer lspface_clear_relay_result(&p.host)

	body := lspface_request(t, p, "2", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/prog.go"},"position":{"line":0,"character":0}`)
	items := lsprelay_result_locations(t, body)
	testing.expectf(t, len(items) == 2, "the unserved location must be dropped, got %d", len(items))
	if len(items) == 2 {
		_, sl, sc, el, ec := lsprelay_location_at(t, items, 0)
		testing.expectf(t, sl == 0 && sc == 5 && el == 0 && ec == 4, "loc A must convert to (0,5)-(0,4) bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		_, sl, sc, el, ec = lsprelay_location_at(t, items, 1)
		testing.expectf(t, sl == 0 && sc == 7 && el == 0 && ec == 7, "loc B must convert to (0,7)-(0,7) bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
	// One fetch per unique document per request (the request-arena cache),
	// and the drop logs once per request.
	testing.expectf(t, p.host.text_calls == 2, "each target document must be fetched once, got %d", p.host.text_calls)
	testing.expectf(t, len(p.host.logs) == 1, "the drop must log once per request, got %d", len(p.host.logs))
}

@(test)
lsprelay_unopened_document_answers_empty :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-16"]`)
	body := lspface_request(t, p, "1", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/never-opened.go"},"position":{"line":0,"character":0}`)
	items := lsprelay_result_locations(t, body)
	testing.expectf(t, len(items) == 0, "an unopened document answers an empty array, got %d", len(items))
	testing.expect(t, p.host.relay_calls == 0, "an unopened document must not reach the host")
	testing.expect(t, len(p.host.logs) == 0, "an unopened document is a normal state, not a refusal")
}

@(test)
lsprelay_references_point_ranges_and_context :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	locs := make([]lspserver.Relay_Location, 1, context.temp_allocator)
	locs[0] = {uri = "file:///w/prog.go", line = 3, col = 2}
	lspface_set_relay_result(&p.host, locs)
	defer lspface_clear_relay_result(&p.host)

	body := lspface_request(t, p, "2", lsp.METHOD_REFERENCES, `"textDocument":{"uri":"file:///w/prog.go"},"position":{"line":1,"character":6},"context":{"includeDeclaration":true}`)
	items := lsprelay_result_locations(t, body)
	testing.expectf(t, len(items) == 1, "references must answer one location")
	if len(items) == 1 {
		_, sl, sc, el, ec := lsprelay_location_at(t, items, 0)
		testing.expectf(t, sl == 3 && sc == 2 && el == 3 && ec == 2, "a point location renders start == end, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
	if p.host.relay_calls == 1 {
		r := p.host.relay_reqs[0]
		testing.expectf(t, r.kind == .References && r.include_declaration, "references context.includeDeclaration must reach the host")
	}

	// Declaration rides the same handler with its own kind.
	body2 := lspface_request(t, p, "3", lsp.METHOD_DECLARATION, `"textDocument":{"uri":"file:///w/prog.go"},"position":{"line":1,"character":6}`)
	lsprelay_result_locations(t, body2)
	testing.expectf(t, p.host.relay_calls == 2, "the declaration request must reach the host, got %d calls", p.host.relay_calls)
	if p.host.relay_calls == 2 {
		testing.expect(t, p.host.relay_reqs[1].kind == .Declaration, "the declaration method must map to the Declaration kind")
	}
}

@(test)
lsprelay_failed_relay_logs_once_and_answers_empty :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	p.host.relay_failed = true
	p.host.relay_err = "the daemon link is down"
	body := lspface_request(t, p, "2", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/prog.go"},"position":{"line":0,"character":0}`)
	items := lsprelay_result_locations(t, body)
	testing.expectf(t, len(items) == 0, "a failed relay answers empty, got %d", len(items))
	testing.expectf(t, len(p.host.logs) == 1, "the failure must log once, got %d", len(p.host.logs))
	testing.expect(t, strings.contains(p.host.logs[0], "the daemon link is down"), "the log names the cause")
}

@(test)
lsprelay_request_before_initialize_refused :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	body := lspface_request(t, p, "1", lsp.METHOD_DEFINITION, `"textDocument":{"uri":"file:///w/x.go"},"position":{"line":0,"character":0}`)
	testing.expect(t, body != "", "the request must be answered")
	testing.expectf(t, lspface_reply_code(t, body) == -32002, "expected -32002 before initialize, got %s", body)
}

// --- tests: the diagnostics republish ----------------------------------------

@(test)
lsprelay_publish_relay_diagnostics_utf16_forwards :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-16"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":4,"text":"package main\n"}`)

	items := `[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":7}},"severity":1,"message":"undeclared"}]`
	lspserver.publish_relay_diagnostics(&p.server, uri, items, context.temp_allocator)

	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params) == uri, "the republish names the view's uri")
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 4, "the republish stamps the view's version 4, got %d", version)
	testing.expectf(t, lsppub_diag_count(t, params) == 1, "the pushed set forwards")
	sl, sc, el, ec := lsppub_diag_pos(t, params, 0)
	testing.expectf(t, sl == 0 && sc == 0 && el == 0 && ec == 7, "utf-16 columns forward unchanged, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	testing.expectf(t, len(p.down.buf) == 0, "exactly one publish went out")
}

@(test)
lsprelay_publish_relay_diagnostics_utf8_converts :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// utf-8 connection: the pushed UTF-16 columns convert through the
	// view's bytes. Line 0 spans utf-16 0..12: `"`[5] h6 é7 l8 l9 o10 `"11
	// — utf-16 (0,5)-(0,11) is bytes (0,5)-(0,12).
	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.thing"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":2,"text":"x := \"héllo\"\ny := 1\n"}`)

	items := `[{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":11}},"severity":1,"message":"unterminated"}]`
	lspserver.publish_relay_diagnostics(&p.server, uri, items, context.temp_allocator)

	params := lsppub_read_publish(t, p)
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 2, "the republish stamps the view's version 2, got %d", version)
	sl, sc, el, ec := lsppub_diag_pos(t, params, 0)
	testing.expectf(t, sl == 0 && sc == 5 && el == 0 && ec == 12, "utf-16 columns must convert to bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
}

@(test)
lsprelay_publish_relay_diagnostics_utf8_converts_related :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// utf-8 connection: a diagnostic's relatedInformation locations ride
	// the same snapshot conversion as the diagnostic's own range. Line 0
	// spans utf-16 0..12 (`"`[5] h6 é7 l8 l9 o10 `"11): the own range
	// utf-16 (0,5)-(0,8) is bytes (0,5)-(0,9) — é's two bytes sit between —
	// and the related range utf-16 (0,6)-(0,11) is bytes (0,6)-(0,12).
	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.thing"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":2,"text":"x := \"héllo\"\ny := 1\n"}`)

	items := `[{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":8}},"severity":1,"message":"unterminated",` +
		`"relatedInformation":[{"location":{"uri":"file:///w/prog.thing","range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}}},"message":"the string starts here"}]}]`
	lspserver.publish_relay_diagnostics(&p.server, uri, items, context.temp_allocator)

	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params) == 1, "the pushed set forwards")
	sl, sc, el, ec := lsppub_diag_pos(t, params, 0)
	testing.expectf(t, sl == 0 && sc == 5 && el == 0 && ec == 9, "the diagnostic's own range must convert to bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)

	diags_v, has_diags := jsonutil.obj_get(params, "diagnostics")
	testing.expect(t, has_diags, "the republish carries diagnostics")
	diags, is_arr := jsonutil.as_array(diags_v)
	testing.expectf(t, is_arr && len(diags) == 1, "one diagnostic republishes")
	if !is_arr || len(diags) == 0 {
		return
	}
	rel_v, has_rel := jsonutil.obj_get(diags[0], "relatedInformation")
	testing.expect(t, has_rel, "the diagnostic carries relatedInformation")
	rels, rel_arr := jsonutil.as_array(rel_v)
	testing.expectf(t, rel_arr && len(rels) == 1, "one related entry republishes")
	if !rel_arr || len(rels) == 0 {
		return
	}
	loc, has_loc := jsonutil.obj_get(rels[0], "location")
	testing.expect(t, has_loc, "the related entry carries a location")
	if !has_loc {
		return
	}
	rng, has_rng := jsonutil.obj_get(loc, "range")
	testing.expect(t, has_rng, "the related location carries a range")
	if !has_rng {
		return
	}
	start, _ := jsonutil.obj_get(rng, "start")
	end, _ := jsonutil.obj_get(rng, "end")
	rsc := jsonutil.obj_get_int(start, "character")
	rec := jsonutil.obj_get_int(end, "character")
	testing.expectf(t, rsc == 6 && rec == 12, "the related range must convert to bytes, got (0,%d)-(0,%d)", rsc, rec)
	testing.expectf(t, len(p.down.buf) == 0, "exactly one publish went out")
}

@(test)
lsprelay_publish_relay_diagnostics_unopened_silent :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-16"]`)
	lspserver.publish_relay_diagnostics(&p.server, "file:///w/never-opened.go", `[]`, context.temp_allocator)
	testing.expectf(t, len(p.down.buf) == 0, "a document the view does not hold publishes nothing")
}

// --- tests: dynamic registration round trips ---------------------------------

Register_Args :: struct {
	p:    ^Lspface_Pair,
	done: chan.Chan(bool),
}

register_thread_entry :: proc(args: ^Register_Args) {
	regs := make([]lspserver.Capability_Registration, 2, context.allocator)
	regs[0] = {id = "aubade.relay.go.definition", method = lsp.METHOD_DEFINITION, language = "go"}
	regs[1] = {id = "aubade.relay.go.references", method = lsp.METHOD_REFERENCES, language = "go"}
	ok := lspserver.server_register_capabilities(&args.p.server, regs, context.allocator, 2000)
	chan.send(chan.as_send(args.done), ok)
}

unregister_thread_entry :: proc(args: ^Register_Args) {
	regs := make([]lspserver.Capability_Registration, 2, context.allocator)
	regs[0] = {id = "aubade.relay.go.definition", method = lsp.METHOD_DEFINITION, language = "go"}
	regs[1] = {id = "aubade.relay.go.references", method = lsp.METHOD_REFERENCES, language = "go"}
	ok := lspserver.server_unregister_capabilities(&args.p.server, regs, context.allocator, 2000)
	chan.send(chan.as_send(args.done), ok)
}

// lsprelay_frame_id renders one request frame's id member as JSON text.
lsprelay_frame_id :: proc(t: ^testing.T, body: string) -> string {
	v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "request frame did not parse: %s", body)
	if perr != nil {
		return "0"
	}
	id, ok := jsonutil.obj_get(v, "id")
	testing.expect(t, ok, "request frame carries no id")
	if !ok {
		return "0"
	}
	#partial switch x in id {
	case i64:
		return fmt.aprintf("%d", x, allocator = context.temp_allocator)
	case string:
		return x
	case:
	}
	return "0"
}

// lsprelay_answer_request asserts one request frame via `check`, then
// answers it with a null result so the pending slot delivers.
lsprelay_answer_request :: proc(t: ^testing.T, p: ^Lspface_Pair, body: string, check: proc(t: ^testing.T, body: string)) {
	check(t, body)
	id := lsprelay_frame_id(t, body)
	reply := strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"result":null}`}, context.temp_allocator)
	werr := jsonrpc.write_frame(&p.send, json_bytes(reply))
	testing.expectf(t, werr == .None, "writing the reply frame failed: %v", werr)
	got, gerr := jsonrpc.read_frame(&p.conn.reader, context.temp_allocator)
	testing.expectf(t, gerr == .None, "reading the reply frame back failed: %v", gerr)
	if gerr == .None {
		jsonrpc.conn_handle_body(&p.conn, got, context.temp_allocator)
	}
}

// lsprelay_drive drives one helper thread that parks in a conn_call on the
// editor conn: the pump spins on the done chan (bounded iterations — a
// stuck call exits via the cap and the bounded join), answering every
// request frame the helper produces. No sleeps: the pipe is memory, the
// handoff is a chan.
lsprelay_drive :: proc(
	t: ^testing.T,
	p: ^Lspface_Pair,
	args: ^Register_Args,
	th: ^thread.Thread,
	check: proc(t: ^testing.T, body: string),
) -> bool {
	ok_seen := false
	pump: for i := 0; i < 2_000_000; i += 1 {
		if ok, has := chan.try_recv(chan.as_recv(args.done)); has {
			ok_seen = ok
			break pump
		}
		if len(p.down.buf) > 0 {
			frame, rerr := jsonrpc.read_frame(&p.recv, context.temp_allocator)
			testing.expectf(t, rerr == .None, "the request frame read failed: %v", rerr)
			if rerr != .None {
				break pump
			}
			lsprelay_answer_request(t, p, string(frame), check)
		}
	}
	chan.destroy(args.done)
	thread.join(th)
	free(th, context.allocator)
	return ok_seen
}

// lsprelay_assert_registration checks one registrations[] entry's id,
// method, and documentSelector language.
lsprelay_assert_registration :: proc(t: ^testing.T, params: json.Value, i: int, id, method, language: string) {
	regs_v, ok := jsonutil.obj_get(params, "registrations")
	testing.expect(t, ok, "registerCapability params carry no registrations")
	if !ok {
		return
	}
	items, is_arr := jsonutil.as_array(regs_v)
	testing.expectf(t, is_arr && i < len(items), "registration %d missing", i)
	if !is_arr || i >= len(items) {
		return
	}
	testing.expectf(t, lsprelay_member_str(items[i], "id") == id && lsprelay_member_str(items[i], "method") == method, "registration %d drifted from (%s,%s)", i, id, method)
	opts, has_opts := jsonutil.obj_get(items[i], "registerOptions")
	testing.expect(t, has_opts, "registerOptions missing")
	if !has_opts {
		return
	}
	sel, has_sel := jsonutil.obj_get(opts, "documentSelector")
	testing.expect(t, has_sel, "documentSelector missing")
	if !has_sel {
		return
	}
	entries, sel_arr := jsonutil.as_array(sel)
	testing.expectf(t, sel_arr && len(entries) == 1, "documentSelector must carry one entry")
	if !sel_arr || len(entries) != 1 {
		return
	}
	testing.expectf(t, lsprelay_member_str(entries[0], "language") == language, "documentSelector must name %s", language)
}

@(test)
lsprelay_register_capability_roundtrip :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	args := new(Register_Args, context.allocator)
	args.p = p
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expect(t, derr == nil, "chan create failed")
	if derr != nil {
		free(args, context.allocator)
		return
	}
	args.done = done
	th := thread.create_and_start_with_poly_data(args, register_thread_entry, self_cleanup = false)

	check := proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, perr == nil, "request frame did not parse: %s", body)
		if perr != nil {
			return
		}
		testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_REGISTER_CAPABILITY, "expected registerCapability, got %s", body)
		if params, ok := jsonutil.obj_get(v, "params"); ok {
			lsprelay_assert_registration(t, params, 0, "aubade.relay.go.definition", lsp.METHOD_DEFINITION, "go")
			lsprelay_assert_registration(t, params, 1, "aubade.relay.go.references", lsp.METHOD_REFERENCES, "go")
		}
	}
	ok := lsprelay_drive(t, p, args, th, check)
	testing.expect(t, ok, "server_register_capabilities must succeed over the wire")
	free(args, context.allocator)
}

@(test)
lsprelay_unregister_capability_roundtrip :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	args := new(Register_Args, context.allocator)
	args.p = p
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expect(t, derr == nil, "chan create failed")
	if derr != nil {
		free(args, context.allocator)
		return
	}
	args.done = done
	th := thread.create_and_start_with_poly_data(args, unregister_thread_entry, self_cleanup = false)

	check := proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, perr == nil, "request frame did not parse: %s", body)
		if perr != nil {
			return
		}
		testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_UNREGISTER_CAPABILITY, "expected unregisterCapability, got %s", body)
		params, ok := jsonutil.obj_get(v, "params")
		if !ok {
			return
		}
		// The specification's own (mis)spelling of the member.
		unregs, has := jsonutil.obj_get(params, "unregisterations")
		testing.expect(t, has, "unregisterCapability params must carry unregisterations")
		if !has {
			return
		}
		items, is_arr := jsonutil.as_array(unregs)
		testing.expectf(t, is_arr && len(items) == 2, "expected two unregistrations, got %d", len(items))
		if is_arr && len(items) == 2 {
			testing.expectf(t, lsprelay_member_str(items[0], "id") == "aubade.relay.go.definition" && lsprelay_member_str(items[0], "method") == lsp.METHOD_DEFINITION, "unregistration 0 drifted")
			testing.expectf(t, lsprelay_member_str(items[1], "id") == "aubade.relay.go.references" && lsprelay_member_str(items[1], "method") == lsp.METHOD_REFERENCES, "unregistration 1 drifted")
		}
	}
	ok := lsprelay_drive(t, p, args, th, check)
	testing.expect(t, ok, "server_unregister_capabilities must succeed over the wire")
	free(args, context.allocator)
}

// --- the host-level harness: a real Lsp_Host against a fake daemon ----------

// Relayhost_Daemon is the fake daemon's preset: what svc.langserver/start
// answers (capable, or Method_Not_Found) and whether svc.doc/open fails.
// ODIN_TEST_THREADS=1 keeps the suite serial; the handler's writes are read
// only after the reply that follows them was observed.
Relayhost_Daemon :: struct {
	start_calls:      int,
	start_ok:         bool,
	start_references: bool,
	doc_open_calls:   int,
	doc_open_fail:    bool,
}

relayhost_daemon_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	d := cast(^Relayhost_Daemon)conn.host
	switch env.method {
	case svc.METHOD_LANGSERVER_START:
		d.start_calls += 1
		if !d.start_ok {
			return {is_error = true, err_code = .Method_Not_Found, err_message = "no language server configured for this language"}, .Respond
		}
		// JSON through concatenation, never through fmt's format string —
		// fmt treats '{' as a parameter brace and eats the literal.
		body := strings.concatenate(
			{
				`{"references":`,
				d.start_references ? "true" : "false",
				"}",
			},
			arena,
		)
		v, perr := json.parse_string(body, spec = .JSON, parse_integers = true, allocator = arena)
		if perr != nil {
			return {is_error = true, err_code = .Internal_Error, err_message = "preset did not parse"}, .Respond
		}
		return {result = v}, .Respond
	case svc.METHOD_DOC_OPEN:
		d.doc_open_calls += 1
		if d.doc_open_fail {
			return {is_error = true, err_code = .Invalid_Params, err_message = "refused"}, .Respond
		}
		v, _ := json.parse_string(`{}`, spec = .JSON, allocator = arena)
		return {result = v}, .Respond
	case:
	}
	return {is_error = true, err_code = .Method_Not_Found, err_message = "unknown svc method"}, .Respond
}

// Svc_Rig is the shared host-half core for the suites that drive a real
// session host against a channel-pair fake daemon: the session App over a
// temp project root, both halves of the rpc.channel_pair with their reader
// threads (so conn_call round trips complete), the parent link, and the
// LSP host. The daemon's svc handlers are the seam: register_svc points
// the daemon conn's dispatch host at daemon_host and registers them.
Svc_Rig :: struct {
	app:   ^session.App,
	root:  ^platform.Cancel_Token,
	clock: ^platform.Clock,

	daemon_conn:   ^jsonrpc.Conn,
	child_conn:    ^jsonrpc.Conn,
	e_daemon:      ^rpc.Chan_Endpoint,
	e_child:       ^rpc.Chan_Endpoint,
	daemon_reader: ^thread.Thread,
	child_reader:  ^thread.Thread,
	daemon_box:    ^Conn_Box,
	child_box:     ^Conn_Box,

	host: ^session.Lsp_Host,
	tmp:  string, // the project root (owned clone)
}

// svcrig_file_uri spells one document uri through the product's single
// encoder — hand-splicing "file://" onto a platform path builds uris no
// client sends (Windows drive letters and backslashes both miss), and the
// encoder keeps the decode round trip exact on every platform.
svcrig_file_uri :: proc(root: string, name: string) -> string {
	path := strings.concatenate({root, "/", name}, context.temp_allocator)
	return symbol.file_uri(path, context.temp_allocator)
}

// svc_rig_init builds the core in the real session's order: temp root,
// token and clock, the App, the channel pair, the daemon conn (dispatch
// host and handlers before its reader thread starts), the child conn and
// reader, the parent link, the LSP host. On failure the rig is unwound and
// false returned — the caller frees only its own record.
svc_rig_init :: proc(t: ^testing.T, r: ^Svc_Rig, daemon_host: rawptr, register_svc: proc(conn: ^jsonrpc.Conn, daemon_host: rawptr)) -> bool {
	tmp, terr := os.make_directory_temp("", "aubade-lsprelay-", context.allocator)
	testing.expectf(t, terr == nil, "temp dir failed: %v", terr)
	if terr != nil {
		return false
	}
	r.tmp = tmp

	r.root = new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(r.root)
	r.clock = new(platform.Clock, context.allocator)
	platform.clock_init(r.clock, false)

	r.app = new(session.App, context.allocator)
	r.app^ = {
		cfg          = {project_root = strings.clone(tmp, context.allocator)},
		root         = r.root,
		clock        = r.clock,
		allocator    = context.allocator,
		cancel_alloc = context.allocator,
	}
	r.app.calls = make(map[string]^session.Call_Entry, 8, context.allocator)

	// The channel-pair fake daemon (the svc_test retry-pair shape): both
	// conns get reader threads, so conn_call round trips complete.
	r.e_daemon, r.e_child = rpc.channel_pair(context.allocator)
	testing.expectf(t, r.e_daemon != nil, "channel_pair failed")
	if r.e_daemon == nil {
		svc_rig_teardown_early(r)
		return false
	}
	r.daemon_conn = new(jsonrpc.Conn, context.allocator)
	jsonrpc.conn_init(r.daemon_conn, rpc.to_reader(&r.e_daemon.stream, jsonrpc.RPC_MAX_FRAME), rpc.to_writer(&r.e_daemon.stream), context.allocator)
	register_svc(r.daemon_conn, daemon_host)
	r.daemon_box = new(Conn_Box, context.allocator)
	r.daemon_box^ = {conn = r.daemon_conn}
	r.daemon_reader = thread.create_and_start_with_poly_data(r.daemon_box, conn_reader_entry, self_cleanup = false)

	r.child_conn = new(jsonrpc.Conn, context.allocator)
	jsonrpc.conn_init(r.child_conn, rpc.to_reader(&r.e_child.stream, jsonrpc.RPC_MAX_FRAME), rpc.to_writer(&r.e_child.stream), context.allocator)
	r.child_box = new(Conn_Box, context.allocator)
	r.child_box^ = {conn = r.child_conn}
	r.child_reader = thread.create_and_start_with_poly_data(r.child_box, conn_reader_entry, self_cleanup = false)

	sync.mutex_lock(&r.app.parent_mu)
	r.app.parent = r.child_conn
	r.app.parent_state = .Live
	sync.mutex_unlock(&r.app.parent_mu)

	r.host = new(session.Lsp_Host, context.allocator)
	r.host^ = {app = r.app}
	return true
}

// svc_rig_teardown_early unwinds the rig before the channel pair exists
// (the init failure path).
svc_rig_teardown_early :: proc(r: ^Svc_Rig) {
	// token_destroy frees the token itself — no second free after it.
	platform.token_destroy(r.root, context.allocator)
	free(r.clock, context.allocator)
	delete(r.app.calls)
	delete(r.app.cfg.project_root, context.allocator)
	free(r.app, context.allocator)
	_ = os.remove_all(r.tmp)
	delete(r.tmp, context.allocator)
}

// svc_rig_destroy shuts the rig down: both conns are marked closed and
// both streams closed BEFORE the joins — each reader blocks on the peer's
// outgoing chan (the retry-pair shutdown ladder) — then the host and app
// state. release_host runs after the joins and before the host record is
// freed, for the suite's host-owned payloads (nil when there are none).
svc_rig_destroy :: proc(r: ^Svc_Rig, release_host: proc(host: ^session.Lsp_Host)) {
	jsonrpc.conn_close(r.daemon_conn)
	jsonrpc.conn_close(r.child_conn)
	r.e_daemon.stream.close(&r.e_daemon.stream)
	r.e_child.stream.close(&r.e_child.stream)
	thread.join(r.daemon_reader)
	free(r.daemon_reader, context.allocator)
	free(r.daemon_box, context.allocator)
	thread.join(r.child_reader)
	free(r.child_reader, context.allocator)
	free(r.child_box, context.allocator)
	rpc.channel_endpoint_destroy(r.e_daemon, context.allocator)
	rpc.channel_endpoint_destroy(r.e_child, context.allocator)
	jsonrpc.conn_destroy(r.daemon_conn)
	free(r.daemon_conn, context.allocator)
	jsonrpc.conn_destroy(r.child_conn)
	free(r.child_conn, context.allocator)

	// Host and app state.
	if release_host != nil {
		release_host(r.host)
	}
	free(r.host, context.allocator)
	delete(r.app.calls)
	delete(r.app.cfg.project_root, context.allocator)
	free(r.app, context.allocator)
	// token_destroy frees the token itself — no second free after it.
	platform.token_destroy(r.root, context.allocator)
	free(r.clock, context.allocator)
	_ = os.remove_all(r.tmp)
	delete(r.tmp, context.allocator)
}

Relayhost_Pair :: struct {
	using rig: Svc_Rig, // the shared host-half core (app, fake-daemon conns, LSP host)

	daemon_state: Relayhost_Daemon,

	up:     Pipe,
	down:   Pipe,
	send:   jsonrpc.Writer,
	recv:   jsonrpc.Reader,
	conn:   jsonrpc.Conn, // the editor conn (the face's)
	server: lspserver.Server,
}

// relayhost_register_svc points the daemon conn at the preset state and
// registers this suite's two fake svc handlers.
relayhost_register_svc :: proc(conn: ^jsonrpc.Conn, daemon_host: rawptr) {
	conn.host = daemon_host
	jsonrpc.conn_register(conn, svc.METHOD_LANGSERVER_START, relayhost_daemon_handler)
	jsonrpc.conn_register(conn, svc.METHOD_DOC_OPEN, relayhost_daemon_handler)
}

relayhost_pair_init :: proc(t: ^testing.T) -> ^Relayhost_Pair {
	p := new(Relayhost_Pair, context.allocator)
	if !svc_rig_init(t, &p.rig, &p.daemon_state, relayhost_register_svc) {
		free(p, context.allocator)
		return nil
	}
	p.host.relay = make(map[string]session.Relay_Lang, 4, context.allocator)

	// The LSP host and its face over the editor pipes.
	pipe_init(&p.up, context.allocator)
	pipe_init(&p.down, context.allocator)
	jsonrpc.writer_init(&p.send, pipe_write, &p.up)
	jsonrpc.reader_init(&p.recv, pipe_read, &p.down, 64 * 1024, context.allocator)
	jsonrpc.reader_init(&p.conn.reader, pipe_read, &p.up, 64 * 1024, context.allocator)
	jsonrpc.writer_init(&p.conn.writer, pipe_write, &p.down)
	jsonrpc.conn_init(&p.conn, p.conn.reader, p.conn.writer, context.allocator)

	p.server = {
		host            = p.host,
		name            = "aubade",
		version         = "test",
		initialize_host = session.host_lsp_initialize,
		doc_open        = session.host_lsp_doc_open,
		doc_change      = session.host_lsp_doc_change,
		doc_close       = session.host_lsp_doc_close,
		highlights      = session.host_lsp_highlights,
		diagnostics     = session.host_lsp_diagnostics,
		readiness       = session.host_lsp_readiness,
		relay           = session.host_lsp_relay,
		text_for_uri    = session.host_lsp_text_for_uri,
		log             = nil,
		allocator       = context.allocator,
	}
	lspserver.server_init(&p.server, &p.conn)
	p.host.server = &p.server

	// The link wiring in the real session's order: the host (and its
	// type-erased App.host_face) exists before any establishment runs the
	// wire hook, so the hook's handlers + host land on the child conn
	// exactly as connect_parent would leave them.
	p.app.host_face = p.host
	p.app.parent_mode = "lsp"
	session.lsp_wire_parent_conn(p.app, p.child_conn)
	return p
}

// relayhost_release_host frees the LSP host's per-language records (the
// map keys are owned clones).
relayhost_release_host :: proc(host: ^session.Lsp_Host) {
	for k in host.relay {
		delete(k, context.allocator)
	}
	delete(host.relay)
}

relayhost_pair_destroy :: proc(p: ^Relayhost_Pair) {
	// The face over the editor pipes.
	lspserver.server_destroy(&p.server)
	jsonrpc.conn_destroy(&p.conn)
	jsonrpc.reader_destroy(&p.recv)
	pipe_close(&p.up)
	pipe_close(&p.down)

	svc_rig_destroy(&p.rig, relayhost_release_host)
	free(p, context.allocator)
}

// relayhost_notify writes one notification frame and dispatches it.
relayhost_notify :: proc(t: ^testing.T, p: ^Relayhost_Pair, method: string, params_inner: string) {
	params := ""
	if params_inner != "" {
		params = strings.concatenate({`,"params":{`, params_inner, "}"}, context.temp_allocator)
	}
	body := strings.concatenate(
		{`{"jsonrpc":"2.0","method":"`, method, `"`, params, "}"},
		context.temp_allocator,
	)
	err := jsonrpc.write_frame(&p.send, json_bytes(body))
	testing.expectf(t, err == .None, "write_frame failed: %v", err)
	if err != .None {
		return
	}
	got, rerr := jsonrpc.read_frame(&p.conn.reader, context.temp_allocator)
	testing.expectf(t, rerr == .None, "read_frame from the up pipe failed: %v", rerr)
	if rerr != .None {
		return
	}
	keep := jsonrpc.conn_handle_body(&p.conn, got, context.temp_allocator)
	testing.expect(t, keep, "the face answered a framing-level rejection")
}

// relayhost_arm_face arms the face's lifecycle flags directly: the face
// handshake has its own suite (lspserver_face_test), and running the real
// initialize host here would bind a project root and load a config stack —
// machinery this file's host-half tests do not exercise. The negotiated
// encoding matches what the tests' client offers.
relayhost_arm_face :: proc(t: ^testing.T, p: ^Relayhost_Pair) {
	_ = t
	p.server.encoding = .Utf16
	p.server.is_initialized = true
}

// relayhost_open composes and dispatches one didOpen. The params JSON is
// built by concatenation — fmt's format string would eat the braces.
relayhost_open :: proc(t: ^testing.T, p: ^Relayhost_Pair, uri, language_id: string, version: i32, text: string) {
	params := strings.concatenate(
		{
			`"textDocument":{"uri":`,
			jsonutil.json_quote(uri, context.temp_allocator),
			`,"languageId":"`,
			language_id,
			`","version":`,
			fmt.aprintf("%d", version, allocator = context.temp_allocator),
			`,"text":`,
			jsonutil.json_quote(text, context.temp_allocator),
			"}",
		},
		context.temp_allocator,
	)
	relayhost_notify(t, p, lsp.METHOD_DID_OPEN, params)
}

// relayhost_push invokes a push handler the way the parent reader thread
// would: synchronously, with a bare conn whose host is the LSP host and a
// parsed notification envelope.
relayhost_push :: proc(t: ^testing.T, p: ^Relayhost_Pair, method: string, params_text: string, handler: jsonrpc.Notifier) {
	dummy := new(jsonrpc.Conn, context.allocator)
	dummy.host = p.host
	env := new(jsonrpc.Envelope, context.allocator)
	env.kind = .Notification
	env.method = method
	env.params_set = true
	v, perr := json.parse_string(params_text, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "push params did not parse: %s", params_text)
	if perr == nil {
		env.params = v
		handler(dummy, env, context.temp_allocator)
	}
	free(env, context.allocator)
	free(dummy, context.allocator)
}

// relayhost_run_pass runs the starter pass on ONE helper thread (the
// registration round trip parks the caller on the editor conn's reply
// slot), pumping and answering the request frames the pass produces.
Relayhost_Pass_Args :: struct {
	h:    ^session.Lsp_Host,
	done: chan.Chan(bool),
}

relayhost_pass_entry :: proc(args: ^Relayhost_Pass_Args) {
	session.lsp_relay_pass(args.h)
	chan.send(chan.as_send(args.done), true)
}

relayhost_run_pass :: proc(t: ^testing.T, p: ^Relayhost_Pair, check: proc(t: ^testing.T, body: string)) -> bool {
	args := new(Relayhost_Pass_Args, context.allocator)
	args.h = p.host
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expect(t, derr == nil, "chan create failed")
	if derr != nil {
		free(args, context.allocator)
		return false
	}
	args.done = done
	th := thread.create_and_start_with_poly_data(args, relayhost_pass_entry, self_cleanup = false)
	completed := false
	pump: for i := 0; i < 2_000_000; i += 1 {
		if ok, has := chan.try_recv(chan.as_recv(args.done)); has {
			completed = ok
			break pump
		}
		if len(p.down.buf) > 0 {
			frame, rerr := jsonrpc.read_frame(&p.recv, context.temp_allocator)
			testing.expectf(t, rerr == .None, "the registration frame read failed: %v", rerr)
			if rerr != .None {
				break pump
			}
			lsprelay_answer_host_frame(t, p, string(frame), check)
		}
	}
	chan.destroy(args.done)
	thread.join(th)
	free(th, context.allocator)
	free(args, context.allocator)
	return completed
}

// lsprelay_answer_host_frame is lsprelay_answer_request on the host pair.
lsprelay_answer_host_frame :: proc(t: ^testing.T, p: ^Relayhost_Pair, body: string, check: proc(t: ^testing.T, body: string)) {
	check(t, body)
	id := lsprelay_frame_id(t, body)
	reply := strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"result":null}`}, context.temp_allocator)
	werr := jsonrpc.write_frame(&p.send, json_bytes(reply))
	testing.expectf(t, werr == .None, "writing the reply frame failed: %v", werr)
	got, gerr := jsonrpc.read_frame(&p.conn.reader, context.temp_allocator)
	testing.expectf(t, gerr == .None, "reading the reply frame back failed: %v", gerr)
	if gerr == .None {
		jsonrpc.conn_handle_body(&p.conn, got, context.temp_allocator)
	}
}

// --- tests: the host half -----------------------------------------------------

@(test)
relayhost_push_diagnostics_republishes_and_drops_foreign :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	relayhost_arm_face(t, p)
	doc_uri := svcrig_file_uri(p.tmp, "main.go")
	relayhost_open(t, p, doc_uri, "go", 7, "package main\n")

	// A push for the open document republishes under the view's spelling
	// and version.
	items := `[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":7}},"severity":1,"message":"undeclared"}]`
	push_params := strings.concatenate(
		{`{"uri":`, jsonutil.json_quote(doc_uri, context.temp_allocator), `,"items":`, jsonutil.json_quote(items, context.temp_allocator), "}"},
		context.temp_allocator,
	)
	relayhost_push(t, p, svc.METHOD_PUSH_DIAGNOSTICS, push_params, session.handle_push_diagnostics)

	params := relayhost_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params) == doc_uri, "the republish must use the view's uri spelling")
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 7, "the republish must stamp the view's version, got %d", version)
	testing.expectf(t, lsppub_diag_count(t, params) == 1, "the pushed set republishes")
	testing.expectf(t, len(p.down.buf) == 0, "exactly one publish went out")

	// A foreign URI (outside the project root) drops silently.
	foreign_params := strings.concatenate(
		{`{"uri":"file:///elsewhere/x.go","items":`, jsonutil.json_quote(items, context.temp_allocator), "}"},
		context.temp_allocator,
	)
	relayhost_push(t, p, svc.METHOD_PUSH_DIAGNOSTICS, foreign_params, session.handle_push_diagnostics)
	testing.expectf(t, len(p.down.buf) == 0, "a foreign URI must not republish")

	// A project document the child does not hold open drops silently too.
	unopened := strings.concatenate(
		{
			`{"uri":`,
			jsonutil.json_quote(svcrig_file_uri(p.tmp, "other.go"), context.temp_allocator),
			`,"items":`,
			jsonutil.json_quote(items, context.temp_allocator),
			"}",
		},
		context.temp_allocator,
	)
	relayhost_push(t, p, svc.METHOD_PUSH_DIAGNOSTICS, unopened, session.handle_push_diagnostics)
	testing.expectf(t, len(p.down.buf) == 0, "an unopened document must not republish")
}

// The daemon pushes in its canonical spelling while the view holds the
// client's spelling through a symlinked directory — the view lookup must
// resolve the two spellings together (POSIX-only: making a symlink needs
// privileges on Windows).
when ODIN_OS == .Darwin || ODIN_OS == .Linux {

	@(test)
	relayhost_push_respells_canonical_to_client_spelling :: proc(t: ^testing.T) {
		p := relayhost_pair_init(t)
		if p == nil {
			return
		}
		defer relayhost_pair_destroy(p)

		real_dir := strings.concatenate({p.tmp, "/real"}, context.temp_allocator)
		if err := os.make_directory(real_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}); err != nil {
			testing.expectf(t, false, "mkdir failed: %v", err)
			return
		}
		link := strings.concatenate({p.tmp, "/link"}, context.temp_allocator)
		if err := os.symlink("real", link); err != nil {
			testing.expectf(t, false, "symlink failed: %v", err)
			return
		}
		// cfg.project_root is rig-owned and freed on the ambient allocator
		// at destroy; the swap keeps that ownership.
		delete(p.app.cfg.project_root, context.allocator)
		p.app.cfg.project_root = safety.pathguard_resolve_root(real_dir, context.allocator)

		relayhost_arm_face(t, p)
		doc_uri := svcrig_file_uri(link, "main.go")
		relayhost_open(t, p, doc_uri, "go", 3, "package main\n")

		canonical_main := strings.concatenate({p.app.cfg.project_root, "/main.go"}, context.temp_allocator)
		items := `[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":7}},"severity":1,"message":"undeclared"}]`
		push_params := strings.concatenate(
			{
				`{"uri":`,
				jsonutil.json_quote(symbol.file_uri(canonical_main, context.temp_allocator), context.temp_allocator),
				`,"items":`,
				jsonutil.json_quote(items, context.temp_allocator),
				"}",
			},
			context.temp_allocator,
		)
		relayhost_push(t, p, svc.METHOD_PUSH_DIAGNOSTICS, push_params, session.handle_push_diagnostics)

		params := relayhost_read_publish(t, p)
		testing.expectf(t, lsppub_uri(t, params) == doc_uri, "the republish must use the view's own spelling")
		version, has_version := lsppub_version(params)
		testing.expectf(t, has_version && version == 3, "the republish must stamp the view's version, got %d", version)
		testing.expectf(t, lsppub_diag_count(t, params) == 1, "the pushed set republishes")
	}

}

@(test)
relayhost_langserver_state_registers_capabilities :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	p.daemon_state.start_ok = true
	p.daemon_state.start_references = true
	relayhost_arm_face(t, p)
	doc_uri := svcrig_file_uri(p.tmp, "main.go")
	relayhost_open(t, p, doc_uri, "go", 1, "package main\n")

	// The didOpen armed the language; a running=true push makes it Ready
	// with its cap, and the starter pass registers references (the cap
	// bit) ahead of the ops faces.
	testing.expectf(t, len(p.host.relay) == 1 && p.host.relay["go"].state == .Pending, "the didOpen must arm the language Pending")
	relayhost_push(t, p, svc.METHOD_PUSH_LANGSERVER_STATE, `{"language":"go","running":true,"references":true}`, session.handle_push_langserver_state)
	testing.expect(t, p.host.relay["go"].state == .Ready, "the push must mark the language Ready")

	completed := relayhost_run_pass(t, p, proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, perr == nil, "frame did not parse: %s", body)
		if perr != nil {
			return
		}
		testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_REGISTER_CAPABILITY, "expected registerCapability, got %s", body)
		if params, ok := jsonutil.obj_get(v, "params"); ok {
			lsprelay_assert_registration(t, params, 0, "aubade.relay.go.references", lsp.METHOD_REFERENCES, "go")
			lsprelay_assert_registration(t, params, 1, "aubade.relay.go.formatting", lsp.METHOD_FORMATTING, "go")
		}
	})
	testing.expect(t, completed, "the starter pass must complete")
	testing.expect(t, p.host.relay["go"].is_registered, "the successful registration must latch is_registered")
	testing.expectf(t, len(p.down.buf) == 0, "exactly one registration request went out")

	// A quiet pass (nothing dirty) is a no-op: no frames, no start calls.
	starts_before := p.daemon_state.start_calls
	relayhost_run_pass(t, p, proc(t: ^testing.T, body: string) {
		testing.expectf(t, false, "a quiet pass must not send frames, got %s", body)
	})
	testing.expect(t, p.daemon_state.start_calls == starts_before, "a quiet pass must not start anything")
}

@(test)
relayhost_start_notfound_latches_noserver :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	p.daemon_state.start_ok = false // the daemon answers Method_Not_Found
	relayhost_arm_face(t, p)
	doc_uri := svcrig_file_uri(p.tmp, "main.rb")
	relayhost_open(t, p, doc_uri, "ruby", 1, "class A\nend\n")

	// The pass can run synchronously here: the start fails, so nothing
	// registers and nothing parks on the editor conn.
	session.lsp_relay_pass(p.host)

	testing.expect(t, p.host.relay["ruby"].state == .NoServer, "the NotFound start must latch NoServer")
	testing.expect(t, !p.host.relay["ruby"].is_registered, "a NoServer language must not register")
	testing.expectf(t, len(p.down.buf) == 0, "no registration may go out for a NoServer language")
	testing.expectf(t, p.daemon_state.start_calls == 1, "exactly one start attempt, got %d", p.daemon_state.start_calls)

	// Latched: the next pass neither retries the start nor re-registers.
	session.lsp_relay_pass(p.host)
	testing.expectf(t, p.daemon_state.start_calls == 1, "the NoServer latch must hold, got %d starts", p.daemon_state.start_calls)
	testing.expectf(t, len(p.down.buf) == 0, "the latch pass must stay silent")
}

@(test)
relayhost_running_false_unregisters :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	p.daemon_state.start_ok = true
	p.daemon_state.start_references = true
	relayhost_arm_face(t, p)
	doc_uri := svcrig_file_uri(p.tmp, "main.go")
	relayhost_open(t, p, doc_uri, "go", 1, "package main\n")

	relayhost_push(t, p, svc.METHOD_PUSH_LANGSERVER_STATE, `{"language":"go","running":true,"references":true}`, session.handle_push_langserver_state)
	completed := relayhost_run_pass(t, p, proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		if perr == nil {
			testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_REGISTER_CAPABILITY, "expected registerCapability, got %s", body)
		}
	})
	testing.expect(t, completed && p.host.relay["go"].is_registered, "the language must register first")

	// running=false: the starter withdraws the registrations on its next
	// pass and the record leaves is_registered.
	relayhost_push(t, p, svc.METHOD_PUSH_LANGSERVER_STATE, `{"language":"go","running":false}`, session.handle_push_langserver_state)
	testing.expect(t, p.host.relay["go"].state == .Failed, "running=false must move the record out of Ready")
	completed = relayhost_run_pass(t, p, proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		if perr != nil {
			return
		}
		testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_UNREGISTER_CAPABILITY, "expected unregisterCapability, got %s", body)
		if params, ok := jsonutil.obj_get(v, "params"); ok {
			if unregs, has := jsonutil.obj_get(params, "unregisterations"); has {
				items, _ := jsonutil.as_array(unregs)
				testing.expectf(t, len(items) == 5, "the withdrawal must mirror the full batch (the references relay + the four langserver faces), got %d", len(items))
			}
		}
	})
	testing.expect(t, completed, "the unregister pass must complete")
	testing.expect(t, !p.host.relay["go"].is_registered, "the record must leave is_registered")
}

@(test)
relayhost_doc_open_fail_records_no_language :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	p.daemon_state.doc_open_fail = true
	relayhost_arm_face(t, p)
	doc_uri := svcrig_file_uri(p.tmp, "main.go")
	relayhost_open(t, p, doc_uri, "go", 1, "package main\n")

	testing.expectf(t, p.daemon_state.doc_open_calls == 1, "the doc open must reach the daemon")
	testing.expectf(t, len(p.host.relay) == 0, "a failed open must record no language, got %d records", len(p.host.relay))
	// And the starter has nothing to drive.
	session.lsp_relay_pass(p.host)
	testing.expectf(t, p.daemon_state.start_calls == 0, "a failed open must not start anything")
}

@(test)
relayhost_wire_hook_registers_push_handlers :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	// The hook ran during init on the child conn: both push notifications
	// are registered and the conn's dispatch host is the LSP host.
	_, has_diag := p.child_conn.notifiers[svc.METHOD_PUSH_DIAGNOSTICS]
	_, has_state := p.child_conn.notifiers[svc.METHOD_PUSH_LANGSERVER_STATE]
	testing.expect(t, has_diag && has_state, "the wire hook must register both push handlers")
	testing.expectf(t, p.child_conn.host == p.host, "the child conn's host must be the LSP host")

	// A second establishment (reconnect) re-runs the hook on a fresh conn:
	// the handlers land there too — registration is per establishment. The
	// conn carries an allocator (a real establishment's conn always went
	// through conn_init); its maps are freed by hand because conn_destroy
	// expects an initialized reader/writer this bare conn never had. The
	// hook registers the push notifications AND the two-writer apply
	// request.
	fresh := new(jsonrpc.Conn, context.allocator)
	fresh^ = {allocator = context.allocator}
	session.lsp_wire_parent_conn(p.app, fresh)
	_, has_diag = fresh.notifiers[svc.METHOD_PUSH_DIAGNOSTICS]
	testing.expect(t, has_diag, "every establishment must carry the handlers")
	_, has_apply := fresh.handlers[svc.METHOD_EDIT_APPLY]
	testing.expect(t, has_apply, "every establishment must carry the apply request handler")
	for k in fresh.notifiers {
		delete(k, fresh.allocator)
	}
	delete(fresh.notifiers)
	for k in fresh.handlers {
		delete(k, fresh.allocator)
	}
	delete(fresh.handlers)
	free(fresh, context.allocator)
}

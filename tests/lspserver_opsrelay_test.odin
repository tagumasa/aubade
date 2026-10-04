// lspserver ops-relay tests: the six langserver-backed requests
// (formatting, code actions, inlay hints, prepare/incoming/outgoing call
// hierarchy) over the same synchronous pipe idiom as the face tests — the
// test writes real wire frames into a memory pipe, dispatches on the
// calling thread, and reads the reply back; a fake Ops_Host records what
// reached it and serves a scripted DTO answer. The host half drives the
// real session host_lsp_ops against a channel-pair fake daemon that
// records the svc request and serves the scripted answer, and the
// registration sweep test pins the four langserver faces riding the same
// registerCapability batch as the position relays.
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"

import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:safety"
import "src:session"
import "src:svc"

// --- the face-side harness ---------------------------------------------------

Opsface_Text :: struct {
	uri:  string, // owned clones
	text: string,
}

// Opsface_Rec records one Ops_Host invocation.
Opsface_Rec :: struct {
	kind:          lspserver.Ops_Kind,
	uri:           string, // owned clone
	start_line:    int,
	start_col:     int,
	end_line:      int,
	end_col:       int,
	tab_size:      int,
	insert_spaces: bool,
	incoming:      bool,
}

// Opsface_Host is the fake host: the ops callback records the request and
// serves the scripted answer (a borrowed test literal, parsed into the
// request arena per call); the text callback serves its per-uri presets;
// the log callback collects the face's notes. Everything runs on the test
// thread (the synchronous harness dispatches frames inline).
Opsface_Host :: struct {
	allocator:   mem.Allocator,
	calls:       [dynamic]Opsface_Rec,
	answer:      string, // borrowed test literal
	failed:      bool,
	err_message: string,
	texts:       [dynamic]Opsface_Text,
	text_calls:  int,
	logs:        [dynamic]string, // owned clones
}

opsface_host_init :: proc(h: ^Opsface_Host, a: mem.Allocator) {
	h^ = {
		allocator = a,
		calls     = make([dynamic]Opsface_Rec, 0, 4, a),
		texts     = make([dynamic]Opsface_Text, 0, 4, a),
		logs      = make([dynamic]string, 0, 4, a),
	}
}

opsface_host_destroy :: proc(h: ^Opsface_Host) {
	for c in h.calls {
		delete(c.uri, h.allocator)
	}
	delete(h.calls)
	for t in h.texts {
		delete(t.uri, h.allocator)
		delete(t.text, h.allocator)
	}
	delete(h.texts)
	for l in h.logs {
		delete(l, h.allocator)
	}
	delete(h.logs)
	// answer / err_message are test-assigned literals: borrowed, never
	// owned — nothing to free.
	h^ = {}
}

opsface_set_text :: proc(h: ^Opsface_Host, uri, text: string) {
	append(&h.texts, Opsface_Text{uri = strings.clone(uri, h.allocator), text = strings.clone(text, h.allocator)})
}

opsface_ops_cb :: proc(host: rawptr, req: lspserver.Ops_Request, arena: mem.Allocator) -> lspserver.Ops_Result {
	h := cast(^Opsface_Host)host
	append(&h.calls, Opsface_Rec{
		kind          = req.kind,
		uri           = strings.clone(req.uri, h.allocator),
		start_line    = req.start_line,
		start_col     = req.start_col,
		end_line      = req.end_line,
		end_col       = req.end_col,
		tab_size      = req.tab_size,
		insert_spaces = req.insert_spaces,
		incoming      = req.incoming,
	})
	r: lspserver.Ops_Result
	r.failed = h.failed
	if h.err_message != "" {
		r.err_message = strings.clone(h.err_message, arena)
	}
	if h.answer != "" {
		if v, perr := json.parse_string(h.answer, spec = .JSON, parse_integers = true, allocator = arena); perr == nil {
			r.items = v
		}
	}
	return r
}

opsface_text_cb :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (text: string, ok: bool) {
	h := cast(^Opsface_Host)host
	_ = arena
	h.text_calls += 1
	for t in h.texts {
		if t.uri == uri {
			return t.text, true
		}
	}
	return "", false
}

opsface_log_cb :: proc(host: rawptr, message: string) {
	h := cast(^Opsface_Host)host
	append(&h.logs, strings.clone(message, h.allocator))
}

// Opsrelay_Pair is the synchronous face harness (the shared lspface pair
// plumbing over the ops host): the server conn reads the up pipe and
// writes the down pipe; the test plays the client.
Opsrelay_Pair :: struct {
	up:     Pipe,
	down:   Pipe,
	send:   jsonrpc.Writer,
	recv:   jsonrpc.Reader,
	conn:   jsonrpc.Conn,
	server: lspserver.Server,
	host:   Opsface_Host,
}

// opsface_finish_host initializes the ops host and builds its server value
// (the ops/text/log callback set) over it.
opsface_finish_host :: proc(host, pair: rawptr, a: mem.Allocator) -> lspserver.Server {
	_ = pair
	h := cast(^Opsface_Host)host
	opsface_host_init(h, a)
	return {
		host         = host,
		name         = "aubade",
		version      = "test",
		text_for_uri = opsface_text_cb,
		ops          = opsface_ops_cb,
		log          = opsface_log_cb,
		allocator    = a,
	}
}

opsface_free_host :: proc(host: rawptr) {
	opsface_host_destroy(cast(^Opsface_Host)host)
}

opsrelay_pair_init :: proc(t: ^testing.T) -> ^Opsrelay_Pair {
	_ = t
	return lspface_pair_open(Opsrelay_Pair, opsface_finish_host)
}

opsrelay_pair_destroy :: proc(p: ^Opsrelay_Pair) {
	lspface_pair_close(p, opsface_free_host)
}

opsrelay_initialize :: proc(t: ^testing.T, p: ^Opsrelay_Pair, encodings_json: string) {
	params := ""
	if encodings_json != "" {
		params = strings.concatenate(
			{`"capabilities":{"general":{"positionEncodings":`, encodings_json, "}}"},
			context.temp_allocator,
		)
	}
	body := lspface_request(t, p, "1", lsp.METHOD_INITIALIZE, params)
	testing.expect(t, body != "", "initialize produced no reply")
	testing.expectf(t, lspface_reply_code(t, body) == 0, "initialize answered an error: %s", body)
}

// opsrelay_result_array digs the result array out of a reply body.
opsrelay_result_array :: proc(t: ^testing.T, body: string) -> []json.Value {
	testing.expectf(t, body != "", "the request produced no reply")
	if body == "" {
		return nil
	}
	testing.expectf(t, lspface_reply_code(t, body) == 0, "the request answered an error: %s", body)
	v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "the reply did not parse: %s", body)
	if perr != nil {
		return nil
	}
	result, ok := jsonutil.obj_get(v, "result")
	testing.expect(t, ok, "the reply carries no result")
	if !ok {
		return nil
	}
	items, is_arr := jsonutil.as_array(result)
	testing.expect(t, is_arr, "the reply result is not an array")
	return items
}

// opsrelay_range_at reads one item's named member as a wire Range.
opsrelay_range_at :: proc(t: ^testing.T, item: json.Value, member: string) -> (sl, sc, el, ec: i64) {
	rng, ok := jsonutil.obj_get(item, member)
	testing.expectf(t, ok, "the item carries no %s", member)
	if !ok {
		return
	}
	return opsrelay_range_value(t, rng)
}

// opsrelay_range_value reads a wire Range value's start/end positions.
opsrelay_range_value :: proc(t: ^testing.T, rng: json.Value) -> (sl, sc, el, ec: i64) {
	start, sok := jsonutil.obj_get(rng, "start")
	end, eok := jsonutil.obj_get(rng, "end")
	testing.expect(t, sok && eok, "the range carries start and end")
	if !sok || !eok {
		return
	}
	sl = jsonutil.obj_get_int(start, "line")
	sc = jsonutil.obj_get_int(start, "character")
	el = jsonutil.obj_get_int(end, "line")
	ec = jsonutil.obj_get_int(end, "character")
	return
}

// --- tests: formatting ---------------------------------------------------------

@(test)
opsrelay_formatting_roundtrip_utf16 :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	opsrelay_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	p.host.answer = `[{"new_text":"package main\n","start_line":0,"start_col":0,"end_line":0,"end_col":12}]`

	body := lspface_request(t, p, "2", lsp.METHOD_FORMATTING, `"textDocument":{"uri":"file:///w/prog.go"},"options":{"tabSize":8,"insertSpaces":false}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "formatting must answer one edit, got %d", len(items))
	if len(items) == 1 {
		sl, sc, el, ec := opsrelay_range_at(t, items[0], "range")
		testing.expectf(t, sl == 0 && sc == 0 && el == 0 && ec == 12, "utf-16 columns pass through, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		testing.expectf(t, opsrelay_member_str(items[0], "newText") == "package main\n", "newText carries the DTO's new_text")
	}
	testing.expectf(t, len(p.host.calls) == 1, "the host must see one call")
	if len(p.host.calls) == 1 {
		r := p.host.calls[0]
		testing.expectf(t, r.kind == .Formatting && r.uri == "file:///w/prog.go", "the host must see the formatting request")
		testing.expectf(t, r.tab_size == 8 && !r.insert_spaces, "the options must reach the host as sent, got (%d,%v)", r.tab_size, r.insert_spaces)
	}
	testing.expect(t, p.host.text_calls == 0, "a utf-16 connection needs no text service")
}

@(test)
opsrelay_formatting_utf8_converts_with_defaults :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	// utf-8 connection, open document: the conversion truth is the view's
	// snapshot (no text preset exists — an empty answer would mean the face
	// skipped it). "α βγ": utf-16 col 1 is byte 2 (' '), col 3 is byte 5
	// (γ's start). No options member: the specification's defaults (4,
	// true) reach the host.
	opsrelay_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":1,"text":"α βγ\n"}`)
	p.host.answer = `[{"new_text":"α βγ","start_line":0,"start_col":1,"end_line":0,"end_col":3}]`

	body := lspface_request(t, p, "2", lsp.METHOD_FORMATTING, `"textDocument":{"uri":"file:///w/prog.thing"}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "formatting must answer one edit, got %d", len(items))
	if len(items) == 1 {
		sl, sc, el, ec := opsrelay_range_at(t, items[0], "range")
		testing.expectf(t, sl == 0 && sc == 2 && el == 0 && ec == 5, "utf-16 columns must convert to bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
	if len(p.host.calls) == 1 {
		r := p.host.calls[0]
		testing.expectf(t, r.tab_size == 4 && r.insert_spaces, "the specification's default options must reach the host, got (%d,%v)", r.tab_size, r.insert_spaces)
	}
	testing.expect(t, p.host.text_calls == 0, "an open document converts through its view snapshot, not a fetch")
}

// --- tests: inbound position conversion -----------------------------------------

@(test)
opsrelay_inbound_positions_convert_utf8 :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	// utf-8 connection: the wire columns are byte columns and must reach
	// the host as the UTF-16 columns the svc face speaks. Line 0 is
	// `x := "héllo"` — bytes x[0] ' '[1] ':'[2] '='[3] ' '[4] '"'[5] h[6]
	// é[7,8] l[9] l[10] o[11] '"'[12]; byte 12 (the closing quote) is
	// utf-16 11 and byte 9 (the l after the rune) is utf-16 8.
	opsrelay_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":1,"text":"x := \"héllo\"\ny := 1\n"}`)
	p.host.answer = `[]`

	// The codeAction range converts both endpoints.
	body := lspface_request(t, p, "2", lsp.METHOD_CODE_ACTION, `"textDocument":{"uri":"file:///w/prog.thing"},"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":12}}`)
	opsrelay_result_array(t, body)
	testing.expectf(t, len(p.host.calls) == 1, "the host must see one call, got %d", len(p.host.calls))
	if len(p.host.calls) == 1 {
		r := p.host.calls[0]
		testing.expectf(t, r.kind == .Code_Actions, "the host must see the code action request")
		testing.expectf(t, r.start_line == 0 && r.start_col == 6 && r.end_line == 0 && r.end_col == 11, "the range's byte columns must reach the host as UTF-16, got (%d,%d)-(%d,%d)", r.start_line, r.start_col, r.end_line, r.end_col)
	}

	// prepareCallHierarchy's position converts.
	body = lspface_request(t, p, "3", lsp.METHOD_PREPARE_CALL_HIERARCHY, `"textDocument":{"uri":"file:///w/prog.thing"},"position":{"line":0,"character":9}`)
	opsrelay_result_array(t, body)
	testing.expectf(t, len(p.host.calls) == 2, "the host must see two calls, got %d", len(p.host.calls))
	if len(p.host.calls) == 2 {
		r := p.host.calls[1]
		testing.expectf(t, r.kind == .Prepare_Call_Hierarchy && r.start_line == 0 && r.start_col == 8, "the position's byte column must reach the host as UTF-16, got (%d,%d)", r.start_line, r.start_col)
	}

	// The call-edges item's selectionRange start converts the same way.
	body = lspface_request(t, p, "4", lsp.METHOD_INCOMING_CALLS, `"item":{"uri":"file:///w/prog.thing","name":"f","kind":12,` +
		`"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},` +
		`"selectionRange":{"start":{"line":0,"character":9},"end":{"line":0,"character":10}}}`)
	opsrelay_result_array(t, body)
	testing.expectf(t, len(p.host.calls) == 3, "the host must see three calls, got %d", len(p.host.calls))
	if len(p.host.calls) == 3 {
		r := p.host.calls[2]
		testing.expectf(t, r.kind == .Call_Edges && r.incoming, "the host must see the incoming edges request")
		testing.expectf(t, r.start_line == 0 && r.start_col == 8, "the selection start's byte column must reach the host as UTF-16, got (%d,%d)", r.start_line, r.start_col)
	}
	testing.expect(t, p.host.text_calls == 0, "an open document converts through its view snapshot, not a fetch")
}

// --- tests: code actions --------------------------------------------------------

@(test)
opsrelay_code_actions_convert_and_drop_unserved :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	// utf-8 connection: each file's edit columns convert through that
	// file's own text; the unservable file's entry drops (logged once per
	// request) while the action and its other file survive. "fn  héllo":
	// utf-16 col 5 is byte 5, col 6 rounds past the rune to byte 7.
	opsrelay_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	opsface_set_text(&p.host, "file:///w/target.go", "fn  héllo\n")
	p.host.answer = `[{"title":"Fix","kind":"quickfix","is_preferred":true,` +
		`"command":{"title":"T","command":"c","arguments":[1,2]},` +
		`"edit":{"changes":{` +
		`"file:///w/target.go":[{"new_text":"x","start_line":0,"start_col":5,"end_line":0,"end_col":6}],` +
		`"file:///w/unserved.go":[{"new_text":"y","start_line":0,"start_col":0,"end_line":0,"end_col":1}]}}}]`

	body := lspface_request(t, p, "2", lsp.METHOD_CODE_ACTION, `"textDocument":{"uri":"file:///w/prog.go"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "the action must survive its file drop, got %d", len(items))
	if len(items) == 1 {
		a := items[0]
		testing.expectf(t, opsrelay_member_str(a, "title") == "Fix" && opsrelay_member_str(a, "kind") == "quickfix", "title and kind pass through")
		testing.expectf(t, jsonutil.obj_get_bool(a, "isPreferred"), "isPreferred renders from the DTO's is_preferred")
		if cmd, ok := jsonutil.obj_get(a, "command"); ok {
			testing.expectf(t, opsrelay_member_str(cmd, "title") == "T" && opsrelay_member_str(cmd, "command") == "c", "the command passes through")
			if args, has := jsonutil.obj_get(cmd, "arguments"); has {
				args_arr, is_arr := jsonutil.as_array(args)
				testing.expectf(t, is_arr && len(args_arr) == 2, "the raw arguments ride along, got %v", args)
			} else {
				testing.expect(t, false, "the command's arguments were dropped")
			}
		} else {
			testing.expect(t, false, "the command was dropped")
		}
		edit, has_edit := jsonutil.obj_get(a, "edit")
		testing.expect(t, has_edit, "the surviving file keeps the edit on the action")
		if has_edit {
			changes_v, changes_ok := jsonutil.obj_get(edit, "changes")
			testing.expect(t, changes_ok, "the wire edit carries changes")
			if changes_ok {
				changes, is_obj := jsonutil.as_object(changes_v)
				testing.expectf(t, is_obj && len(changes) == 1, "only the served file's entry survives, got %v", changes_v)
				if edits_v, found := changes["file:///w/target.go"]; found {
					edits, _ := jsonutil.as_array(edits_v)
					testing.expectf(t, len(edits) == 1, "the served file keeps its edit")
					if len(edits) == 1 {
						sl, sc, el, ec := opsrelay_range_at(t, edits[0], "range")
						testing.expectf(t, sl == 0 && sc == 5 && el == 0 && ec == 7, "the target file's columns must convert to bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
						testing.expectf(t, opsrelay_member_str(edits[0], "newText") == "x", "newText renders from new_text")
					}
				} else {
					testing.expect(t, false, "the served file's key vanished")
				}
			}
		}
	}
	testing.expectf(t, len(p.host.logs) == 1, "the unserved file's drop must log once per request, got %d", len(p.host.logs))
	// The open requested document converts through its view snapshot; the
	// text service sees each edited file exactly once — the served target
	// and the refused drop alike (servability is learned by asking).
	testing.expectf(t, p.host.text_calls == 2, "each edited file is fetched once, got %d", p.host.text_calls)
}

@(test)
opsrelay_code_actions_utf16_passthrough :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	opsrelay_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	p.host.answer = `[{"title":"A","edit":{"changes":{"file:///w/other.go":[{"new_text":"z","start_line":1,"start_col":2,"end_line":1,"end_col":4}]}}}]`

	body := lspface_request(t, p, "2", lsp.METHOD_CODE_ACTION, `"textDocument":{"uri":"file:///w/prog.go"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "one action answers, got %d", len(items))
	if len(items) == 1 {
		edit, has := jsonutil.obj_get(items[0], "edit")
		testing.expect(t, has, "the edit passes through")
		if has {
			changes, changes_ok := jsonutil.obj_get(edit, "changes")
			testing.expect(t, changes_ok, "changes ride the edit")
			if changes_ok {
				co, is_obj := jsonutil.as_object(changes)
				testing.expect(t, is_obj && len(co) == 1, "one file's entry")
				if edits_v, found := co["file:///w/other.go"]; found {
					edits, _ := jsonutil.as_array(edits_v)
					if len(edits) == 1 {
						sl, sc, el, ec := opsrelay_range_at(t, edits[0], "range")
						testing.expectf(t, sl == 1 && sc == 2 && el == 1 && ec == 4, "utf-16 columns pass through unchanged, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
					}
				} else {
					testing.expect(t, false, "the uri key must pass through verbatim")
				}
			}
		}
	}
	testing.expect(t, p.host.text_calls == 0, "a utf-16 connection needs no text service")
	testing.expectf(t, len(p.host.logs) == 0, "nothing drops, nothing logs")
}

// --- tests: inlay hints ---------------------------------------------------------

@(test)
opsrelay_inlay_hints_kinds_and_utf8 :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	// utf-8 connection. Line 0 of the view text `x := "héllo"`: utf-16
	// col 11 (the closing quote) is byte 12. The kind names recover to the
	// specification's InlayHintKind numbers; an unknown name omits the
	// member.
	opsrelay_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":1,"text":"x := \"héllo\"\ny := 1\n"}`)
	p.host.answer = `[` +
		`{"position":{"line":0,"column":11},"label":"i32","kind":"type","tooltip":"the int","padding_left":true},` +
		`{"position":{"line":1,"column":0},"label":"x","kind":"parameter","padding_right":true},` +
		`{"position":{"line":1,"column":5},"label":"y","kind":"bogus"}]`

	body := lspface_request(t, p, "2", lsp.METHOD_INLAY_HINT, `"textDocument":{"uri":"file:///w/prog.thing"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 3, "every servable hint renders, got %d", len(items))
	if len(items) == 3 {
		pos, has_pos := jsonutil.obj_get(items[0], "position")
		testing.expect(t, has_pos, "the hint carries a position")
		if has_pos {
			testing.expectf(t, jsonutil.obj_get_int(pos, "line") == 0 && jsonutil.obj_get_int(pos, "character") == 12, "the position must convert to bytes, got (%d,%d)", jsonutil.obj_get_int(pos, "line"), jsonutil.obj_get_int(pos, "character"))
		}
		testing.expectf(t, opsrelay_member_str(items[0], "label") == "i32", "the label passes through")
		testing.expectf(t, jsonutil.obj_get_int(items[0], "kind") == 1, "the type kind renders as 1, got %d", jsonutil.obj_get_int(items[0], "kind"))
		testing.expectf(t, opsrelay_member_str(items[0], "tooltip") == "the int", "the tooltip passes through")
		testing.expectf(t, jsonutil.obj_get_bool(items[0], "paddingLeft"), "padding_left renders as paddingLeft")
		_, has_pad_right := jsonutil.obj_get(items[0], "paddingRight")
		testing.expect(t, !has_pad_right, "an absent padding stays absent")

		testing.expectf(t, jsonutil.obj_get_int(items[1], "kind") == 2, "the parameter kind renders as 2, got %d", jsonutil.obj_get_int(items[1], "kind"))
		testing.expectf(t, jsonutil.obj_get_bool(items[1], "paddingRight"), "padding_right renders as paddingRight")

		_, has_kind := jsonutil.obj_get(items[2], "kind")
		testing.expect(t, !has_kind, "an unknown kind name omits the member")
	}
}

// --- tests: call hierarchy -------------------------------------------------------

@(test)
opsrelay_prepare_item_shape :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	opsrelay_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	p.host.answer = `[{"name":"main","kind":12,"uri":"file:///w/prog.go",` +
		`"range":{"start_line":0,"start_col":0,"end_line":3,"end_col":1},` +
		`"selection_range":{"start_line":2,"start_col":4,"end_line":2,"end_col":8}}]`

	body := lspface_request(t, p, "2", lsp.METHOD_PREPARE_CALL_HIERARCHY, `"textDocument":{"uri":"file:///w/prog.go"},"position":{"line":2,"character":5}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "prepare must answer one item, got %d", len(items))
	if len(items) == 1 {
		item := items[0]
		testing.expectf(t, opsrelay_member_str(item, "name") == "main", "the name passes through")
		testing.expectf(t, jsonutil.obj_get_int(item, "kind") == 12, "the kind rides as its number")
		testing.expectf(t, opsrelay_member_str(item, "uri") == "file:///w/prog.go", "the uri passes through")
		sl, sc, el, ec := opsrelay_range_at(t, item, "range")
		testing.expectf(t, sl == 0 && sc == 0 && el == 3 && ec == 1, "range renders start/end, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		sl, sc, el, ec = opsrelay_range_at(t, item, "selectionRange")
		testing.expectf(t, sl == 2 && sc == 4 && el == 2 && ec == 8, "selectionRange renders from selection_range, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
	if len(p.host.calls) == 1 {
		r := p.host.calls[0]
		testing.expectf(t, r.kind == .Prepare_Call_Hierarchy && r.start_line == 2 && r.start_col == 5, "the host must see the request position")
	}
}

@(test)
opsrelay_edges_shapes_and_point :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	opsrelay_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	p.host.answer = `[{"name":"caller","kind":12,"uri":"file:///w/caller.go",` +
		`"range":{"start_line":0,"start_col":0,"end_line":0,"end_col":0},` +
		`"selection_range":{"start_line":1,"start_col":2,"end_line":1,"end_col":8},` +
		`"from_ranges":[{"start_line":3,"start_col":4,"end_line":3,"end_col":9}]}]`

	item_params := `"item":{"uri":"file:///w/prepared.go","name":"callee","kind":12,` +
		`"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":1}},` +
		`"selectionRange":{"start":{"line":5,"character":6},"end":{"line":5,"character":12}}}`

	body := lspface_request(t, p, "2", lsp.METHOD_INCOMING_CALLS, item_params)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "incoming calls must answer one call, got %d", len(items))
	if len(items) == 1 {
		from, has_from := jsonutil.obj_get(items[0], "from")
		testing.expect(t, has_from, "an incoming call carries from")
		if has_from {
			testing.expectf(t, opsrelay_member_str(from, "name") == "caller", "the from item renders the CallHierarchyItem")
		}
		ranges, has_ranges := jsonutil.obj_get(items[0], "fromRanges")
		testing.expect(t, has_ranges, "an incoming call carries fromRanges")
		if has_ranges {
			fr, is_arr := jsonutil.as_array(ranges)
			testing.expectf(t, is_arr && len(fr) == 1, "one call-site range, got %v", ranges)
			if is_arr && len(fr) == 1 {
				sl, sc, el, ec := opsrelay_range_value(t, fr[0])
				testing.expectf(t, sl == 3 && sc == 4 && el == 3 && ec == 9, "the call-site range passes through, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
			}
		}
	}
	if len(p.host.calls) == 1 {
		r := p.host.calls[0]
		testing.expectf(t, r.kind == .Call_Edges && r.incoming, "incoming must reach the host as the incoming direction")
		testing.expectf(t, r.uri == "file:///w/prepared.go" && r.start_line == 5 && r.start_col == 6, "the point must recover from item.selectionRange.start, got (%s,%d,%d)", r.uri, r.start_line, r.start_col)
	}

	body2 := lspface_request(t, p, "3", lsp.METHOD_OUTGOING_CALLS, item_params)
	items2 := opsrelay_result_array(t, body2)
	testing.expectf(t, len(items2) == 1, "outgoing calls must answer one call, got %d", len(items2))
	if len(items2) == 1 {
		to, has_to := jsonutil.obj_get(items2[0], "to")
		testing.expect(t, has_to, "an outgoing call carries to")
		if has_to {
			testing.expectf(t, opsrelay_member_str(to, "name") == "caller", "the to item renders the CallHierarchyItem")
		}
	}
	if len(p.host.calls) == 2 {
		testing.expect(t, !p.host.calls[1].incoming, "outgoing must reach the host as the outgoing direction")
	}
}

@(test)
opsrelay_edges_utf8_drops_unserved_and_converts_ranges :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	// utf-8 connection, prepared document NOT open (the host's fetch
	// branch). The prepared document's text converts the outgoing
	// fromRanges (they are relative to the caller); each item's own ranges
	// convert through the item's file. The unservable item drops.
	opsrelay_initialize(t, p, `["utf-8"]`)
	opsface_set_text(&p.host, "file:///w/prepared.go", "αααααααααα\n") // utf-16 col k is byte 2k on line 0
	opsface_set_text(&p.host, "file:///w/callee.go", "bbbbbbbb\n")    // plain bytes
	p.host.answer = `[` +
		`{"name":"callee","kind":12,"uri":"file:///w/callee.go",` +
		`"range":{"start_line":0,"start_col":2,"end_line":0,"end_col":2},` +
		`"selection_range":{"start_line":0,"start_col":2,"end_line":0,"end_col":2},` +
		`"from_ranges":[{"start_line":0,"start_col":4,"end_line":0,"end_col":6}]},` +
		`{"name":"ghost","kind":12,"uri":"file:///w/missing.go",` +
		`"range":{"start_line":0,"start_col":0,"end_line":0,"end_col":0},` +
		`"selection_range":{"start_line":0,"start_col":0,"end_line":0,"end_col":0}}]`

	body := lspface_request(t, p, "2", lsp.METHOD_OUTGOING_CALLS, `"item":{"uri":"file:///w/prepared.go","selectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 1, "the unservable item must drop, got %d", len(items))
	if len(items) == 1 {
		to, has_to := jsonutil.obj_get(items[0], "to")
		testing.expect(t, has_to, "the surviving item carries to")
		if has_to {
			sl, sc, el, ec := opsrelay_range_at(t, to, "range")
			testing.expectf(t, sl == 0 && sc == 2 && el == 0 && ec == 2, "the item's own columns convert through its file, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		}
		ranges_v, has_ranges := jsonutil.obj_get(items[0], "fromRanges")
		testing.expect(t, has_ranges, "the surviving item carries fromRanges")
		if has_ranges {
			fr, _ := jsonutil.as_array(ranges_v)
			testing.expectf(t, len(fr) == 1, "one call-site range")
			if len(fr) == 1 {
				sl, sc, el, ec := opsrelay_range_value(t, fr[0])
				testing.expectf(t, sl == 0 && sc == 8 && el == 0 && ec == 12, "the call sites must convert through the prepared document's bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
			}
		}
	}
	testing.expectf(t, len(p.host.logs) == 1, "the per-item drop must log once per request, got %d", len(p.host.logs))
}

// --- tests: degradation and gates -------------------------------------------------

@(test)
opsrelay_failed_ops_answers_empty :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	opsrelay_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	p.host.failed = true
	p.host.err_message = "the daemon link is down"

	body := lspface_request(t, p, "2", lsp.METHOD_FORMATTING, `"textDocument":{"uri":"file:///w/prog.go"},"options":{"tabSize":4,"insertSpaces":true}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 0, "a failed op answers empty, got %d", len(items))
	testing.expectf(t, len(p.host.logs) == 1, "the failure must log once, got %d", len(p.host.logs))
	testing.expect(t, strings.contains(p.host.logs[0], "the daemon link is down"), "the log names the cause")
}

@(test)
opsrelay_nil_ops_host_answers_empty :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	p.server.ops = nil
	opsrelay_initialize(t, p, `["utf-16"]`)
	body := lspface_request(t, p, "2", lsp.METHOD_FORMATTING, `"textDocument":{"uri":"file:///w/prog.go"}`)
	items := opsrelay_result_array(t, body)
	testing.expectf(t, len(items) == 0, "a nil ops host answers empty, got %d", len(items))
	testing.expectf(t, len(p.host.calls) == 0, "a nil ops host must not be called")
	testing.expectf(t, len(p.host.logs) == 0, "a nil ops host is a normal state, not a refusal")
}

@(test)
opsrelay_invalid_params :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	opsrelay_initialize(t, p, `["utf-16"]`)

	body := lspface_request(t, p, "2", lsp.METHOD_FORMATTING, `"options":{"tabSize":4}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32602, "formatting without textDocument must answer Invalid_Params, got %s", body)

	body = lspface_request(t, p, "3", lsp.METHOD_CODE_ACTION, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32602, "codeAction without range must answer Invalid_Params, got %s", body)

	body = lspface_request(t, p, "4", lsp.METHOD_INLAY_HINT, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32602, "inlayHint without range must answer Invalid_Params, got %s", body)

	body = lspface_request(t, p, "5", lsp.METHOD_PREPARE_CALL_HIERARCHY, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32602, "prepare without position must answer Invalid_Params, got %s", body)

	body = lspface_request(t, p, "6", lsp.METHOD_INCOMING_CALLS, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32602, "incoming calls without item must answer Invalid_Params, got %s", body)

	body = lspface_request(t, p, "7", lsp.METHOD_OUTGOING_CALLS, `"item":{"uri":"file:///w/x.go"}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32602, "an item without selectionRange must answer Invalid_Params, got %s", body)

	testing.expectf(t, len(p.host.calls) == 0, "malformed params must not reach the host")
}

@(test)
opsrelay_request_before_initialize_refused :: proc(t: ^testing.T) {
	p := opsrelay_pair_init(t)
	defer opsrelay_pair_destroy(p)

	body := lspface_request(t, p, "1", lsp.METHOD_FORMATTING, `"textDocument":{"uri":"file:///w/x.go"}`)
	testing.expect(t, body != "", "the request must be answered")
	testing.expectf(t, lspface_reply_code(t, body) == -32002, "expected -32002 before initialize, got %s", body)
}

opsrelay_member_str :: proc(v: json.Value, key: string) -> string {
	if m, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.value_str(m)
	}
	return ""
}

// --- the host-level harness: a real Lsp_Host against a fake daemon ---------

// Opsvc_Call records one svc request the fake daemon saw (strings cloned
// into the state's allocator — the handler runs on the reader thread and
// the reads happen after the reply was observed).
Opsvc_Call :: struct {
	method:        string, // owned clone
	rel:           string, // owned clone
	tab_size:      int,
	insert_spaces: bool,
	sl:            int,
	sc:            int,
	el:            int,
	ec:            int,
	line:          int,
	col:           int,
	direction:     string, // owned clone
}

Opsvc_State :: struct {
	allocator: mem.Allocator,
	calls:     [dynamic]Opsvc_Call,
	answer:    string, // borrowed test literal: the full svc result JSON
}

opsvc_state_init :: proc(d: ^Opsvc_State, a: mem.Allocator) {
	d^ = {
		allocator = a,
		calls     = make([dynamic]Opsvc_Call, 0, 4, a),
	}
}

opsvc_state_destroy :: proc(d: ^Opsvc_State) {
	for c in d.calls {
		delete(c.method, d.allocator)
		if c.rel != "" {
			delete(c.rel, d.allocator)
		}
		if c.direction != "" {
			delete(c.direction, d.allocator)
		}
	}
	delete(d.calls)
	d^ = {}
}

// opsvc_handler records the request and serves the scripted result. The
// per-method params extraction mirrors the svc client wrappers' shapes.
opsvc_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	d := cast(^Opsvc_State)conn.host
	_ = arena
	rec := Opsvc_Call{method = strings.clone(env.method, d.allocator)}
	rel := ""
	switch env.method {
	case svc.METHOD_LANGSERVER_FORMAT:
		rel = opsvc_param_str(env.params, "relative_path")
		rec.tab_size = int(jsonutil.obj_get_int(env.params, "tab_size"))
		rec.insert_spaces = jsonutil.obj_get_bool(env.params, "insert_spaces")
	case svc.METHOD_LANGSERVER_CODE_ACTIONS, svc.METHOD_LANGSERVER_INLAY_HINTS:
		rel = opsvc_param_str(env.params, "relative_path")
		rec.sl = int(jsonutil.obj_get_int(env.params, "start_line"))
		rec.sc = int(jsonutil.obj_get_int(env.params, "start_col"))
		rec.el = int(jsonutil.obj_get_int(env.params, "end_line"))
		rec.ec = int(jsonutil.obj_get_int(env.params, "end_col"))
	case svc.METHOD_LANGSERVER_CALL_HIERARCHY:
		rel = opsvc_param_str(env.params, "relative_path")
		rec.line = int(jsonutil.obj_get_int(env.params, "line"))
		rec.col = int(jsonutil.obj_get_int(env.params, "col"))
		rec.direction = strings.clone(opsvc_param_str(env.params, "direction"), d.allocator)
	case svc.METHOD_SYMBOL_LIST:
		rel = opsvc_param_str(env.params, "path")
	case:
	}
	if rel != "" {
		rec.rel = strings.clone(rel, d.allocator)
	}
	append(&d.calls, rec)

	if d.answer == "" {
		return {is_error = true, err_code = .Internal_Error, err_message = "no scripted answer"}, .Respond
	}
	v, perr := json.parse_string(d.answer, spec = .JSON, parse_integers = true, allocator = arena)
	if perr != nil {
		return {is_error = true, err_code = .Internal_Error, err_message = "the scripted answer did not parse"}, .Respond
	}
	return {result = v}, .Respond
}

opsvc_param_str :: proc(params: json.Value, key: string) -> string {
	if v, ok := jsonutil.obj_get(params, key); ok {
		return jsonutil.value_str(v)
	}
	return ""
}

// Opsvc_Pair is the host-half rig: a real Lsp_Host whose parent link is a
// channel pair into the fake daemon — the shared Svc_Rig core from
// lspserver_relay_test.odin, parameterized here by the five svc handlers
// the ops host drives. No editor face — the tests call
// session.host_lsp_ops directly.
Opsvc_Pair :: struct {
	using rig: Svc_Rig, // the shared core: App, fake-daemon conns and readers, LSP host
	state: Opsvc_State,
	srv:   ^lspserver.Server, // the empty view set uri re-spelling consults
}

// opsvc_register_svc points the daemon conn at the scripted state and
// registers the svc handlers the ops host drives.
opsvc_register_svc :: proc(conn: ^jsonrpc.Conn, daemon_host: rawptr) {
	conn.host = daemon_host
	jsonrpc.conn_register(conn, svc.METHOD_LANGSERVER_FORMAT, opsvc_handler)
	jsonrpc.conn_register(conn, svc.METHOD_LANGSERVER_CODE_ACTIONS, opsvc_handler)
	jsonrpc.conn_register(conn, svc.METHOD_LANGSERVER_INLAY_HINTS, opsvc_handler)
	jsonrpc.conn_register(conn, svc.METHOD_LANGSERVER_CALL_HIERARCHY, opsvc_handler)
	jsonrpc.conn_register(conn, svc.METHOD_SYMBOL_LIST, opsvc_handler)
}

opsvc_pair_init :: proc(t: ^testing.T) -> ^Opsvc_Pair {
	p := new(Opsvc_Pair, context.allocator)
	opsvc_state_init(&p.state, context.allocator)
	if !svc_rig_init(t, &p.rig, &p.state, opsvc_register_svc) {
		opsvc_state_destroy(&p.state)
		free(p, context.allocator)
		return nil
	}
	// The ops host re-spells answer uris through the open-view set; this rig
	// has no editor face, so the Server stays zero — a nil view map reads as
	// "no open views" and the canonical spelling answers.
	p.srv = new(lspserver.Server, context.allocator)
	p.host.server = p.srv
	return p
}

opsvc_pair_destroy :: proc(p: ^Opsvc_Pair) {
	// The rig's ladder joins the reader threads before anything they can
	// touch (the daemon handler records into state) is released.
	svc_rig_destroy(&p.rig, nil)
	opsvc_state_destroy(&p.state)
	free(p.srv, context.allocator)
	free(p, context.allocator)
}

// opsvc_arena hands the tests one request arena per call site.
opsvc_arena :: proc(a: ^mem.Dynamic_Arena) -> mem.Allocator {
	mem.dynamic_arena_init(a, context.allocator)
	return mem.dynamic_arena_allocator(a)
}

// opsvc_canonical_uri builds one expected answer uri through the same
// root canonicalizer the host applies: answers for documents outside
// the open-view set carry the symlink-resolved spelling, which differs
// from the rig's raw temp spelling on macOS (/var -> /private/var).
opsvc_canonical_uri :: proc(p: ^Opsvc_Pair, name: string) -> string {
	root := safety.pathguard_resolve_root(p.tmp, context.temp_allocator)
	return strings.concatenate({"file://", root, "/", name}, context.temp_allocator)
}

// --- tests: the host half -----------------------------------------------------

@(test)
opsvc_format_roundtrip :: proc(t: ^testing.T) {
	p := opsvc_pair_init(t)
	if p == nil {
		return
	}
	defer opsvc_pair_destroy(p)
	p.state.answer = `{"items":[{"new_text":"x","start_line":0,"start_col":0,"end_line":0,"end_col":1}]}`

	arena: mem.Dynamic_Arena
	a := opsvc_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc_uri := strings.concatenate({"file://", p.tmp, "/main.go"}, context.temp_allocator)
	req := lspserver.Ops_Request{kind = .Formatting, uri = doc_uri, tab_size = 8, insert_spaces = false}
	res := session.host_lsp_ops(p.host, req, a)
	testing.expectf(t, !res.failed, "format must not fail: %s", res.err_message)
	testing.expect(t, len(p.state.calls) == 1, "one svc call must go out")
	if len(p.state.calls) == 1 {
		c := p.state.calls[0]
		testing.expectf(t, c.method == svc.METHOD_LANGSERVER_FORMAT, "expected %s, got %s", svc.METHOD_LANGSERVER_FORMAT, c.method)
		testing.expectf(t, c.rel == "main.go", "the rel path must reach the svc face, got %s", c.rel)
		testing.expectf(t, c.tab_size == 8 && !c.insert_spaces, "the options must ride the params, got (%d,%v)", c.tab_size, c.insert_spaces)
	}
	items, is_arr := jsonutil.as_array(res.items)
	testing.expectf(t, is_arr && len(items) == 1, "the DTO array passes through, got %v", res.items)
	if is_arr && len(items) == 1 {
		testing.expectf(t, opsrelay_member_str(items[0], "new_text") == "x", "the text-edit DTO passes through verbatim")
	}
}

@(test)
opsvc_code_actions_respell_uris :: proc(t: ^testing.T) {
	p := opsvc_pair_init(t)
	if p == nil {
		return
	}
	defer opsvc_pair_destroy(p)
	p.state.answer = `{"items":[{"title":"A","edit":{"changes":{"main.go":[{"new_text":"x","start_line":0,"start_col":0,"end_line":0,"end_col":1}]}}}]}`

	arena: mem.Dynamic_Arena
	a := opsvc_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc_uri := strings.concatenate({"file://", p.tmp, "/main.go"}, context.temp_allocator)
	req := lspserver.Ops_Request{kind = .Code_Actions, uri = doc_uri, start_line = 0, start_col = 1, end_line = 2, end_col = 3}
	res := session.host_lsp_ops(p.host, req, a)
	testing.expectf(t, !res.failed, "code actions must not fail: %s", res.err_message)
	if len(p.state.calls) == 1 {
		c := p.state.calls[0]
		testing.expectf(t, c.method == svc.METHOD_LANGSERVER_CODE_ACTIONS, "expected the code_actions face, got %s", c.method)
		testing.expectf(t, c.sl == 0 && c.sc == 1 && c.el == 2 && c.ec == 3, "the range must ride the params as UTF-16, got (%d,%d)-(%d,%d)", c.sl, c.sc, c.el, c.ec)
	}
	items, is_arr := jsonutil.as_array(res.items)
	testing.expectf(t, is_arr && len(items) == 1, "one action answers, got %v", res.items)
	if is_arr && len(items) == 1 {
		edit_v, has_edit := jsonutil.obj_get(items[0], "edit")
		testing.expect(t, has_edit, "the edit survives")
		if has_edit {
			changes_v, changes_ok := jsonutil.obj_get(edit_v, "changes")
			testing.expect(t, changes_ok, "the changes map survives")
			if changes_ok {
				changes, _ := jsonutil.as_object(changes_v)
				want_uri := opsvc_canonical_uri(p, "main.go")
				_, found := changes[want_uri]
				testing.expectf(t, len(changes) == 1 && found, "the rel key must re-spell to the client uri, got %v", changes_v)
			}
		}
	}
}

@(test)
opsvc_inlay_hints_roundtrip :: proc(t: ^testing.T) {
	p := opsvc_pair_init(t)
	if p == nil {
		return
	}
	defer opsvc_pair_destroy(p)
	p.state.answer = `{"items":[{"position":{"line":1,"column":2},"label":"i32"}]}`

	arena: mem.Dynamic_Arena
	a := opsvc_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc_uri := strings.concatenate({"file://", p.tmp, "/main.go"}, context.temp_allocator)
	req := lspserver.Ops_Request{kind = .Inlay_Hints, uri = doc_uri, start_line = 0, start_col = 0, end_line = 9, end_col = 0}
	res := session.host_lsp_ops(p.host, req, a)
	testing.expectf(t, !res.failed, "inlay hints must not fail: %s", res.err_message)
	if len(p.state.calls) == 1 {
		c := p.state.calls[0]
		testing.expectf(t, c.method == svc.METHOD_LANGSERVER_INLAY_HINTS, "expected the inlay_hints face, got %s", c.method)
		testing.expectf(t, c.el == 9, "the range must ride the params")
	}
	items, is_arr := jsonutil.as_array(res.items)
	testing.expectf(t, is_arr && len(items) == 1, "one hint passes through, got %v", res.items)
	if is_arr && len(items) == 1 {
		testing.expectf(t, opsrelay_member_str(items[0], "label") == "i32", "the hint DTO passes through verbatim")
	}
}

@(test)
opsvc_prepare_walks_the_outline :: proc(t: ^testing.T) {
	p := opsvc_pair_init(t)
	if p == nil {
		return
	}
	defer opsvc_pair_destroy(p)
	// The outline answer here is the svc face's snake_case DTO — the e2e
	// preset is the camelCase wire form the daemon's LS client receives, a
	// different hop. The request at (2,4) sits inside greet's full range
	// but outside its selection range, so the ladder's deepest-range
	// candidate wins.
	p.state.answer = `{"symbols":[{"name":"Greeter","kind":5,` +
		`"range":{"start":{"line":0,"character":0},"end":{"line":4,"character":3}},` +
		`"selection_range":{"start":{"line":0,"character":6},"end":{"line":0,"character":13}},` +
		`"children":[{"name":"greet","kind":6,` +
		`"range":{"start":{"line":1,"character":2},"end":{"line":3,"character":5}},` +
		`"selection_range":{"start":{"line":1,"character":6},"end":{"line":1,"character":11}}}]}]}`

	arena: mem.Dynamic_Arena
	a := opsvc_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc_uri := strings.concatenate({"file://", p.tmp, "/main.cr"}, context.temp_allocator)
	req := lspserver.Ops_Request{kind = .Prepare_Call_Hierarchy, uri = doc_uri, start_line = 2, start_col = 4}
	res := session.host_lsp_ops(p.host, req, a)
	testing.expectf(t, !res.failed, "prepare must not fail: %s", res.err_message)
	testing.expectf(t, len(p.state.calls) == 1 && p.state.calls[0].method == svc.METHOD_SYMBOL_LIST, "prepare must read the symbol inventory once")
	if len(p.state.calls) == 1 {
		testing.expectf(t, p.state.calls[0].rel == "main.cr", "the rel path must reach the inventory, got %s", p.state.calls[0].rel)
	}
	items, is_arr := jsonutil.as_array(res.items)
	testing.expectf(t, is_arr && len(items) == 1, "prepare must answer one item, got %v", res.items)
	if is_arr && len(items) == 1 {
		item := items[0]
		testing.expectf(t, opsrelay_member_str(item, "name") == "greet", "the deepest containing symbol wins, got %s", opsrelay_member_str(item, "name"))
		testing.expectf(t, jsonutil.obj_get_int(item, "kind") == 6, "the outline kind rides as its number, got %d", jsonutil.obj_get_int(item, "kind"))
		want_uri := opsvc_canonical_uri(p, "main.cr")
		testing.expectf(t, opsrelay_member_str(item, "uri") == want_uri, "the uri must re-spell to the client spelling, got %s", opsrelay_member_str(item, "uri"))
		sl, sc, el, ec := opsrelay_dto_range(t, item, "range")
		testing.expectf(t, sl == 1 && sc == 2 && el == 3 && ec == 5, "the full range flattens, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		sl, sc, el, ec = opsrelay_dto_range(t, item, "selection_range")
		testing.expectf(t, sl == 1 && sc == 6 && el == 1 && ec == 11, "the selection range flattens, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
}

@(test)
opsvc_edges_direction_and_conversion :: proc(t: ^testing.T) {
	p := opsvc_pair_init(t)
	if p == nil {
		return
	}
	defer opsvc_pair_destroy(p)
	p.state.answer = `{"items":[{"name":"caller","kind":"Function","relative_path":"main.go",` +
		`"line":0,"col":0,"selection_line":1,"selection_col":2,` +
		`"from_ranges":[{"start_line":3,"start_col":4,"end_line":3,"end_col":9}]}]}`

	arena: mem.Dynamic_Arena
	a := opsvc_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc_uri := strings.concatenate({"file://", p.tmp, "/main.go"}, context.temp_allocator)
	req := lspserver.Ops_Request{kind = .Call_Edges, uri = doc_uri, start_line = 5, start_col = 6, incoming = true}
	res := session.host_lsp_ops(p.host, req, a)
	testing.expectf(t, !res.failed, "edges must not fail: %s", res.err_message)
	testing.expectf(t, len(p.state.calls) == 1, "one svc call must go out")
	if len(p.state.calls) == 1 {
		c := p.state.calls[0]
		testing.expectf(t, c.method == svc.METHOD_LANGSERVER_CALL_HIERARCHY, "expected the call_hierarchy face, got %s", c.method)
		testing.expectf(t, c.direction == "incoming", "the incoming direction must ride the params, got %s", c.direction)
		testing.expectf(t, c.line == 5 && c.col == 6, "the start point must ride the params, got (%d,%d)", c.line, c.col)
	}
	items, is_arr := jsonutil.as_array(res.items)
	testing.expectf(t, is_arr && len(items) == 1, "one edge answers, got %v", res.items)
	if is_arr && len(items) == 1 {
		item := items[0]
		testing.expectf(t, jsonutil.obj_get_int(item, "kind") == 12, "the kind name must recover to its number, got %d", jsonutil.obj_get_int(item, "kind"))
		want_uri := opsvc_canonical_uri(p, "main.go")
		testing.expectf(t, opsrelay_member_str(item, "uri") == want_uri, "the rel path must re-spell, got %s", opsrelay_member_str(item, "uri"))
		sl, sc, el, ec := opsrelay_dto_range(t, item, "range")
		testing.expectf(t, sl == 0 && sc == 0 && el == 0 && ec == 0, "the point range flattens, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		sl, sc, el, ec = opsrelay_dto_range(t, item, "selection_range")
		testing.expectf(t, sl == 1 && sc == 2 && el == 1 && ec == 2, "the selection point flattens, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		_, has_ranges := jsonutil.obj_get(item, "from_ranges")
		testing.expect(t, has_ranges, "the call-site ranges ride along")
	}

	// Outgoing rides the same face with the other direction spelling.
	req2 := lspserver.Ops_Request{kind = .Call_Edges, uri = doc_uri, start_line = 5, start_col = 6, incoming = false}
	res2 := session.host_lsp_ops(p.host, req2, a)
	testing.expectf(t, !res2.failed, "outgoing must not fail: %s", res2.err_message)
	testing.expectf(t, len(p.state.calls) == 2 && p.state.calls[1].direction == "outgoing", "the outgoing direction must ride the params, got %s", p.state.calls[len(p.state.calls)-1].direction)
}

@(test)
opsvc_link_down_fails :: proc(t: ^testing.T) {
	p := opsvc_pair_init(t)
	if p == nil {
		return
	}
	defer opsvc_pair_destroy(p)

	sync.mutex_lock(&p.app.parent_mu)
	p.app.parent = nil
	sync.mutex_unlock(&p.app.parent_mu)

	arena: mem.Dynamic_Arena
	a := opsvc_arena(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	doc_uri := strings.concatenate({"file://", p.tmp, "/main.go"}, context.temp_allocator)
	req := lspserver.Ops_Request{kind = .Formatting, uri = doc_uri, tab_size = 4, insert_spaces = true}
	res := session.host_lsp_ops(p.host, req, a)
	testing.expect(t, res.failed, "a down link must fail the fetch")
	testing.expect(t, res.err_message == "the daemon link is down", "the failure must name the cause")
	testing.expectf(t, len(p.state.calls) == 0, "a down link must not reach the daemon")
}

// opsrelay_dto_range reads one flattened DTO range block.
opsrelay_dto_range :: proc(t: ^testing.T, v: json.Value, member: string) -> (sl, sc, el, ec: i64) {
	rng, ok := jsonutil.obj_get(v, member)
	testing.expectf(t, ok, "the item carries no %s", member)
	if !ok {
		return
	}
	sl = jsonutil.obj_get_int(rng, "start_line")
	sc = jsonutil.obj_get_int(rng, "start_col")
	el = jsonutil.obj_get_int(rng, "end_line")
	ec = jsonutil.obj_get_int(rng, "end_col")
	return
}

// --- test: the registration sweep ---------------------------------------------

@(test)
opsrelay_sweep_registers_langserver_faces :: proc(t: ^testing.T) {
	p := relayhost_pair_init(t)
	if p == nil {
		return
	}
	defer relayhost_pair_destroy(p)

	p.daemon_state.start_ok = true
	p.daemon_state.start_references = true
	p.daemon_state.start_declaration = false
	relayhost_arm_face(t, p)
	doc_uri := strings.concatenate({"file://", p.tmp, "/main.go"}, context.temp_allocator)
	relayhost_open(t, p, doc_uri, "go", 1, "package main\n")

	// The push makes go Ready, and the starter pass must register the four
	// langserver faces in the SAME batch as the position relays — no
	// capability bits exist for them, so they ride every Ready batch.
	relayhost_push(t, p, svc.METHOD_PUSH_LANGSERVER_STATE, `{"language":"go","running":true,"references":true,"declaration":false}`, session.handle_push_langserver_state)
	completed := relayhost_run_pass(t, p, proc(t: ^testing.T, body: string) {
		v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
		testing.expectf(t, perr == nil, "frame did not parse: %s", body)
		if perr != nil {
			return
		}
		testing.expectf(t, lsprelay_member_str(v, "method") == lsp.METHOD_REGISTER_CAPABILITY, "expected registerCapability, got %s", body)
		if params, ok := jsonutil.obj_get(v, "params"); ok {
			regs_v, regs_ok := jsonutil.obj_get(params, "registrations")
			if regs_ok {
				regs, _ := jsonutil.as_array(regs_v)
				testing.expectf(t, len(regs) == 6, "one batch of six (definition, references, formatting, codeAction, inlayHint, prepareCallHierarchy), got %d", len(regs))
			}
			lsprelay_assert_registration(t, params, 0, "aubade.relay.go.definition", lsp.METHOD_DEFINITION, "go")
			lsprelay_assert_registration(t, params, 1, "aubade.relay.go.references", lsp.METHOD_REFERENCES, "go")
			lsprelay_assert_registration(t, params, 2, "aubade.relay.go.formatting", lsp.METHOD_FORMATTING, "go")
			lsprelay_assert_registration(t, params, 3, "aubade.relay.go.codeAction", lsp.METHOD_CODE_ACTION, "go")
			lsprelay_assert_registration(t, params, 4, "aubade.relay.go.inlayHint", lsp.METHOD_INLAY_HINT, "go")
			lsprelay_assert_registration(t, params, 5, "aubade.relay.go.prepareCallHierarchy", lsp.METHOD_PREPARE_CALL_HIERARCHY, "go")
		}
	})
	testing.expect(t, completed, "the starter pass must complete")
	testing.expect(t, p.host.relay["go"].is_registered, "the successful registration must latch is_registered")
	testing.expectf(t, len(p.down.buf) == 0, "exactly one registration request went out")
}

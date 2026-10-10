// textDocument/documentSymbol tests: the face over the same synchronous
// pipe harness as the face and relay tests (own fake host — outline, text,
// log — on the shared lspface pair plumbing and Pipe/json_bytes helpers),
// and the supply-side verification over a real in-process daemon: the
// outline the SQLite L1 payload decode produces and the outline a fresh
// parse produces must be structurally equal.
package tests

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:platform"
import "src:svc"

// The canned svc.symbol/list answer the fake outline host serves. Ghost
// carries a child so the rangeless drop is visible as a subtree drop;
// Rootless pins the same rule at the top level; fallback has no
// selection_range so the range-as-selection fallback shows.
ds_outline_tree_json :: `{"symbols":[
 {"name":"Outer","kind":5,"detail":"class doc","range":{"start":{"line":0,"character":0},"end":{"line":5,"character":1}},"selection_range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"children":[
   {"name":"inner","kind":8,"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":12}},"selection_range":{"start":{"line":1,"character":1},"end":{"line":1,"character":6}}},
   {"name":"Ghost","kind":13,"children":[{"name":"Orphan","kind":13,"range":{"start":{"line":2,"character":2},"end":{"line":2,"character":8}}}]},
   {"name":"fallback","kind":12,"range":{"start":{"line":3,"character":1},"end":{"line":3,"character":20}}}
 ]},
 {"name":"top2","kind":23,"range":{"start":{"line":7,"character":0},"end":{"line":7,"character":9}}},
 {"name":"Rootless","kind":13,"children":[{"name":"Buried","kind":13,"range":{"start":{"line":9,"character":0},"end":{"line":9,"character":6}}}]}
]}`

// Two ASCII-line outline nodes over a document whose first line carries a
// two-byte rune: line 0 is `x := "héllo"` — utf-16 column 7 is the rune's
// start (byte 7), column 8 lands past it (byte 9).
ds_outline_utf8_json :: `{"symbols":[
 {"name":"accent","kind":13,"range":{"start":{"line":0,"character":7},"end":{"line":0,"character":8}}},
 {"name":"ascii","kind":12,"range":{"start":{"line":1,"character":5},"end":{"line":1,"character":9}}}
]}`

// --- the fake host -----------------------------------------------------------

Ds_Host :: struct {
	allocator:     mem.Allocator,
	outline_calls: int,
	outline_ok:    bool,   // the preset svc verdict
	outline_json:  string, // the preset raw answer (a test literal, borrowed)
	text_calls:    int,
	text:          string, // the preset Text_For_Uri answer ("" = not ok)
	logs:          [dynamic]string, // owned clones of the face's notes
}

ds_host_init :: proc(h: ^Ds_Host, a: mem.Allocator) {
	h^ = {
		allocator = a,
		logs      = make([dynamic]string, 0, 4, a),
	}
}

ds_host_destroy :: proc(h: ^Ds_Host) {
	for l in h.logs {
		delete(l, h.allocator)
	}
	delete(h.logs)
	h^ = {}
}

ds_outline_host_cb :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (json.Value, bool) {
	h := cast(^Ds_Host)host
	_ = uri
	h.outline_calls += 1
	if !h.outline_ok {
		return json.Value{}, false
	}
	v, perr := json.parse_string(h.outline_json, spec = .JSON, parse_integers = true, allocator = arena)
	if perr != nil {
		return json.Value{}, false
	}
	return v, true
}

ds_text_host_cb :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (text: string, ok: bool) {
	h := cast(^Ds_Host)host
	_ = uri
	_ = arena
	h.text_calls += 1
	if h.text == "" {
		return "", false
	}
	return h.text, true
}

ds_log_host_cb :: proc(host: rawptr, message: string) {
	h := cast(^Ds_Host)host
	append(&h.logs, strings.clone(message, h.allocator))
}

// --- the synchronous harness (the shared lspface pair plumbing, own host) -----

Ds_Pair :: struct {
	up:     Pipe,
	down:   Pipe,
	send:   jsonrpc.Writer,
	recv:   jsonrpc.Reader,
	conn:   jsonrpc.Conn, // the server's conn
	server: lspserver.Server,
	host:   Ds_Host,
}

// ds_finish_host initializes the ds host and builds its server value (the
// outline/text/log callback set) over it.
ds_finish_host :: proc(host, pair: rawptr, a: mem.Allocator) -> lspserver.Server {
	_ = pair
	h := cast(^Ds_Host)host
	ds_host_init(h, a)
	return {
		host         = host,
		name         = "aubade",
		version      = "test",
		outline      = ds_outline_host_cb,
		text_for_uri = ds_text_host_cb,
		log          = ds_log_host_cb,
		allocator    = a,
	}
}

ds_free_host :: proc(host: rawptr) {
	ds_host_destroy(cast(^Ds_Host)host)
}

ds_pair_init :: proc(t: ^testing.T) -> ^Ds_Pair {
	_ = t
	return lspface_pair_open(Ds_Pair, ds_finish_host)
}

ds_pair_destroy :: proc(p: ^Ds_Pair) {
	lspface_pair_close(p, ds_free_host)
}

// ds_open composes one didOpen (built by concatenation and json_quote —
// fmt's format string would eat the braces).
ds_open :: proc(t: ^testing.T, p: ^Ds_Pair, uri, language_id: string, version: i32, text: string) {
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
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, params)
}

// ds_initialize sends initialize with the given capabilities inner text
// ("" = none) and asserts an ok reply.
ds_initialize :: proc(t: ^testing.T, p: ^Ds_Pair, caps_inner: string) {
	params := ""
	if caps_inner != "" {
		params = strings.concatenate({`"capabilities":{`, caps_inner, "}"}, context.temp_allocator)
	}
	body := lspface_request(t, p, "1", lsp.METHOD_INITIALIZE, params)
	testing.expect(t, body != "", "initialize produced no reply")
	testing.expectf(t, lspface_reply_code(t, body) == 0, "initialize answered an error: %s", body)
}

DS_CAPS_UTF16 :: `"general":{"positionEncodings":["utf-16"]}`
DS_CAPS_UTF8 :: `"general":{"positionEncodings":["utf-8"]}`
DS_CAPS_UTF16_HIER :: `"general":{"positionEncodings":["utf-16"]},"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}}`
DS_CAPS_UTF8_HIER :: `"general":{"positionEncodings":["utf-8"]},"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}}`

// --- face-side readers --------------------------------------------------------

ds_result_items :: proc(t: ^testing.T, body: string) -> []json.Value {
	testing.expectf(t, body != "", "documentSymbol produced no reply")
	if body == "" {
		return nil
	}
	testing.expectf(t, lspface_reply_code(t, body) == 0, "documentSymbol answered an error: %s", body)
	v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "documentSymbol reply did not parse: %s", body)
	if perr != nil {
		return nil
	}
	result, ok := jsonutil.obj_get(v, "result")
	testing.expect(t, ok, "documentSymbol reply carries no result")
	if !ok {
		return nil
	}
	items, is_arr := jsonutil.as_array(result)
	testing.expect(t, is_arr, "documentSymbol result is not an array")
	return items
}

ds_range_of :: proc(t: ^testing.T, node: json.Value, key: string) -> (sl, sc, el, ec: i64) {
	rng, ok := jsonutil.obj_get(node, key)
	testing.expectf(t, ok, "%s member missing", key)
	if !ok {
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

// --- tests: the face ------------------------------------------------------------

@(test)
dsface_document_symbol_hierarchical_nested :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	ds_initialize(t, p, DS_CAPS_UTF16_HIER)

	p.host.outline_ok = true
	p.host.outline_json = ds_outline_tree_json
	body := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	items := ds_result_items(t, body)
	testing.expectf(t, len(items) == 2, "the rangeless root drops with its subtree: 2 roots expected, got %d", len(items))
	if len(items) != 2 {
		return
	}

	outer := items[0]
	testing.expectf(t, jsonutil.obj_get_int(outer, "kind") == 5, "the kind passes through as the int, got %d", jsonutil.obj_get_int(outer, "kind"))
	if v, ok := jsonutil.obj_get(outer, "name"); ok {
		testing.expectf(t, jsonutil.value_str(v) == "Outer", "the root name must pass through, got %s", jsonutil.value_str(v))
	}
	if v, ok := jsonutil.obj_get(outer, "detail"); ok {
		testing.expectf(t, jsonutil.value_str(v) == "class doc", "a non-empty detail must ride along, got %s", jsonutil.value_str(v))
	}
	sl, sc, el, ec := ds_range_of(t, outer, "range")
	testing.expectf(t, sl == 0 && sc == 0 && el == 5 && ec == 1, "the range must pass through, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	sl, sc, el, ec = ds_range_of(t, outer, "selectionRange")
	testing.expectf(t, sl == 0 && sc == 6 && el == 0 && ec == 11, "the selectionRange must pass through, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	_, has_uri := jsonutil.obj_get(outer, "uri")
	testing.expect(t, !has_uri, "hierarchical items carry no uri")

	kids_v, has_kids := jsonutil.obj_get(outer, "children")
	testing.expect(t, has_kids, "surviving children must render")
	kids, _ := jsonutil.as_array(kids_v)
	testing.expectf(t, len(kids) == 2, "the rangeless child drops with its subtree: 2 children expected, got %d", len(kids))
	if len(kids) == 2 {
		// fallback carries no selection_range in the source outline: its
		// range serves as the selectionRange.
		fsl, fsc, fel, fec := ds_range_of(t, kids[1], "range")
		ssl, ssc, sel, sec := ds_range_of(t, kids[1], "selectionRange")
		testing.expectf(
			t,
			fsl == 3 && fsc == 1 && fel == 3 && fec == 20 && ssl == fsl && ssc == fsc && sel == fel && sec == fec,
			"the missing selection_range must fall back to the range, got (%d,%d)-(%d,%d) and (%d,%d)-(%d,%d)",
			fsl, fsc, fel, fec, ssl, ssc, sel, sec,
		)
	}

	// Ghost's subtree (the Orphan inside the rangeless child) and Rootless's
	// Buried must appear nowhere.
	for item in items {
		if sub_v, ok := jsonutil.obj_get(item, "children"); ok {
			if sub, is_arr := jsonutil.as_array(sub_v); is_arr {
				for kid in sub {
					if v, nok := jsonutil.obj_get(kid, "name"); nok {
						testing.expectf(t, jsonutil.value_str(v) != "Orphan", "the dropped child's subtree must not survive")
					}
				}
			}
		}
	}
	testing.expectf(t, p.host.outline_calls == 1, "the outline host must be called once, got %d", p.host.outline_calls)
	testing.expectf(t, p.host.text_calls == 0, "a utf-16 connection converts nothing, so no text is fetched, got %d", p.host.text_calls)
}

@(test)
dsface_document_symbol_flat_carries_uri :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	// No textDocument.documentSymbol capability member: absent bit = flat.
	ds_initialize(t, p, DS_CAPS_UTF16)

	p.host.outline_ok = true
	p.host.outline_json = ds_outline_tree_json
	body := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	items := ds_result_items(t, body)
	// Pre-order flatten: Outer, inner, fallback, then top2; the rangeless
	// nodes (Ghost, Rootless) drop with their subtrees.
	testing.expectf(t, len(items) == 4, "the flat form pre-orders the survivors, got %d", len(items))
	want := [4]string{"Outer", "inner", "fallback", "top2"}
	for item, i in items {
		if i >= len(want) {
			break
		}
		if v, ok := jsonutil.obj_get(item, "name"); ok {
			testing.expectf(t, jsonutil.value_str(v) == want[i], "flat item %d must be %s, got %s", i, want[i], jsonutil.value_str(v))
		}
		_, has_children := jsonutil.obj_get(item, "children")
		_, has_detail := jsonutil.obj_get(item, "detail")
		_, has_sel := jsonutil.obj_get(item, "selectionRange")
		testing.expectf(t, !has_children && !has_detail && !has_sel, "flat items carry neither children, detail, nor selectionRange (item %d)", i)
		loc, ok := jsonutil.obj_get(item, "location")
		testing.expectf(t, ok, "flat item %d carries a location", i)
		if ok {
			if uv, uok := jsonutil.obj_get(loc, "uri"); uok {
				testing.expectf(t, jsonutil.value_str(uv) == "file:///w/prog.go", "flat items carry the requested uri verbatim, got %s", jsonutil.value_str(uv))
			} else {
				testing.expectf(t, false, "flat item %d's location carries no uri", i)
			}
			_, has_range := jsonutil.obj_get(loc, "range")
			testing.expectf(t, has_range, "flat item %d's location carries the range", i)
		}
	}
}

@(test)
dsface_document_symbol_utf8_converts_columns :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	ds_initialize(t, p, DS_CAPS_UTF8_HIER)
	ds_open(t, p, "file:///w/prog.thing", "odin", 1, "x := \"héllo\"\nfunc main() {}\n")

	p.host.outline_ok = true
	p.host.outline_json = ds_outline_utf8_json
	body := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.thing"}`)
	items := ds_result_items(t, body)
	testing.expectf(t, len(items) == 2, "both nodes carry ranges, got %d", len(items))
	if len(items) == 2 {
		// utf-16 (0,7)-(0,8) sits on the two-byte rune and past it:
		// bytes (0,7)-(0,9).
		sl, sc, el, ec := ds_range_of(t, items[0], "range")
		testing.expectf(t, sl == 0 && sc == 7 && el == 0 && ec == 9, "the accent line must convert to bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
		// An ASCII line converts to itself.
		sl, sc, el, ec = ds_range_of(t, items[1], "range")
		testing.expectf(t, sl == 1 && sc == 5 && el == 1 && ec == 9, "the ascii line must pass through, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	}
	// The open document's view snapshot is the conversion truth — the text
	// host is never fetched for the requested document.
	testing.expectf(t, p.host.text_calls == 0, "the view snapshot must serve the conversion, got %d text fetches", p.host.text_calls)
}

@(test)
dsface_document_symbol_unservable_text_answers_empty :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	// utf-8 connection, document neither open nor fetchable: the outline's
	// UTF-16 columns cannot be rendered in the negotiated encoding, so the
	// whole answer degrades to empty — one log line, no per-node holes.
	ds_initialize(t, p, DS_CAPS_UTF8)

	p.host.outline_ok = true
	p.host.outline_json = ds_outline_tree_json
	body := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/elsewhere.go"}`)
	items := ds_result_items(t, body)
	testing.expectf(t, len(items) == 0, "an unservable document answers empty, got %d", len(items))
	testing.expectf(t, p.host.outline_calls == 1, "the outline is fetched before the conversion truth is needed, got %d", p.host.outline_calls)
	testing.expectf(t, p.host.text_calls == 1, "the text host is the snapshot's fallback, got %d fetches", p.host.text_calls)
	testing.expectf(t, len(p.host.logs) == 1, "the degradation logs once, got %d lines", len(p.host.logs))
}

@(test)
dsface_document_symbol_failed_host_answers_empty :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	ds_initialize(t, p, DS_CAPS_UTF16)

	// A failed svc fetch is never an error response: empty array, one line.
	p.host.outline_ok = false
	body := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	items := ds_result_items(t, body)
	testing.expectf(t, len(items) == 0, "a failed fetch answers empty, got %d", len(items))
	testing.expectf(t, len(p.host.logs) == 1, "the failure logs once, got %d lines", len(p.host.logs))

	// An answer without a symbol list degrades the same way.
	logs_before := len(p.host.logs)
	p.host.outline_ok = true
	p.host.outline_json = `{}`
	body2 := lspface_request(t, p, "3", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	items2 := ds_result_items(t, body2)
	testing.expectf(t, len(items2) == 0, "a missing symbol list answers empty, got %d", len(items2))
	testing.expectf(t, len(p.host.logs)-logs_before == 1, "the shape break logs once, got %d new lines", len(p.host.logs)-logs_before)
}

@(test)
dsface_document_symbol_nil_host_answers_empty :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	ds_initialize(t, p, DS_CAPS_UTF16)
	p.server.outline = nil

	body := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	items := ds_result_items(t, body)
	testing.expectf(t, len(items) == 0, "a nil outline host answers empty, got %d", len(items))
	testing.expect(t, len(p.host.logs) == 0, "an unwired host is a normal state, not a refusal")
}

@(test)
dsface_document_symbol_gate_and_params :: proc(t: ^testing.T) {
	p := ds_pair_init(t)
	defer ds_pair_destroy(p)

	// Before initialize every request waits: -32002.
	body := lspface_request(t, p, "1", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expect(t, body != "", "the request must be answered")
	testing.expectf(t, lspface_reply_code(t, body) == -32002, "expected -32002 before initialize, got %s", body)

	ds_initialize(t, p, DS_CAPS_UTF16)

	// A missing uri is invalid params, not an empty outline.
	body2 := lspface_request(t, p, "2", lsp.METHOD_DOCUMENT_SYMBOL, `"textDocument":{}`)
	testing.expectf(t, lspface_reply_code(t, body2) == -32602, "a missing uri must answer InvalidParams, got %s", body2)
}

// --- the supply side over a real daemon -----------------------------------------

// ds_outline_level_equal compares one outline level pairwise (names, kinds,
// ranges, selection ranges, children) and recurses.
ds_outline_level_equal :: proc(t: ^testing.T, ka, kb: []json.Value, place: string) -> bool {
	if len(ka) != len(kb) {
		testing.expectf(t, false, "%s: node count %d != %d", place, len(ka), len(kb))
		return false
	}
	for i in 0 ..< len(ka) {
		next := strings.concatenate({place, "/", fmt.aprintf("%d", i, allocator = context.temp_allocator)}, context.temp_allocator)
		if !ds_outline_node_equal(t, ka[i], kb[i], next) {
			return false
		}
	}
	return true
}

ds_outline_node_equal :: proc(t: ^testing.T, na, nb: json.Value, place: string) -> bool {
	name_a := ""
	if v, ok := jsonutil.obj_get(na, "name"); ok {
		name_a = jsonutil.value_str(v)
	}
	name_b := ""
	if v, ok := jsonutil.obj_get(nb, "name"); ok {
		name_b = jsonutil.value_str(v)
	}
	if name_a != name_b {
		testing.expectf(t, false, "%s: names differ (%s vs %s)", place, name_a, name_b)
		return false
	}
	if jsonutil.obj_get_int(na, "kind") != jsonutil.obj_get_int(nb, "kind") {
		testing.expectf(t, false, "%s: kinds differ", place)
		return false
	}
	if !ds_outline_range_equal(t, na, nb, "range", place) {
		return false
	}
	_, sa := jsonutil.obj_get(na, "selection_range")
	_, sb := jsonutil.obj_get(nb, "selection_range")
	if sa != sb {
		testing.expectf(t, false, "%s: selection_range presence differs", place)
		return false
	}
	if sa && !ds_outline_range_equal(t, na, nb, "selection_range", place) {
		return false
	}
	kids_a: []json.Value
	if v, ok := jsonutil.obj_get(na, "children"); ok {
		kids_a, _ = jsonutil.as_array(v)
	}
	kids_b: []json.Value
	if v, ok := jsonutil.obj_get(nb, "children"); ok {
		kids_b, _ = jsonutil.as_array(v)
	}
	return ds_outline_level_equal(t, kids_a, kids_b, place)
}

ds_outline_range_equal :: proc(t: ^testing.T, na, nb: json.Value, key, place: string) -> bool {
	ra, oka := jsonutil.obj_get(na, key)
	rb, okb := jsonutil.obj_get(nb, key)
	if !oka || !okb {
		testing.expectf(t, false, "%s: %s missing from one arm", place, key)
		return false
	}
	sta, _ := jsonutil.obj_get(ra, "start")
	ena, _ := jsonutil.obj_get(ra, "end")
	stb, _ := jsonutil.obj_get(rb, "start")
	enb, _ := jsonutil.obj_get(rb, "end")
	same := jsonutil.obj_get_int(sta, "line") == jsonutil.obj_get_int(stb, "line") &&
		jsonutil.obj_get_int(sta, "character") == jsonutil.obj_get_int(stb, "character") &&
		jsonutil.obj_get_int(ena, "line") == jsonutil.obj_get_int(enb, "line") &&
		jsonutil.obj_get_int(ena, "character") == jsonutil.obj_get_int(enb, "character")
	if !same {
		testing.expectf(t, false, "%s: %s differs between the arms", place, key)
	}
	return same
}

// The outline's two supply arms agree. The first
// svc.symbol/list answers from the L1 SQLite payload (a payload hit never
// parses); the second answers from a fresh parse, forced by a
// structure-preserving byte change — same bytes would hit the L1 probe
// before the hot tier by design, so the byte change is the honest way to
// reach the parse arm. Trailing-comment bytes leave every symbol's name,
// kind, range, and children untouched, so the two answers must be
// structurally equal.
@(test)
ds_svc_outline_cold_and_hot_agree :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)
	if !svc_symbol_quiesce_warm(t, pair) {
		return
	}

	body_text := "package main\n\nOuter :: struct {\n\tinner:  int,\n\tnested: bool,\n}\n\nHelper :: proc() -> int {\n\treturn 7\n}\n\nmain :: proc() {\n\tprintln(\"hi\")\n}\n"
	svc_symbol_write_file(t, pair.tmp, "hello.odin", body_text)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	hello_params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&hello_params, "client_pid", jsonutil.json_int(4242))
	_, _, _, hcerr := jsonrpc.conn_call(pair.conn, svc.METHOD_HELLO, json.Value(json.Object(hello_params)), alloc, deadline)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)

	// The synchronous crawl fills the index rows and the L1 payload for the
	// file; nothing holds its parse tree.
	crawl := svc.client_index_crawl(pair.conn, "", alloc, deadline)
	testing.expect_value(t, crawl.call_err, jsonrpc.Call_Err.None)

	// COLD: the L1 SQLite payload decode.
	list_cold := svc.client_symbol_list(pair.conn, "hello.odin", alloc, deadline)
	testing.expect_value(t, list_cold.call_err, jsonrpc.Call_Err.None)
	syms_cold_v, cok := jsonutil.obj_get(list_cold.result, "symbols")
	testing.expect(t, cok, "the cold answer carries symbols")
	syms_cold, carr := jsonutil.as_array(syms_cold_v)
	testing.expectf(t, carr && len(syms_cold) > 0, "the cold answer must carry roots, got %d", len(syms_cold))

	// HOT: a trailing comment changes the bytes (new hash: L1 miss) without
	// touching any symbol's structure, so the next list parses fresh.
	svc_symbol_write_file(t, pair.tmp, "hello.odin", strings.concatenate({body_text, "\n// appended after every symbol's range\n"}, alloc))
	list_hot := svc.client_symbol_list(pair.conn, "hello.odin", alloc, deadline)
	testing.expect_value(t, list_hot.call_err, jsonrpc.Call_Err.None)
	syms_hot_v, hok := jsonutil.obj_get(list_hot.result, "symbols")
	testing.expect(t, hok, "the hot answer carries symbols")
	syms_hot, harr := jsonutil.as_array(syms_hot_v)
	testing.expect(t, harr, "the hot answer's symbols is an array")

	ds_outline_level_equal(t, syms_cold, syms_hot, "outline")
}

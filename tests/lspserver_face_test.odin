// lspserver face tests against an in-memory fake LSP client, driven
// synchronously: the test writes real wire frames (Content-Length header
// framing) into a pipe, runs the server conn's dispatch on the test thread
// itself, and reads the reply frames back out of the opposite pipe. No
// threads, no sleeps — every step is a direct call, and the fake host
// callbacks record what reached them. Covers the initialize handshake
// (positionEncoding negotiation, static capabilities, serverInfo), the
// lifecycle gate (-32002 before initialize, shutdown/exit statuses),
// document-sync forwarding, semanticTokens/full encoding (utf-8 and
// utf-16), the decline ladder's empty-data degradation with its per-file
// log latch, and unknown-method handling.
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"

import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:lsp"
import "src:lspserver"

// --- the fake host -----------------------------------------------------------

Lspface_Open :: struct {
	uri:         string,
	language_id: string,
	version:     i32,
	text:        string,
}

Lspface_Change :: struct {
	uri:     string,
	version: i32,
	text:    string,
}

Lspface_Highlights :: struct {
	has_version: bool,
	decline:     string,
	failed:      bool,
	err_message: string,
	captures:    []lspserver.Capture_Hit,
}

// Lspface_Diagnostics is the preset svc.doc/diagnostics answer the
// diagnostics callback returns (the publish tests point it at declines,
// failures, and hit lists).
Lspface_Diagnostics :: struct {
	version:     i32,
	has_version: bool,
	decline:     string,
	truncated:   bool,
	failed:      bool,
	err_message: string,
	hits:        []lspserver.Diag_Hit, // owned clones
}

// Lspface_Relay_Call records one Relay_Host invocation (kind, the request
// position, and the converted UTF-16 column the face handed over).
Lspface_Relay_Call :: struct {
	kind:                lspserver.Relay_Kind,
	uri:                 string, // owned clone
	line:                int,
	col_utf16:           int,
	include_declaration: bool,
}

// Lspface_Text is one preset Text_For_Uri_Host answer: the host serves
// `text` for `uri` and not-ok for anything else.
Lspface_Text :: struct {
	uri:  string, // owned clones
	text: string,
}

// Lspface_Host records every callback the face makes. Everything runs on
// the test thread (the synchronous harness dispatches frames inline), so
// plain fields need no lock.
Lspface_Host :: struct {
	allocator: mem.Allocator,

	init_root_uri: string,
	init_folders:  [dynamic]string,
	// When set, the initialize callback returns this error message.
	init_failure: string,

	opens:   [dynamic]Lspface_Open,
	changes: [dynamic]Lspface_Change,
	closes:  [dynamic]string,

	highlights_calls: int,
	// The preset answer the highlights callback returns.
	highlights: Lspface_Highlights,

	diagnostics_calls: int,
	// The preset answer the diagnostics callback returns.
	diagnostics: Lspface_Diagnostics,

	readiness_calls: int,
	readiness_live:  bool, // the preset svc.langserver/list verdict

	// The relay ports: every Relay_Host call is recorded (the request
	// position with its converted UTF-16 column), and the preset answer is
	// returned (locations cloned into the request arena). The text host
	// serves its preset per-uri texts; unknown uris answer not-ok.
	relay_calls: int,
	relay_reqs:  [dynamic]Lspface_Relay_Call,
	relay_locs:  [dynamic]lspserver.Relay_Location, // owned clones (the preset answer)
	relay_failed: bool,
	relay_err:    string, // owned clone

	text_calls: int,
	texts:      [dynamic]Lspface_Text,

	logs: [dynamic]string, // owned clones of the face's notes

	// Back-pointer to the owning pair, set by lspface_pair_init: lets the
	// diagnostics callback re-dispatch a frame through the server conn
	// (the mid-pass didClose the publish ordering test drives).
	pair: ^Lspface_Pair,
	// When set, the diagnostics callback first dispatches a didClose for
	// this uri through the server conn before answering — a close landing
	// mid-pass, which the debounced fire pass must stay ordered against.
	// Owned clone.
	close_uri: string,
}

lspface_host_init :: proc(h: ^Lspface_Host, a: mem.Allocator) {
	h^ = {
		allocator    = a,
		init_folders = make([dynamic]string, 0, 4, a),
		opens        = make([dynamic]Lspface_Open, 0, 4, a),
		changes      = make([dynamic]Lspface_Change, 0, 4, a),
		closes       = make([dynamic]string, 0, 4, a),
		relay_reqs   = make([dynamic]Lspface_Relay_Call, 0, 4, a),
		relay_locs   = make([dynamic]lspserver.Relay_Location, 0, 4, a),
		texts        = make([dynamic]Lspface_Text, 0, 4, a),
		logs         = make([dynamic]string, 0, 4, a),
	}
}

lspface_host_destroy :: proc(h: ^Lspface_Host) {
	for f in h.init_folders {
		delete(f, h.allocator)
	}
	delete(h.init_folders)
	for o in h.opens {
		delete(o.uri, h.allocator)
		delete(o.language_id, h.allocator)
		delete(o.text, h.allocator)
	}
	delete(h.opens)
	for c in h.changes {
		delete(c.uri, h.allocator)
		delete(c.text, h.allocator)
	}
	delete(h.changes)
	for c in h.closes {
		delete(c, h.allocator)
	}
	delete(h.closes)
	for l in h.logs {
		delete(l, h.allocator)
	}
	delete(h.logs)
	if h.close_uri != "" {
		delete(h.close_uri, h.allocator)
	}
	if h.init_root_uri != "" {
		delete(h.init_root_uri, h.allocator)
	}
	for r in h.relay_reqs {
		delete(r.uri, h.allocator)
	}
	delete(h.relay_reqs)
	lspface_clear_relay_result(h)
	for t in h.texts {
		delete(t.uri, h.allocator)
		delete(t.text, h.allocator)
	}
	delete(h.texts)
	// relay_err is test-assigned (string literals): borrowed by the
	// callback, never owned — nothing to free here.
	lspface_clear_captures(h)
	lspface_clear_diagnostics(h)
	h^ = {}
}

lspface_init_host_cb :: proc(host: rawptr, root_uri: string, workspace_folders: []string, arena: mem.Allocator) -> string {
	h := cast(^Lspface_Host)host
	_ = arena
	if h.init_root_uri == "" {
		h.init_root_uri = strings.clone(root_uri, h.allocator)
	}
	for f in workspace_folders {
		append(&h.init_folders, strings.clone(f, h.allocator))
	}
	return h.init_failure
}

lspface_open_host_cb :: proc(host: rawptr, uri: string, language_id: string, version: i32, text: string) {
	h := cast(^Lspface_Host)host
	append(
		&h.opens,
		Lspface_Open{
			uri         = strings.clone(uri, h.allocator),
			language_id = strings.clone(language_id, h.allocator),
			version     = version,
			text        = strings.clone(text, h.allocator),
		},
	)
}

lspface_change_host_cb :: proc(host: rawptr, uri: string, version: i32, text: string) {
	h := cast(^Lspface_Host)host
	append(
		&h.changes,
		Lspface_Change{
			uri     = strings.clone(uri, h.allocator),
			version = version,
			text    = strings.clone(text, h.allocator),
		},
	)
}

lspface_close_host_cb :: proc(host: rawptr, uri: string) {
	h := cast(^Lspface_Host)host
	append(&h.closes, strings.clone(uri, h.allocator))
}

lspface_highlights_host_cb :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> lspserver.Highlights_Result {
	h := cast(^Lspface_Host)host
	_ = uri
	h.highlights_calls += 1
	hr: lspserver.Highlights_Result
	hr.has_version = h.highlights.has_version
	hr.decline = h.highlights.decline
	hr.failed = h.highlights.failed
	hr.err_message = h.highlights.err_message
	if h.highlights.captures != nil {
		// Copy into the request arena; the captures' names ride along.
		dyn := make([dynamic]lspserver.Capture_Hit, 0, len(h.highlights.captures), arena)
		for c in h.highlights.captures {
			append(&dyn, lspserver.Capture_Hit{capture = strings.clone(c.capture, arena), start_byte = c.start_byte, end_byte = c.end_byte})
		}
		hr.captures = dyn[:]
	}
	return hr
}

lspface_log_host_cb :: proc(host: rawptr, message: string) {
	h := cast(^Lspface_Host)host
	append(&h.logs, strings.clone(message, h.allocator))
}

lspface_diagnostics_host_cb :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> lspserver.Diagnostics_Result {
	h := cast(^Lspface_Host)host
	_ = uri
	h.diagnostics_calls += 1
	// The mid-pass close: dispatch a didClose through the server conn
	// before answering, so the fire pass's fetch races the close path the
	// way the off-thread pass races the dispatch thread in production.
	if h.close_uri != "" && h.pair != nil {
		body := strings.concatenate(
			{`{"jsonrpc":"2.0","method":"`, lsp.METHOD_DID_CLOSE, `","params":{"textDocument":{"uri":"`, h.close_uri, `"}}}`},
			context.temp_allocator,
		)
		if err := jsonrpc.write_frame(&h.pair.send, json_bytes(body)); err == .None {
			if got, rerr := jsonrpc.read_frame(&h.pair.conn.reader, context.temp_allocator); rerr == .None {
				_ = jsonrpc.conn_handle_body(&h.pair.conn, got, context.temp_allocator)
			}
		}
	}
	dr: lspserver.Diagnostics_Result
	dr.version = h.diagnostics.version
	dr.has_version = h.diagnostics.has_version
	dr.decline = h.diagnostics.decline
	dr.truncated = h.diagnostics.truncated
	dr.failed = h.diagnostics.failed
	dr.err_message = h.diagnostics.err_message
	if h.diagnostics.hits != nil {
		// Copy into the request arena; the messages ride along.
		dyn := make([dynamic]lspserver.Diag_Hit, 0, len(h.diagnostics.hits), arena)
		for hit in h.diagnostics.hits {
			append(&dyn, lspserver.Diag_Hit{start_byte = hit.start_byte, end_byte = hit.end_byte, message = strings.clone(hit.message, arena)})
		}
		dr.diagnostics = dyn[:]
	}
	return dr
}

lspface_readiness_host_cb :: proc(host: rawptr, language_id: string, arena: mem.Allocator) -> lspserver.Readiness_Result {
	h := cast(^Lspface_Host)host
	_ = language_id
	_ = arena
	h.readiness_calls += 1
	rr: lspserver.Readiness_Result
	rr.live = h.readiness_live
	return rr
}

lspface_relay_host_cb :: proc(host: rawptr, uri: string, line: int, col_utf16: int, include_declaration: bool, kind: lspserver.Relay_Kind, arena: mem.Allocator) -> lspserver.Relay_Result {
	h := cast(^Lspface_Host)host
	h.relay_calls += 1
	append(&h.relay_reqs, Lspface_Relay_Call{
		kind                = kind,
		uri                 = strings.clone(uri, h.allocator),
		line                = line,
		col_utf16           = col_utf16,
		include_declaration = include_declaration,
	})
	rr: lspserver.Relay_Result
	rr.failed = h.relay_failed
	rr.err_message = h.relay_err
	if len(h.relay_locs) > 0 {
		out := make([dynamic]lspserver.Relay_Location, 0, len(h.relay_locs), arena)
		for l in h.relay_locs {
			append(&out, lspserver.Relay_Location{
				uri      = strings.clone(l.uri, arena),
				line     = l.line,
				col      = l.col,
				has_end  = l.has_end,
				end_line = l.end_line,
				end_col  = l.end_col,
			})
		}
		rr.locations = out[:]
	}
	return rr
}

lspface_text_host_cb :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> (text: string, ok: bool) {
	h := cast(^Lspface_Host)host
	_ = arena
	h.text_calls += 1
	for t in h.texts {
		if t.uri == uri {
			return t.text, true
		}
	}
	return "", false
}

// --- the synchronous harness ---------------------------------------------------

// The server conn's reader consumes `up` (the fake client's frames) and its
// writer feeds `down` (the replies the test reads back). The test plays both
// sides: write a frame into `up`, dispatch it through the server conn, read
// the reply from `down`. This record and the plumbing below are the shared
// pair harness for every suite that drives the face over memory pipes: each
// suite's record carries its own host field, and lspserver.Server's host
// pointer is type-erased, so the shared wiring never names the concrete
// host type.
Lspface_Pair :: struct {
	up:     Pipe,
	down:   Pipe,
	send:   jsonrpc.Writer, // writes into up
	recv:   jsonrpc.Reader, // reads from down
	conn:   jsonrpc.Conn,   // the server's conn
	server: lspserver.Server,
	host:   Lspface_Host,
}

// lspface_pair_open allocates a pair record ($P carries up, down, send,
// recv, conn, server, host) and wires the transport: the fake-client
// writer/reader, then the server conn. finish initializes the record's
// host field and returns the configured lspserver.Server (its host pointer
// aims at that field); server_init binds the server to the conn.
lspface_pair_open :: proc($P: typeid, finish: proc(host, pair: rawptr, a: mem.Allocator) -> lspserver.Server) -> ^P {
	p := new(P, context.allocator)
	pipe_init(&p.up, context.allocator)
	pipe_init(&p.down, context.allocator)
	jsonrpc.writer_init(&p.send, pipe_write, &p.up)
	jsonrpc.reader_init(&p.recv, pipe_read, &p.down, 64 * 1024, context.allocator)

	jsonrpc.reader_init(&p.conn.reader, pipe_read, &p.up, 64 * 1024, context.allocator)
	jsonrpc.writer_init(&p.conn.writer, pipe_write, &p.down)
	jsonrpc.conn_init(&p.conn, p.conn.reader, p.conn.writer, context.allocator)

	p.server = finish(&p.host, p, context.allocator)
	lspserver.server_init(&p.server, &p.conn)
	return p
}

// lspface_pair_close releases a record opened by lspface_pair_open: the
// server, the server conn, the record's host (free_host), the fake-client
// reader, and both pipes. The tests drain the down pipe through
// lspface_send on every step, so the closes are quiet.
lspface_pair_close :: proc(p: ^$P, free_host: proc(host: rawptr)) {
	lspserver.server_destroy(&p.server)
	jsonrpc.conn_destroy(&p.conn)
	free_host(&p.host)
	jsonrpc.reader_destroy(&p.recv)
	pipe_close(&p.up)
	pipe_close(&p.down)
	free(p, context.allocator)
}

// lspface_finish_host initializes the face host — with its pair
// back-pointer, which the diagnostics callback's mid-pass didClose
// re-dispatch rides — and builds the face server value over it.
lspface_finish_host :: proc(host, pair: rawptr, a: mem.Allocator) -> lspserver.Server {
	h := cast(^Lspface_Host)host
	lspface_host_init(h, a)
	h.pair = cast(^Lspface_Pair)pair
	return {
		host            = host,
		name            = "aubade",
		version         = "test",
		initialize_host = lspface_init_host_cb,
		doc_open        = lspface_open_host_cb,
		doc_change      = lspface_change_host_cb,
		doc_close       = lspface_close_host_cb,
		highlights      = lspface_highlights_host_cb,
		diagnostics     = lspface_diagnostics_host_cb,
		readiness       = lspface_readiness_host_cb,
		relay           = lspface_relay_host_cb,
		text_for_uri    = lspface_text_host_cb,
		log             = lspface_log_host_cb,
		allocator       = a,
	}
}

lspface_free_host :: proc(host: rawptr) {
	lspface_host_destroy(cast(^Lspface_Host)host)
}

lspface_pair_init :: proc(t: ^testing.T) -> ^Lspface_Pair {
	return lspface_pair_open(Lspface_Pair, lspface_finish_host)
}

lspface_pair_destroy :: proc(p: ^Lspface_Pair) {
	lspface_pair_close(p, lspface_free_host)
}

// lspface_request writes one request frame (params must be valid JSON text,
// without the surrounding braces, or ""), dispatches it through the server
// conn, and returns the raw reply body. The body is a view into the temp
// allocator's frame scratch — used within the test step, never freed here.
lspface_request :: proc(t: ^testing.T, p: ^$P, id_text: string, method: string, params_inner: string) -> string {
	params := ""
	if params_inner != "" {
		params = strings.concatenate({`,"params":{`, params_inner, "}"}, context.temp_allocator)
	}
	body := strings.concatenate(
		{`{"jsonrpc":"2.0","id":`, id_text, `,"method":"`, method, `"`, params, "}"},
		context.temp_allocator,
	)
	return lspface_send(t, p, body)
}

// lspface_notify writes one notification frame and dispatches it. Unlike
// lspface_send it never drains the down pipe: a notification can produce
// server-initiated frames (the didClose clear publish), which stay there
// for the test to read.
lspface_notify :: proc(t: ^testing.T, p: ^$P, method: string, params_inner: string) {
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
	testing.expect(t, keep, "the server conn answered a framing-level rejection")
}

lspface_send :: proc(t: ^testing.T, p: ^$P, body: string) -> string {
	err := jsonrpc.write_frame(&p.send, json_bytes(body))
	testing.expectf(t, err == .None, "write_frame failed: %v", err)
	if err != .None {
		return ""
	}
	got, rerr := jsonrpc.read_frame(&p.conn.reader, context.temp_allocator)
	testing.expectf(t, rerr == .None, "read_frame from the up pipe failed: %v", rerr)
	if rerr != .None {
		return ""
	}
	keep := jsonrpc.conn_handle_body(&p.conn, got, context.temp_allocator)
	testing.expect(t, keep, "the server conn answered a framing-level rejection")
	// The reply (when the dispatch produced one) was written synchronously
	// into the down pipe during the dispatch above; an absent reply is an
	// empty pipe, checked without blocking.
	if len(p.down.buf) == 0 {
		return ""
	}
	reply, derr := jsonrpc.read_frame(&p.recv, context.temp_allocator)
	testing.expectf(t, derr == .None, "read_frame from the down pipe failed: %v", derr)
	if derr != .None {
		return ""
	}
	return string(reply)
}

// lspface_reply_code extracts error.code from a reply body (0 when the
// reply carries a result instead).
lspface_reply_code :: proc(t: ^testing.T, body: string) -> i64 {
	v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "reply did not parse: %s", body)
	if perr != nil {
		return 0
	}
	if ev, ok := jsonutil.obj_get(v, "error"); ok {
		if cv, found := jsonutil.obj_get(ev, "code"); found {
			return jsonutil.value_int(cv)
		}
	}
	return 0
}

// lspface_result_member digs a member out of a result-shaped reply body.
lspface_result_member :: proc(t: ^testing.T, body: string, key: string) -> json.Value {
	v, perr := json.parse_bytes(json_bytes(body), spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "reply did not parse: %s", body)
	if perr != nil {
		return nil
	}
	if result, ok := jsonutil.obj_get(v, "result"); ok {
		if m, found := jsonutil.obj_get(result, key); found {
			return m
		}
	}
	return nil
}

// lspface_caps_member reads result.capabilities.<key> — the LSP 3.17 home
// of the server's capability members (positionEncoding included).
lspface_caps_member :: proc(t: ^testing.T, body: string, key: string) -> json.Value {
	caps := lspface_result_member(t, body, "capabilities")
	if caps == nil {
		return nil
	}
	if m, found := jsonutil.obj_get(caps, key); found {
		return m
	}
	return nil
}

// lspface_tokens_data reads the semanticTokens data array out of a reply.
lspface_tokens_data :: proc(t: ^testing.T, body: string) -> []i64 {
	data_v := lspface_result_member(t, body, "data")
	if data_v == nil {
		testing.expectf(t, false, "no data member in reply: %s", body)
		return nil
	}
	items, ok := jsonutil.as_array(data_v)
	testing.expect(t, ok, "semanticTokens data is not an array")
	if !ok {
		return nil
	}
	out := make([]i64, len(items), context.temp_allocator)
	for item, i in items {
		out[i] = jsonutil.value_int(item)
	}
	return out
}

// lspface_default_initialize sends a plain initialize and asserts the reply
// parsed. Returns the raw reply body.
lspface_default_initialize :: proc(t: ^testing.T, p: ^Lspface_Pair, encodings_json: string) -> string {
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
	return body
}

// lspface_assert_legend checks the reply's semanticTokens legend against
// the mapping-table legend procs — the wire list must be derived, never a
// second declaration.
lspface_assert_legend :: proc(t: ^testing.T, body: string) {
	caps := lspface_result_member(t, body, "capabilities")
	testing.expect(t, caps != nil, "capabilities missing from the initialize result")
	if caps == nil {
		return
	}
	st, found := jsonutil.obj_get(caps, "semanticTokensProvider")
	testing.expect(t, found, "semanticTokensProvider missing from capabilities")
	if !found {
		return
	}
	legend, _ := jsonutil.obj_get(st, "legend")
	testing.expect(t, legend != nil, "legend missing")
	if legend == nil {
		return
	}
	types, _ := jsonutil.obj_get(legend, "tokenTypes")
	mods, _ := jsonutil.obj_get(legend, "tokenModifiers")
	want_types, want_type_count := lspserver.legend_token_types()
	got_types, ok := jsonutil.as_array(types)
	testing.expect(t, ok, "legend tokenTypes is not an array")
	if ok {
		testing.expectf(t, len(got_types) == want_type_count, "legend type count %d != derived %d", len(got_types), want_type_count)
		table := want_types
		for i in 0 ..< min(len(got_types), want_type_count) {
			testing.expectf(t, jsonutil.value_str(got_types[i]) == lspserver.token_type_name(table[i]), "legend type %d drifted from the tables", i)
		}
	}
	want_mods, want_mod_count := lspserver.legend_token_modifiers()
	got_mods, mok := jsonutil.as_array(mods)
	testing.expect(t, mok, "legend tokenModifiers is not an array")
	if mok {
		testing.expectf(t, len(got_mods) == want_mod_count, "legend modifier count %d != derived %d", len(got_mods), want_mod_count)
		mtable := want_mods
		for i in 0 ..< min(len(got_mods), want_mod_count) {
			testing.expectf(t, jsonutil.value_str(got_mods[i]) == lspserver.token_modifier_name(mtable[i]), "legend modifier %d drifted from the tables", i)
		}
	}
}

// lspface_assert_reconstruction folds a wire data array back into absolute
// positions and checks them against the expected table (which also pins
// the non-negative delta invariant).
lspface_assert_reconstruction :: proc(t: ^testing.T, data: []i64, want: []lspserver.Tok_Pos) {
	line, char: int
	for i in 0 ..< len(data) / 5 {
		d_line := data[i * 5 + 0]
		d_char := data[i * 5 + 1]
		length := data[i * 5 + 2]
		type_index := data[i * 5 + 3]
		mods := data[i * 5 + 4]
		testing.expectf(t, d_line >= 0 && d_char >= 0, "negative delta at token %d", i)
		if d_line > 0 {
			line += int(d_line)
			char = int(d_char)
		} else {
			char += int(d_char)
		}
		if i >= len(want) {
			testing.expectf(t, false, "more tokens than expected (at %d)", i)
			return
		}
		testing.expectf(
			t,
			line == want[i].line && char == want[i].char &&
			length == i64(want[i].length) && type_index == i64(want[i].type_index) &&
			mods == i64(want[i].modifiers),
			"token %d reconstructed (%d,%d,%d,%d,%d) != expected (%d,%d,%d,%d,%d)",
			i, line, char, length, type_index, mods,
			want[i].line, want[i].char, want[i].length, want[i].type_index, want[i].modifiers,
		)
	}
	testing.expectf(t, len(data)/5 == len(want), "token count %d != expected %d", len(data)/5, len(want))
}

// --- tests ---------------------------------------------------------------------

@(test)
lspface_initialize_negotiates_utf8 :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	body := lspface_default_initialize(t, p, `["utf-8","utf-16"]`)
	enc := lspface_caps_member(t, body, "positionEncoding")
	testing.expectf(t, enc != nil && jsonutil.value_str(enc) == "utf-8", "a utf-8 offer must select utf-8, got %s", body)
}

@(test)
lspface_initialize_defaults_utf16 :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// No positionEncodings member at all: the specification's safe
	// default applies.
	body := lspface_default_initialize(t, p, "")
	enc := lspface_caps_member(t, body, "positionEncoding")
	testing.expectf(t, enc != nil && jsonutil.value_str(enc) == "utf-16", "an absent offer must default to utf-16, got %s", body)

	// A second initialize is refused, not re-served.
	body2 := lspface_request(t, p, "2", lsp.METHOD_INITIALIZE, "")
	testing.expect(t, body2 != "", "the second initialize must be refused")
	testing.expectf(t, lspface_reply_code(t, body2) == -32600, "the second initialize must answer InvalidRequest, got %s", body2)
}

@(test)
lspface_initialize_offers_utf16_only :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	body := lspface_default_initialize(t, p, `["utf-16","utf-32"]`)
	enc := lspface_caps_member(t, body, "positionEncoding")
	testing.expectf(t, enc != nil && jsonutil.value_str(enc) == "utf-16", "an offer without utf-8 must select utf-16, got %s", body)
}

@(test)
lspface_initialize_capabilities :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	body := lspface_default_initialize(t, p, `["utf-8"]`)
	caps := lspface_result_member(t, body, "capabilities")
	testing.expect(t, caps != nil, "capabilities missing")
	if caps == nil {
		return
	}
	sync_v, found := jsonutil.obj_get(caps, "textDocumentSync")
	testing.expect(t, found, "textDocumentSync must be declared")
	if found {
		testing.expectf(t, jsonutil.obj_get_int(sync_v, "change") == 1, "textDocumentSync.change must be Full (1)")
		oc, oc_found := jsonutil.obj_get(sync_v, "openClose")
		testing.expectf(t, oc_found && jsonutil.value_bool(oc), "textDocumentSync.openClose must be true")
		save_v, save_found := jsonutil.obj_get(sync_v, "save")
		testing.expect(t, save_found, "textDocumentSync.save must be declared")
		if save_found {
			inc, inc_found := jsonutil.obj_get(save_v, "includeText")
			testing.expectf(t, inc_found && !jsonutil.value_bool(inc), "save.includeText must be false")
		}
	}
	_, found = jsonutil.obj_get(caps, "documentSymbolProvider")
	testing.expect(t, found, "documentSymbolProvider must be advertised")
	// The definition/declaration jump is answered out of the daemon's own
	// index and advertised statically; references stays dynamically
	// registered behind a live server.
	def_v, def_found := jsonutil.obj_get(caps, "definitionProvider")
	testing.expectf(t, def_found && jsonutil.value_bool(def_v), "definitionProvider must be advertised statically")
	decl_v, decl_found := jsonutil.obj_get(caps, "declarationProvider")
	testing.expectf(t, decl_found && jsonutil.value_bool(decl_v), "declarationProvider must be advertised statically")
	_, refs_found := jsonutil.obj_get(caps, "referencesProvider")
	testing.expect(t, !refs_found, "referencesProvider must not be advertised statically")
	// The negotiated encoding is a capability member (LSP 3.17
	// ServerCapabilities.positionEncoding), never a result-top-level one.
	enc_v, enc_found := jsonutil.obj_get(caps, "positionEncoding")
	testing.expectf(t, enc_found && jsonutil.value_str(enc_v) == "utf-8",
		"positionEncoding must live inside capabilities, got %v", enc_v)
	lspface_assert_legend(t, body)

	info := lspface_result_member(t, body, "serverInfo")
	name_v, _ := jsonutil.obj_get(info, "name")
	testing.expectf(t, name_v != nil && jsonutil.value_str(name_v) == "aubade", "serverInfo.name must be aubade")
}

@(test)
lspface_request_before_initialize :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	body := lspface_request(t, p, "1", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///x.go"}`)
	testing.expect(t, body != "", "a request before initialize must be answered")
	testing.expectf(t, lspface_reply_code(t, body) == -32002, "expected -32002, got %s", body)
}

@(test)
lspface_shutdown_exit_clean :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	body := lspface_request(t, p, "2", lsp.METHOD_SHUTDOWN, "")
	testing.expect(t, body != "", "shutdown must be answered")
	testing.expect(t, strings.contains(body, `"result":null`), "the shutdown result must be null")
	testing.expectf(t, lspserver.server_exit_status(&p.server) == .Running, "the exit status must stay Running until exit")

	// A request after shutdown is refused with InvalidRequest.
	body2 := lspface_request(t, p, "3", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///x.go"}`)
	testing.expectf(t, lspface_reply_code(t, body2) == -32600, "a post-shutdown request must answer InvalidRequest, got %s", body2)

	lspface_notify(t, p, lsp.METHOD_EXIT, "")
	testing.expectf(t, lspserver.server_exit_status(&p.server) == .Clean, "exit after shutdown must be Clean")
	testing.expect(t, lspserver.server_exit_code(&p.server) == 0, "a clean exit maps to code 0")
}

@(test)
lspface_exit_without_shutdown_forced :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_EXIT, "")
	testing.expectf(t, lspserver.server_exit_status(&p.server) == .Forced, "exit without shutdown must be Forced")
	testing.expect(t, lspserver.server_exit_code(&p.server) == 1, "a forced exit maps to code 1")
}

@(test)
lspface_doc_sync_callbacks :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)

	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":3,"text":"package main"}`)
	testing.expectf(t, len(p.host.opens) == 1, "didOpen must reach the host callback")
	if len(p.host.opens) == 1 {
		o := p.host.opens[0]
		testing.expect(t, o.uri == "file:///w/prog.go" && o.language_id == "go" && o.version == 3 && o.text == "package main", "didOpen params were not parsed faithfully")
	}
	testing.expect(t, lspserver.server_is_tracking_uri(&p.server, "file:///w/prog.go"), "the open document must enter the view")

	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":4},"contentChanges":[{"text":"package main // changed"}]`)
	testing.expectf(t, len(p.host.changes) == 1, "didChange must reach the host callback")
	if len(p.host.changes) == 1 {
		c := p.host.changes[0]
		testing.expect(t, c.uri == "file:///w/prog.go" && c.version == 4 && c.text == "package main // changed", "didChange params were not parsed faithfully")
	}

	// A ranged change violates the Full-sync contract: dropped, logged
	// once, and never forwarded.
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":5},"contentChanges":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":7}},"text":"gone"}]`)
	testing.expectf(t, len(p.host.changes) == 1, "a ranged change must not reach the host callback")
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":6},"contentChanges":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"text":"x"}]`)
	testing.expectf(t, len(p.host.logs) == 1, "the ranged-change refusal must log once per file, got %d", len(p.host.logs))

	// didClose forwards and releases the view entry.
	lspface_notify(t, p, lsp.METHOD_DID_CLOSE, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, len(p.host.closes) == 1 && p.host.closes[0] == "file:///w/prog.go", "didClose must reach the host callback")
	testing.expect(t, !lspserver.server_is_tracking_uri(&p.server, "file:///w/prog.go"), "didClose must release the view entry")
}

@(test)
lspface_did_change_not_open_is_silent :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	// A change for a document that was never opened: dropped with no
	// callback and no log (a keystream for an unopened document must
	// not become a log storm).
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/other.go","version":1},"contentChanges":[{"text":"x"}]`)
	testing.expect(t, len(p.host.changes) == 0, "a change for an unopened document must not reach the host callback")
	testing.expect(t, len(p.host.logs) == 0, "a change for an unopened document must stay silent")
}

@(test)
lspface_semantic_tokens_utf8_roundtrip :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8","utf-16"]`)
	// Text (byte offsets): "package"[0,7) " main"[7,12) "\n"[12]
	// "\n"[13] "func "[14,19) "main"[19,23).
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n\nfunc main() {}\n"}`)

	caps := make([]lspserver.Capture_Hit, 3, context.temp_allocator)
	caps[0] = {capture = "keyword", start_byte = 0, end_byte = 7}
	caps[1] = {capture = "function", start_byte = 8, end_byte = 12}
	caps[2] = {capture = "function", start_byte = 19, end_byte = 23}
	lspface_set_captures(&p.host, caps)
	// A synced-document answer: the captures index the open text.
	p.host.highlights.has_version = true
	defer lspface_clear_captures(&p.host)

	// Wire type values are legend ranks (the rank among the types the
	// mapping tables emit), read from the legend procs the server's rank
	// cache is derived from.
	kw, _ := lspserver.legend_type_index(.Keyword)
	fn, _ := lspserver.legend_type_index(.Function)
	want := make([]lspserver.Tok_Pos, 3, context.temp_allocator)
	want[0] = {line = 0, char = 0, length = 7, type_index = kw, modifiers = 0} // keyword
	want[1] = {line = 0, char = 8, length = 4, type_index = fn, modifiers = 0} // function
	want[2] = {line = 2, char = 5, length = 4, type_index = fn, modifiers = 0} // function

	body := lspface_request(t, p, "2", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expect(t, body != "", "semanticTokens/full must be answered")
	data := lspface_tokens_data(t, body)
	lspface_assert_reconstruction(t, data, want)
}

@(test)
lspface_semantic_tokens_utf16_columns :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// The client offers only utf-16: columns become UTF-16 code units,
	// derived through the open document's text. "héllo" holds one
	// two-byte rune, so byte columns and utf-16 columns diverge.
	// Bytes: x[0] ' '[:] '='[3] ' '"[5] h[6] é[7,8] l l o '"[12] \n[13]
	// y[14] ' ':'[16] '='[17] ' '1[19] \n[20].
	lspface_default_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":1,"text":"x := \"héllo\"\ny := 1\n"}`)

	caps := make([]lspserver.Capture_Hit, 3, context.temp_allocator)
	caps[0] = {capture = "operator", start_byte = 2, end_byte = 4}
	caps[1] = {capture = "string", start_byte = 5, end_byte = 13} // "héllo": 8 bytes, 7 utf-16 units
	caps[2] = {capture = "number", start_byte = 19, end_byte = 20}
	lspface_set_captures(&p.host, caps)
	// A synced-document answer: the captures index the open text.
	p.host.highlights.has_version = true
	defer lspface_clear_captures(&p.host)

	op, _ := lspserver.legend_type_index(.Operator)
	st, _ := lspserver.legend_type_index(.String)
	num, _ := lspserver.legend_type_index(.Number)
	want := make([]lspserver.Tok_Pos, 3, context.temp_allocator)
	want[0] = {line = 0, char = 2, length = 2, type_index = op, modifiers = 0}  // operator
	want[1] = {line = 0, char = 5, length = 7, type_index = st, modifiers = 0}  // string
	want[2] = {line = 1, char = 5, length = 1, type_index = num, modifiers = 0} // number

	body := lspface_request(t, p, "2", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.thing"}`)
	testing.expect(t, body != "", "semanticTokens/full must be answered")
	data := lspface_tokens_data(t, body)
	lspface_assert_reconstruction(t, data, want)
}

@(test)
lspface_semantic_tokens_decline_ladder :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main"}`)

	p.host.highlights.decline = "no_grammar"
	body := lspface_request(t, p, "2", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	data := lspface_tokens_data(t, body)
	testing.expectf(t, len(data) == 0, "a declined document answers empty data, got %d ints", len(data))
	// Second request: still empty, and the latch keeps the log at one
	// line for the file while it stays open.
	body2 := lspface_request(t, p, "3", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	data2 := lspface_tokens_data(t, body2)
	testing.expectf(t, len(data2) == 0, "the second declined request answers empty data too")
	testing.expectf(t, len(p.host.logs) == 1, "the decline must log once per file, got %d lines", len(p.host.logs))
	testing.expectf(t, strings.contains(p.host.logs[0], "no_grammar"), "the decline log names the decline kind")

	// A fetch failure degrades the same way: empty data (the file's
	// one-line latch is already spent, so this stays quiet too).
	p.host.highlights.decline = ""
	p.host.highlights.failed = true
	p.host.highlights.err_message = "the daemon link is down"
	body3 := lspface_request(t, p, "4", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	data3 := lspface_tokens_data(t, body3)
	testing.expectf(t, len(data3) == 0, "a failed fetch answers empty data")

	// Re-open clears the latch: the next decline logs again.
	p.host.highlights.failed = false
	p.host.highlights.decline = "source_too_large"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":2,"text":"package main"}`)
	lspface_request(t, p, "5", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, len(p.host.logs) == 2, "a re-open must clear the per-file latch, got %d lines", len(p.host.logs))
}

@(test)
lspface_semantic_tokens_unknown_document :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	body := lspface_request(t, p, "1", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/never-opened.go"}`)
	data := lspface_tokens_data(t, body)
	testing.expectf(t, len(data) == 0, "tokens for an unopened document answer empty data")
	testing.expect(t, len(p.host.logs) == 0, "an unopened document is a normal state, not a refusal")
	testing.expect(t, p.host.highlights_calls == 0, "an unopened document must not reach the host")
}

// The disk-truth degradation: an answer without a synced version (the
// daemon's buffer for the document was evicted) carries captures that
// index disk bytes, not the open view's text — even when they fit inside
// the view's bounds, the currency rule answers empty data rather than
// encode them against the wrong bytes.
@(test)
lspface_semantic_tokens_disk_truth_answers_empty :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":3,"text":"package main\n"}`)

	// The captures index the disk's LF-folded spelling — shorter than the
	// view's CRLF text, so a bounds check alone would pass them through.
	caps := make([]lspserver.Capture_Hit, 1, context.temp_allocator)
	caps[0] = {capture = "keyword", start_byte = 0, end_byte = 7}
	lspface_set_captures(&p.host, caps)
	defer lspface_clear_captures(&p.host)
	p.host.highlights.has_version = false

	body := lspface_request(t, p, "2", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///w/prog.go"}`)
	data := lspface_tokens_data(t, body)
	testing.expectf(t, len(data) == 0, "disk-truth captures must answer empty data, got %d ints", len(data))
	testing.expectf(t, len(p.host.logs) == 1, "the disk-truth degradation logs once per open, got %d lines", len(p.host.logs))
	testing.expectf(t, strings.contains(p.host.logs[0], "disk truth"), "the log names the disk-truth degradation: %s", p.host.logs[0])
}

@(test)
lspface_unknown_request_and_notification :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	// A method the face does not implement stays unregistered: completion is
	// out of v1.1 scope, so it answers MethodNotFound.
	body := lspface_request(t, p, "9", "textDocument/completion", `"textDocument":{"uri":"file:///w/prog.go"}`)
	testing.expectf(t, lspface_reply_code(t, body) == -32601, "an unknown request must answer MethodNotFound, got %s", body)

	// An unknown notification is ignored: no reply frame, no crash.
	lspface_notify(t, p, "workspace/didChangeConfiguration", `"settings":{}`)
	testing.expectf(t, len(p.down.buf) == 0, "an unknown notification must not produce a reply")
}

@(test)
lspface_initialize_without_root_fails :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// The fake initialize callback returns its preset failure; the face
	// must surface it as the initialize error.
	p.host.init_failure = "no project root: initialize carried neither rootUri nor workspace folders, and no --project was given"
	body := lspface_request(t, p, "1", lsp.METHOD_INITIALIZE, "")
	testing.expect(t, body != "", "initialize must be answered")
	testing.expectf(t, lspface_reply_code(t, body) == -32600, "a failed root resolution must answer InvalidRequest, got %s", body)
	// The server is not initialized: the request gate stays closed.
	body2 := lspface_request(t, p, "2", lsp.METHOD_SEMANTIC_TOKENS_FULL, `"textDocument":{"uri":"file:///x"}`)
	testing.expectf(t, lspface_reply_code(t, body2) == -32002, "a failed initialize must keep the gate closed, got %s", body2)
}

@(test)
lspface_root_uri_reaches_the_host :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_request(t, p, "1", lsp.METHOD_INITIALIZE, `"rootUri":"file:///home/dev/proj","capabilities":{},"workspaceFolders":[{"uri":"file:///home/dev/other"}]`)
	testing.expectf(t, p.host.init_root_uri == "file:///home/dev/proj", "rootUri must reach the host verbatim, got %q", p.host.init_root_uri)
	testing.expectf(t, len(p.host.init_folders) == 1 && p.host.init_folders[0] == "file:///home/dev/other", "the workspace folders must reach the host")
}

// --- helpers the tests share ------------------------------------------------

lspface_set_captures :: proc(h: ^Lspface_Host, caps: []lspserver.Capture_Hit) {
	lspface_clear_captures(h)
	dyn := make([dynamic]lspserver.Capture_Hit, 0, len(caps), h.allocator)
	for c in caps {
		append(&dyn, lspserver.Capture_Hit{capture = strings.clone(c.capture, h.allocator), start_byte = c.start_byte, end_byte = c.end_byte})
	}
	h.highlights.captures = dyn[:]
}

lspface_clear_captures :: proc(h: ^Lspface_Host) {
	for cap in h.highlights.captures {
		delete(cap.capture, h.allocator)
	}
	delete(h.highlights.captures)
	h.highlights.captures = nil
}

lspface_set_diagnostics :: proc(h: ^Lspface_Host, hits: []lspserver.Diag_Hit) {
	lspface_clear_diagnostics(h)
	dyn := make([dynamic]lspserver.Diag_Hit, 0, len(hits), h.allocator)
	for hit in hits {
		append(&dyn, lspserver.Diag_Hit{start_byte = hit.start_byte, end_byte = hit.end_byte, message = strings.clone(hit.message, h.allocator)})
	}
	h.diagnostics.hits = dyn[:]
}

lspface_clear_diagnostics :: proc(h: ^Lspface_Host) {
	for hit in h.diagnostics.hits {
		delete(hit.message, h.allocator)
	}
	delete(h.diagnostics.hits)
	h.diagnostics.hits = nil
}

// lspface_set_relay_result presets the Relay_Host answer (owned clones in
// the host's allocator).
lspface_set_relay_result :: proc(h: ^Lspface_Host, locs: []lspserver.Relay_Location) {
	lspface_clear_relay_result(h)
	h.relay_locs = make([dynamic]lspserver.Relay_Location, 0, len(locs), h.allocator)
	for l in locs {
		append(&h.relay_locs, lspserver.Relay_Location{
			uri      = strings.clone(l.uri, h.allocator),
			line     = l.line,
			col      = l.col,
			has_end  = l.has_end,
			end_line = l.end_line,
			end_col  = l.end_col,
		})
	}
}

lspface_clear_relay_result :: proc(h: ^Lspface_Host) {
	for l in h.relay_locs {
		delete(l.uri, h.allocator)
	}
	delete(h.relay_locs)
	h.relay_locs = nil
}

// lspface_set_text presets one Text_For_Uri_Host answer.
lspface_set_text :: proc(h: ^Lspface_Host, uri, text: string) {
	append(&h.texts, Lspface_Text{uri = strings.clone(uri, h.allocator), text = strings.clone(text, h.allocator)})
}

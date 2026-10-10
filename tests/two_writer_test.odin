// Two-writer integrity tests: the workspace/applyEdit round trip
// between the daemon's edit routing and the lsp child. Two layers: the
// face-level tests drive lspserver.server_apply_edits over the synchronous
// pipe harness (capability gate, documentChanges forward, utf-8 column
// conversion), and the daemon-level tests run the full round trip over the
// channel transport — two fake lsp children (the owner and a bystander), a
// scripted applyEdit sink, and the didChange echo the confirmation reads.
// Arrivals are observed through bounded polls (the suite's no-sleeps
// rule); the one long wait is the injected short deadline.
package tests

import "core:encoding/json"
import "core:sync/chan"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "src:daemon"
import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:platform"
import "src:rpc"
import "src:svc"
import "src:util"

// ---------------------------------------------------------------------------
// Diff reduction: edit_range_of_diff over multi-byte text
// ---------------------------------------------------------------------------

// two_writer_runes_whole reports whether s is whole UTF-8 runes end to
// end: every lead byte's rune fits inside s, and no position starts
// inside a rune.
two_writer_runes_whole :: proc(s: string) -> bool {
	i := 0
	for i < len(s) {
		b := s[i]
		if (b & 0xC0) == 0x80 {
			return false
		}
		n := 1
		if (b & 0xE0) == 0xC0 {
			n = 2
		} else if (b & 0xF0) == 0xE0 {
			n = 3
		} else if (b & 0xF8) == 0xF0 {
			n = 4
		}
		if i+n > len(s) {
			return false
		}
		for k := 1; k < n; k += 1 {
			if (s[i+k] & 0xC0) != 0x80 {
				return false
			}
		}
		i += n
	}
	return true
}

// two_writer_apply_range splices one edit (UTF-16 range + replacement)
// back onto its basis text — the math the receiving editor runs — so a
// diff can be asserted round-trip exact. Returns a clone owned by `a`.
two_writer_apply_range :: proc(text: string, rng: svc.Edit_Range, mid: string, a: mem.Allocator) -> string {
	starts := util.line_start_offsets(text, context.temp_allocator)
	if len(starts) == 0 {
		return strings.clone(text, a)
	}
	offset_at :: proc(starts: []int, text: string, line, col: int) -> int {
		ln := line
		if ln < 0 {
			ln = 0
		}
		if ln >= len(starts) {
			ln = len(starts) - 1
		}
		start := starts[ln]
		line_end := len(text)
		if ln+1 < len(starts) {
			line_end = starts[ln+1]
		}
		return start + util.utf16_col_to_byte_offset(text[start:line_end], col)
	}
	so := offset_at(starts, text, rng.sl, rng.sc)
	eo := offset_at(starts, text, rng.el, rng.ec)
	return strings.concatenate({text[:so], mid, text[eo:]}, a)
}

// One diff-reduction case: the transform `before` -> `after`, and the
// replacement the reduction must produce.
Diff_Case :: struct {
	name, before, after, want_mid: string,
}

// The rune-boundary back-off: every multi-byte case below stops at least
// one of the common-prefix/suffix scans mid-rune. The reduction must keep
// the replacement whole runes, and applying the returned range and
// replacement to the old text must reproduce the new text exactly. The
// append and delete cases pin the boundary scans' pure shapes: an append
// leaves the prefix scan at the end of `old` (already a rune boundary),
// and a delete yields an empty replacement.
@(test)
two_writer_edit_range_of_diff_rune_boundaries :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// а U+0430 (D0 B0) -> б U+0431 (D0 B1): differs in its last byte, so
	// the prefix scan stops mid-rune. é U+00E9 (C3 A9) -> á U+00E1 (C3 A1):
	// the same shape, two-byte runes. あ U+3042 (E3 81 82) -> い U+3044
	// (E3 81 84): the CJK three-byte case, again last-byte. あ -> 。 U+3002
	// (E3 80 82): differs mid-rune, so the SUFFIX scan walks past the
	// matching last byte and stops mid-rune. The mixed case splits both
	// scans, and the backed-off replacement spans two runes.
	cases := []Diff_Case{
		{name = "cyrillic single rune", before = "а", after = "б", want_mid = "б"},
		{name = "accented latin", before = "café", after = "cafá", want_mid = "á"},
		{name = "cjk three bytes", before = "あいう", after = "あえう", want_mid = "え"},
		{name = "suffix-side split", before = "xあ", after = "x。", want_mid = "。"},
		{name = "prefix and suffix split", before = "éあ!", after = "á。!", want_mid = "á。"},
		{name = "pure append", before = "abc", after = "abcdef", want_mid = "def"},
		{name = "pure delete", before = "abcdef", after = "abc", want_mid = ""},
	}
	for c in cases {
		rng, mid, ok := svc.edit_range_of_diff(c.before, c.after, a)
		if !ok {
			testing.expectf(t, false, "%s: the texts differ; the reduction must produce an edit", c.name)
			continue
		}
		testing.expectf(t, mid == c.want_mid, "%s: the replacement must be %q, got %q", c.name, c.want_mid, mid)
		testing.expectf(t, two_writer_runes_whole(mid), "%s: the replacement must be whole runes, got %q", c.name, mid)
		got := two_writer_apply_range(c.before, rng, mid, a)
		testing.expectf(t, got == c.after, "%s: applying the edit must reproduce the new text, got %q", c.name, got)
	}
}

// ---------------------------------------------------------------------------
// Face-level: server_apply_edits over the lspface pipe harness
// ---------------------------------------------------------------------------

// two_writer_face_initialize runs initialize with the positionEncodings
// offer plus one extra capabilities member (the workspace applyEdit bits).
two_writer_face_initialize :: proc(t: ^testing.T, p: ^Lspface_Pair, encodings, workspace_caps: string) {
	params := strings.concatenate(
		{`"capabilities":{"general":{"positionEncodings":`, encodings, "}", workspace_caps, "}"},
		context.temp_allocator,
	)
	body := lspface_request(t, p, "1", lsp.METHOD_INITIALIZE, params)
	testing.expect(t, body != "", "initialize produced no reply")
	testing.expectf(t, lspface_reply_code(t, body) == 0, "initialize answered an error: %s", body)
}

// Two_Writer_Face_Apply carries one helper thread's apply call: the
// params value is read-only, the verdict fields are written by the helper
// and read after the done signal.
Two_Writer_Face_Apply :: struct {
	p:      ^Lspface_Pair,
	params: json.Value,
	done:   chan.Chan(bool),
	applied: bool,
	reason: string,
}

two_writer_face_apply_entry :: proc(args: ^Two_Writer_Face_Apply) {
	args.applied, args.reason = lspserver.server_apply_edits(&args.p.server, args.params, context.allocator, 4000)
	chan.send(chan.as_send(args.done), true)
}

// two_writer_face_read_request pops one frame off the face's down pipe
// (the editor role reading its inbound workspace/applyEdit) and returns
// the parsed envelope.
two_writer_face_read_request :: proc(t: ^testing.T, p: ^Lspface_Pair) -> json.Value {
	// The frame lands from the helper thread: a bounded arrival wait, not
	// a single check (2 ms slices, hard deadline).
	deadline := platform.mono_ms() + 5000
	for len(p.down.buf) == 0 {
		if platform.mono_ms() >= deadline {
			testing.expect(t, false, "expected a workspace/applyEdit request; the pipe stayed empty")
			return nil
		}
		time.sleep(2 * time.Millisecond)
	}
	body, rerr := jsonrpc.read_frame(&p.recv, context.temp_allocator)
	testing.expectf(t, rerr == .None, "read_frame from the down pipe failed: %v", rerr)
	if rerr != .None {
		return nil
	}
	v, perr := json.parse_bytes(body, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	testing.expectf(t, perr == nil, "applyEdit request did not parse: %s", string(body))
	if perr != nil {
		return nil
	}
	method_v, has_method := jsonutil.obj_get(v, "method")
	testing.expectf(
		t,
		has_method && jsonutil.value_str(method_v) == lsp.METHOD_APPLY_EDIT,
		"expected workspace/applyEdit, got: %s",
		string(body),
	)
	return v
}

// two_writer_face_answer writes the editor's applyEdit verdict back
// through the up pipe (lspface_send pumps it into the pending slot).
two_writer_face_answer :: proc(t: ^testing.T, p: ^Lspface_Pair, req: json.Value, applied: bool) {
	id := jsonutil.obj_get_int(req, "id")
	body := strings.concatenate(
		{`{"jsonrpc":"2.0","id":`, util.int_to_dec(int(id), context.temp_allocator), `,"result":{"applied":`, applied ? "true" : "false", "}}"},
		context.temp_allocator,
	)
	lspface_send(t, p, body)
}

// two_writer_apply_params builds one svc.edit/apply params value (the
// daemon wire shape: flat per-document {uri, version, edits} with a single
// edit — the shape every scenario sends).
two_writer_apply_params :: proc(
	a: mem.Allocator,
	uri: string,
	version: i32,
	sl, sc, el, ec: int,
	new_text: string,
) -> json.Value {
	start := jsonutil.json_object(2, a)
	jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(sl)))
	jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(sc)))
	end := jsonutil.json_object(2, a)
	jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(el)))
	jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(ec)))
	rng := jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&rng, "start", start)
	jsonutil.obj_set_object(&rng, "end", end)
	edit := jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&edit, "range", rng)
	jsonutil.obj_set(&edit, "new_text", jsonutil.json_string(new_text))
	edits := make([dynamic]json.Value, 0, 1, a)
	append(&edits, json.Value(json.Object(edit)))
	change := jsonutil.json_object(3, a)
	jsonutil.obj_set(&change, "uri", jsonutil.json_string(uri))
	jsonutil.obj_set(&change, "version", jsonutil.json_int(i64(version)))
	jsonutil.obj_set(&change, "edits", jsonutil.json_array(edits[:], a))
	changes := make([dynamic]json.Value, 0, 1, a)
	append(&changes, json.Value(json.Object(change)))
	params := jsonutil.json_object(1, a)
	jsonutil.obj_set(&params, "document_changes", jsonutil.json_array(changes[:], a))
	return json.Value(json.Object(params))
}

// two_writer_face_changes digs edit.documentChanges[0] out of an
// applyEdit request (the pinned form's presence IS an assertion: the
// version-less `changes` map never appears).
two_writer_face_changes :: proc(t: ^testing.T, req: json.Value) -> json.Value {
	params_v, has_params := jsonutil.obj_get(req, "params")
	if !has_params {
		testing.expect(t, false, "applyEdit request carries no params")
		return nil
	}
	edit, has_edit := jsonutil.obj_get(params_v, "edit")
	if !has_edit {
		testing.expect(t, false, "applyEdit request carries no edit")
		return nil
	}
	changes_v, has_changes := jsonutil.obj_get(edit, "documentChanges")
	if !has_changes {
		testing.expect(t, false, "applyEdit must carry edit.documentChanges (never the changes form)")
		return nil
	}
	changes, is_arr := jsonutil.as_array(changes_v)
	testing.expectf(t, is_arr && len(changes) == 1, "edit.documentChanges must carry the one change")
	if !is_arr || len(changes) == 0 {
		return nil
	}
	return changes[0]
}

two_writer_member_str :: proc(v: json.Value, key: string) -> string {
	if m, ok := jsonutil.obj_get(v, key); ok {
		return jsonutil.value_str(m)
	}
	return ""
}

two_writer_face_range :: proc(t: ^testing.T, edit: json.Value) -> (sl, sc, el, ec: i64) {
	rng_v, ok := jsonutil.obj_get(edit, "range")
	if !ok {
		testing.expect(t, false, "edit carries no range")
		return
	}
	start, sok := jsonutil.obj_get(rng_v, "start")
	end, eok := jsonutil.obj_get(rng_v, "end")
	if !sok || !eok {
		testing.expect(t, false, "edit range carries no start or end")
		return
	}
	sl = jsonutil.obj_get_int(start, "line")
	sc = jsonutil.obj_get_int(start, "character")
	el = jsonutil.obj_get_int(end, "line")
	ec = jsonutil.obj_get_int(end, "character")
	return
}

// The capability gate at the child face: an editor that never declared
// workspace.applyEdit (or documentChanges) is refused in place —
// applied=false with a reason, and NO frame reaches the editor.
@(test)
two_writer_face_capability_gate :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// Initialize with no workspace capability members at all.
	_ = lspface_default_initialize(t, p, `["utf-16"]`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	params := two_writer_apply_params(a, "file:///w/prog.go", 1, 0, 7, 1, 0, "text")
	applied, reason := lspserver.server_apply_edits(&p.server, params, a, 1000)
	testing.expect(t, !applied, "an editor without applyEdit must not report the edit applied")
	testing.expectf(t, strings.contains(reason, "applyEdit"), "the refusal must name the missing capability: %s", reason)
	testing.expectf(t, len(p.down.buf) == 0, "no workspace/applyEdit may reach the editor without the capability")
}

// The forward: a capable editor receives ONE workspace/applyEdit whose
// edit.documentChanges carries the version-pinned TextDocumentEdit — the
// view's own uri spelling, the pinned version, UTF-16 columns untouched.
@(test)
two_writer_face_forwards_document_changes :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	two_writer_face_initialize(t, p, `["utf-16"]`, `,"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true}}`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":7,"text":"package main\n"}`)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	params := two_writer_apply_params(a, "file:///w/prog.go", 7, 0, 7, 1, 0, "text")
	args := new(Two_Writer_Face_Apply, context.allocator)
	args^ = {p = p, params = params}
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expectf(t, derr == nil, "done chan create failed: %v", derr)
	if derr != nil {
		return
	}
	args.done = done
	thr := thread.create_and_start_with_poly_data(args, two_writer_face_apply_entry, self_cleanup = false)

	req := two_writer_face_read_request(t, p)
	if req != nil {
		if change := two_writer_face_changes(t, req); change != nil {
			td, has_td := jsonutil.obj_get(change, "textDocument")
			testing.expect(t, has_td, "the change carries no textDocument")
			if has_td {
				testing.expectf(t, two_writer_member_str(td, "uri") == "file:///w/prog.go", "the change must use the view's own uri spelling")
				testing.expectf(t, jsonutil.obj_get_int(td, "version") == 7, "the change must pin the observed version")
			}
			edits_v, has_edits := jsonutil.obj_get(change, "edits")
			edits, is_arr := jsonutil.as_array(edits_v)
			testing.expectf(t, has_edits && is_arr && len(edits) == 1, "the change must carry the one edit")
			if has_edits && is_arr && len(edits) == 1 {
				sl, sc, el, ec := two_writer_face_range(t, edits[0])
				testing.expectf(t, sl == 0 && sc == 7 && el == 1 && ec == 0, "utf-16 columns must pass through untouched, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
				nt := two_writer_member_str(edits[0], "newText")
				testing.expectf(t, nt == "text", "the new text must forward verbatim, got %q", nt)
			}
		}
		two_writer_face_answer(t, p, req, true)
	}

	sent, _ := chan.recv(chan.as_recv(args.done))
	testing.expect(t, sent && args.applied, "the editor's applied=true must surface")
	testing.expectf(t, args.reason == "", "an applied answer carries no reason, got %q", args.reason)
	thread.join(thr)
	free(thr, context.allocator)
	chan.destroy(args.done)
	free(args, context.allocator)
}

// The editor's rejection names its reason through ApplyWorkspaceEditResult's
// failureReason member (LSP 3.17) — the field the face must read, never the
// svc leg's own "reason" spelling.
@(test)
two_writer_face_rejection_carries_failure_reason :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	two_writer_face_initialize(t, p, `["utf-16"]`, `,"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true}}`)
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":7,"text":"package main\n"}`)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	params := two_writer_apply_params(a, "file:///w/prog.go", 7, 0, 7, 1, 0, "text")
	args := new(Two_Writer_Face_Apply, context.allocator)
	args^ = {p = p, params = params}
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expectf(t, derr == nil, "done chan create failed: %v", derr)
	if derr != nil {
		return
	}
	args.done = done
	thr := thread.create_and_start_with_poly_data(args, two_writer_face_apply_entry, self_cleanup = false)

	req := two_writer_face_read_request(t, p)
	if req != nil {
		id := jsonutil.obj_get_int(req, "id")
		body := strings.concatenate(
			{`{"jsonrpc":"2.0","id":`, util.int_to_dec(int(id), context.temp_allocator), `,"result":{"applied":false,"failureReason":"Contents changed"}}`},
			context.temp_allocator,
		)
		lspface_send(t, p, body)
	}

	sent, _ := chan.recv(chan.as_recv(args.done))
	testing.expect(t, sent && !args.applied, "the editor's applied=false must surface")
	testing.expectf(t, args.reason == "Contents changed", "the rejection must carry the editor's failureReason text, got %q", args.reason)
	thread.join(thr)
	free(thr, context.allocator)
	chan.destroy(args.done)
	free(args, context.allocator)
}

// Under a utf-8 connection the incoming UTF-16 columns convert through the
// open view's own bytes (the relay discipline) — never a UTF-16 number in a
// byte column.
@(test)
two_writer_face_utf8_converts_columns :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	two_writer_face_initialize(t, p, `["utf-8"]`, `,"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true}}`)
	// Line 0 spans utf-16 0..12: `"`[5] h6 é7 l8 l9 o10 `"11 — utf-16
	// (0,5)-(0,11) is bytes (0,5)-(0,12).
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":2,"text":"x := \"héllo\"\ny := 1\n"}`)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	params := two_writer_apply_params(a, "file:///w/prog.thing", 2, 0, 5, 0, 11, "X")
	args := new(Two_Writer_Face_Apply, context.allocator)
	args^ = {p = p, params = params}
	done, derr := chan.create_buffered(chan.Chan(bool), 1, context.allocator)
	testing.expectf(t, derr == nil, "done chan create failed: %v", derr)
	if derr != nil {
		return
	}
	args.done = done
	thr := thread.create_and_start_with_poly_data(args, two_writer_face_apply_entry, self_cleanup = false)

	req := two_writer_face_read_request(t, p)
	if req != nil {
		if change := two_writer_face_changes(t, req); change != nil {
			edits_v, has_edits := jsonutil.obj_get(change, "edits")
			edits, is_arr := jsonutil.as_array(edits_v)
			if has_edits && is_arr && len(edits) == 1 {
				sl, sc, el, ec := two_writer_face_range(t, edits[0])
				testing.expectf(t, sl == 0 && sc == 5 && el == 0 && ec == 12, "utf-16 columns must convert to bytes, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
			}
		}
		two_writer_face_answer(t, p, req, true)
	}

	sent, _ := chan.recv(chan.as_recv(args.done))
	testing.expect(t, sent && args.applied, "the editor's applied=true must surface")
	thread.join(thr)
	free(thr, context.allocator)
	chan.destroy(args.done)
	free(args, context.allocator)
}

// ---------------------------------------------------------------------------
// Daemon-level: the full round trip over the channel transport
// ---------------------------------------------------------------------------

// Apply_Sink_Mode is the fake editor's script. Apply answers applied=true
// (splicing the edit into its view for the echo), Never_Answer never
// replies (the deadline path), Reject_Then_Apply refuses the first attempt
// with applied=false — the version-moved rejection the round trip retries
// past — and applies later ones.
Apply_Sink_Mode :: enum {
	Apply,
	Never_Answer,
	Reject_Then_Apply,
}

Apply_Request :: struct {
	uri:     string, // cloned onto the sink allocator
	version: i32,
	sl, sc, el, ec: int,
	new_text: string, // cloned
}

// Apply_Sink is one fake lsp child's svc.edit/apply endpoint: it records
// the forwarded requests and plays its script. The handler runs on the
// child conn's reader thread, whose allocator is not the test thread's —
// every clone goes through the sink's own allocator. `view_text`/`version`
// model the editor document the echo reports (spliced on apply).
Apply_Sink :: struct {
	allocator: mem.Allocator,
	mu:        sync.Mutex,
	requests:  [dynamic]Apply_Request,
	mode:      Apply_Sink_Mode,
	answers:   int,
	conn:      ^jsonrpc.Conn,
	rel:       string, // cloned; the echo target
	uri:       string, // cloned
	view_text: string, // owned clone; the editor document
	version:   i32,
}

apply_sink_init :: proc(s: ^Apply_Sink, rel, uri, view_text: string, version: i32) {
	s^ = {allocator = context.allocator, mode = .Apply}
	s.requests = make([dynamic]Apply_Request, 0, 4, s.allocator)
	s.rel = strings.clone(rel, s.allocator)
	s.uri = strings.clone(uri, s.allocator)
	s.view_text = strings.clone(view_text, s.allocator)
	s.version = version
}

apply_sink_destroy :: proc(s: ^Apply_Sink) {
	if s.requests != nil {
		for r in s.requests {
			delete(r.uri, s.allocator)
			delete(r.new_text, s.allocator)
		}
		delete(s.requests)
	}
	if s.rel != "" {
		delete(s.rel, s.allocator)
	}
	if s.uri != "" {
		delete(s.uri, s.allocator)
	}
	if s.view_text != "" {
		delete(s.view_text, s.allocator)
	}
}

// apply_sink_handler is the fake editor's svc.edit/apply endpoint.
apply_sink_handler :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	_ = arena
	sink := cast(^Apply_Sink)conn.host
	if sink == nil {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Internal_Error, err_message = "no sink"}
		return reply, .Respond
	}
	req, parsed := apply_sink_parse(sink, env.params)
	if !parsed {
		reply: jsonrpc.Reply = {is_error = true, err_code = .Invalid_Params, err_message = "malformed document_changes"}
		return reply, .Respond
	}

	sync.mutex_lock(&sink.mu)
	mode := sink.mode
	answers := sink.answers
	sink.answers += 1
	refuse := mode == .Reject_Then_Apply && answers == 0
	if !refuse && mode != .Never_Answer {
		// The editor applied: splice the recorded edit into the view and
		// move the version (Si -> Si+1) — what the echo reports. The old
		// view bytes die here (the sink allocator owns both sides).
		spliced := apply_sink_splice(sink.view_text, req, sink.allocator)
		delete(sink.view_text, sink.allocator)
		sink.view_text = spliced
		sink.version += 1
	}
	sync.mutex_unlock(&sink.mu)

	if mode == .Never_Answer {
		// Never replies: the daemon's bounded conn_call times out — the
		// deadline path.
		reply: jsonrpc.Reply
		return reply, .Defer
	}
	result := jsonutil.json_object(2, context.temp_allocator)
	jsonutil.obj_set(&result, "applied", jsonutil.json_bool(!refuse))
	if refuse {
		jsonutil.obj_set(&result, "reason", jsonutil.json_string("content modified"))
	}
	reply: jsonrpc.Reply = {result = json.Value(json.Object(result))}
	return reply, .Respond
}

// apply_sink_parse records one request (first change, first edit) and
// returns a copy for the handler's splice decision.
apply_sink_parse :: proc(sink: ^Apply_Sink, params: json.Value) -> (req: Apply_Request, ok: bool) {
	changes_v, found := jsonutil.obj_get(params, "document_changes")
	if !found {
		return
	}
	changes, is_arr := jsonutil.as_array(changes_v)
	if !is_arr || len(changes) == 0 {
		return
	}
	change := changes[0]
	uri_v, uok := jsonutil.obj_get(change, "uri")
	version_v, vok := jsonutil.obj_get(change, "version")
	edits_v, eok := jsonutil.obj_get(change, "edits")
	if !uok || !vok || !eok {
		return
	}
	edits, earr := jsonutil.as_array(edits_v)
	if !earr || len(edits) == 0 {
		return
	}
	rng_v, rok := jsonutil.obj_get(edits[0], "range")
	text_v, tok := jsonutil.obj_get(edits[0], "new_text")
	if !rok || !tok {
		return
	}
	start_v, _ := jsonutil.obj_get(rng_v, "start")
	end_v, _ := jsonutil.obj_get(rng_v, "end")

	req.uri = jsonutil.value_str(uri_v)
	req.version = i32(jsonutil.value_int(version_v))
	req.sl = int(jsonutil.obj_get_int(start_v, "line"))
	req.sc = int(jsonutil.obj_get_int(start_v, "character"))
	req.el = int(jsonutil.obj_get_int(end_v, "line"))
	req.ec = int(jsonutil.obj_get_int(end_v, "character"))
	req.new_text = jsonutil.value_str(text_v)

	stored := req
	stored.uri = strings.clone(req.uri, sink.allocator)
	stored.new_text = strings.clone(req.new_text, sink.allocator)
	sync.mutex_lock(&sink.mu)
	append(&sink.requests, stored)
	sync.mutex_unlock(&sink.mu)
	return req, true
}

// apply_sink_splice applies one recorded range edit to `text` (UTF-16
// columns through the line index — the math the editor would run).
// Returns a clone owned by `a`.
apply_sink_splice :: proc(text: string, r: Apply_Request, a: mem.Allocator) -> string {
	starts := util.line_start_offsets(text, context.temp_allocator)
	if len(starts) == 0 {
		return strings.clone(text, a)
	}
	offset_at :: proc(starts: []int, text: string, line, col: int) -> int {
		ln := line
		if ln < 0 {
			ln = 0
		}
		if ln >= len(starts) {
			ln = len(starts) - 1
		}
		start := starts[ln]
		line_end := len(text)
		if ln+1 < len(starts) {
			line_end = starts[ln+1]
		}
		return start + util.utf16_col_to_byte_offset(text[start:line_end], col)
	}
	so := offset_at(starts, text, r.sl, r.sc)
	eo := offset_at(starts, text, r.el, r.ec)
	if so > len(text) {
		so = len(text)
	}
	if eo < so || eo > len(text) {
		eo = so
	}
	return strings.concatenate({text[:so], r.new_text, text[eo:]}, a)
}

// apply_sink_wait_requests polls until the sink holds n recorded requests
// (2 ms slices, hard deadline — the bounded-arrival idiom).
apply_sink_wait_requests :: proc(s: ^Apply_Sink, n: int, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for {
		sync.mutex_lock(&s.mu)
		got := len(s.requests)
		sync.mutex_unlock(&s.mu)
		if got >= n {
			return true
		}
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

// apply_sink_wait_version polls until the sink's editor version reaches v.
apply_sink_wait_version :: proc(s: ^Apply_Sink, v: i32, timeout_ms: i64) -> bool {
	deadline := platform.mono_ms() + timeout_ms
	for {
		sync.mutex_lock(&s.mu)
		got := s.version
		sync.mutex_unlock(&s.mu)
		if got >= v {
			return true
		}
		if platform.mono_ms() >= deadline {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

// apply_sink_state snapshots the sink's editor view under its lock.
apply_sink_state :: proc(s: ^Apply_Sink, a: mem.Allocator) -> (text: string, version: i32) {
	sync.mutex_lock(&s.mu)
	text = strings.clone(s.view_text, a)
	version = s.version
	sync.mutex_unlock(&s.mu)
	return
}

// apply_sink_set_view installs the fake editor's next document state (the
// driver's keystroke): the view and version the next echo reports.
apply_sink_set_view :: proc(s: ^Apply_Sink, text: string, version: i32) {
	sync.mutex_lock(&s.mu)
	if s.view_text != "" {
		delete(s.view_text, s.allocator)
	}
	s.view_text = strings.clone(text, s.allocator)
	s.version = version
	sync.mutex_unlock(&s.mu)
}

// apply_sink_echo submits the editor's didChange for its current view —
// the echo the daemon's confirmation reads. It is a blocking svc request,
// so the scenario drivers call it from their own helper threads, never
// from the child reader thread. `timeout_ms` is a duration; the svc call
// takes the absolute monotonic deadline it becomes.
apply_sink_echo :: proc(s: ^Apply_Sink, arena: mem.Allocator, timeout_ms: i64) {
	text, version := apply_sink_state(s, arena)
	cc := svc.client_doc_change(s.conn, s.rel, version, text, arena, platform.mono_ms() + timeout_ms)
	_ = cc
}

// apply_sink_quiet waits out a fixed window and reports whether the sink
// recorded nothing (a non-owner's silence is a bounded observation).
apply_sink_quiet :: proc(s: ^Apply_Sink, window_ms: i64) -> bool {
	deadline := platform.mono_ms() + window_ms
	for {
		sync.mutex_lock(&s.mu)
		got := len(s.requests)
		sync.mutex_unlock(&s.mu)
		if got != 0 {
			return false
		}
		if platform.mono_ms() >= deadline {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
}

// Two_Writer_Ends collects the daemon-side channel endpoints across a
// scenario's children.
Two_Writer_Ends :: struct {
	ends: [dynamic]^rpc.Chan_Endpoint,
}

// Two_Writer_Child is one connected fake lsp child (channel endpoint +
// reader thread + scripted sink). `daemon_endpoint` is the pair's other
// half: the daemon holds its stream for the child's lifetime, so it is
// destroyed only after the daemon is down (the scenarios' final cleanup).
Two_Writer_Child :: struct {
	sink:           Apply_Sink,
	endpoint:       ^rpc.Chan_Endpoint,
	daemon_endpoint: ^rpc.Chan_Endpoint,
	conn:           ^jsonrpc.Conn,
	box:            ^Conn_Box,
	reader:         ^thread.Thread,
}

// two_writer_child_connect dials the in-process daemon as a new lsp-mode
// child, registers the scripted apply endpoint, and completes the hello.
two_writer_child_connect :: proc(
	t: ^testing.T,
	d: ^daemon.Daemon,
	rel, uri, view_text: string,
	version: i32,
	mode: Apply_Sink_Mode,
	daemon_ends: ^Two_Writer_Ends,
) -> ^Two_Writer_Child {
	e_child, e_daemon := rpc.channel_pair(context.allocator)
	if e_child == nil {
		testing.expect(t, false, "channel_pair failed")
		return nil
	}
	c := new(Two_Writer_Child, context.allocator)
	c.endpoint = e_child
	c.daemon_endpoint = e_daemon
	apply_sink_init(&c.sink, rel, uri, view_text, version)
	c.sink.mode = mode
	if daemon.daemon_in_process_accept(d, e_daemon) == nil {
		rpc.channel_endpoint_destroy(e_daemon)
		rpc.channel_endpoint_destroy(e_child)
		apply_sink_destroy(&c.sink)
		free(c, context.allocator)
		testing.expect(t, false, "in-process accept failed")
		return nil
	}
	append(&daemon_ends.ends, e_daemon)

	conn := new(jsonrpc.Conn, context.allocator)
	r := rpc.to_reader(&e_child.stream, rpc.RPC_MAX_FRAME)
	w := rpc.to_writer(&e_child.stream)
	jsonrpc.conn_init(conn, r, w, context.allocator)
	c.conn = conn
	c.sink.conn = conn
	c.box = new(Conn_Box, context.allocator)
	c.box^ = {conn = conn}
	c.reader = thread.create_and_start_with_poly_data(c.box, conn_reader_entry, self_cleanup = false)
	jsonrpc.conn_register(conn, svc.METHOD_EDIT_APPLY, apply_sink_handler)
	conn.host = &c.sink

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	hello := jsonutil.json_object(2, mem.dynamic_arena_allocator(&arena))
	jsonutil.obj_set(&hello, "client_pid", jsonutil.json_int(i64(os.get_pid())))
	jsonutil.obj_set(&hello, "mode", jsonutil.json_string("lsp"))
	_, _, _, hcerr := jsonrpc.conn_call(
		conn, svc.METHOD_HELLO, json.Value(json.Object(hello)),
		mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 10_000,
	)
	mem.dynamic_arena_destroy(&arena)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)
	if hcerr != .None {
		// The closer frees the child's half; the daemon-side endpoint stays
		// with the daemon_ends collector — the daemon already accepted it.
		two_writer_child_close(c)
		return nil
	}
	return c
}

two_writer_child_close :: proc(c: ^Two_Writer_Child) {
	if c == nil {
		return
	}
	jsonrpc.conn_close(c.conn)
	c.endpoint.stream.close(&c.endpoint.stream)
	if c.reader != nil {
		thread.join(c.reader)
		free(c.reader, context.allocator)
	}
	free(c.box, context.allocator)
	jsonrpc.conn_destroy(c.conn)
	free(c.conn, context.allocator)
	rpc.channel_endpoint_destroy(c.endpoint)
	apply_sink_destroy(&c.sink)
	free(c, context.allocator)
}

// two_writer_daemon_ends_destroy frees the daemon-side channel endpoints
// collected by the scenarios: the daemon held their streams until
// pair_shutdown joined it. The pointer sees the scenario's later appends.
two_writer_daemon_ends_destroy :: proc(collector: ^Two_Writer_Ends) {
	for e in collector.ends {
		rpc.channel_endpoint_destroy(e)
	}
	delete(collector.ends)
}

// two_writer_child_open opens the child's document over its own conn with
// the capability bits on (or off, for the gate scenario).
two_writer_child_open :: proc(t: ^testing.T, c: ^Two_Writer_Child, rel: string, version: i32, text: string, caps: bool) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	cc := svc.client_doc_open(
		c.conn, rel, "go", version, text,
		mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 10_000,
		nil, caps, caps,
	)
	mem.dynamic_arena_destroy(&arena)
	testing.expect_value(t, cc.call_err, jsonrpc.Call_Err.None)
}

// The routed file write, with its echo driver: the helper thread waits for
// the forwarded request, then submits the sink's didChange (the editor's
// echo). Returns the file_write outcome; `echo` selects whether the editor
// echoes at all (the never-answers scenario leaves it off).
Two_Writer_Write_Run :: struct {
	pair:    ^Daemon_Pair,
	rel:     string,
	content: string,
	echo:    bool,
	sink:    ^Apply_Sink,
	overwrote: bool,
	err:     platform.Err,
}

two_writer_write_entry :: proc(run: ^Two_Writer_Write_Run) {
	if run.echo {
		job := new(Two_Writer_Echo_Job, context.allocator)
		job^ = {run = run}
		thr := thread.create_and_start_with_poly_data(job, two_writer_echo_entry, self_cleanup = false)
		defer {
			thread.join(thr)
			free(thr, context.allocator)
			free(job, context.allocator)
		}
		run.overwrote, run.err = svc.file_write(run.pair.daemon.ed, run.rel, run.content, context.temp_allocator, run.pair.daemon.edit_tw)
		return
	}
	run.overwrote, run.err = svc.file_write(run.pair.daemon.ed, run.rel, run.content, context.temp_allocator, run.pair.daemon.edit_tw)
}

Two_Writer_Echo_Job :: struct {
	run: ^Two_Writer_Write_Run,
}

// two_writer_echo_entry plays the editor's echo: wait for the first
// forwarded request, then report the sink's current view. The sink handler
// splices and bumps the version BEFORE answering, so the echo carries the
// post-apply state.
two_writer_echo_entry :: proc(job: ^Two_Writer_Echo_Job) {
	if !apply_sink_wait_requests(job.run.sink, 1, 10_000) {
		return
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	apply_sink_echo(job.run.sink, mem.dynamic_arena_allocator(&arena), 10_000)
	mem.dynamic_arena_destroy(&arena)
	free_all(context.temp_allocator)
}

// Scenario 1 (owner-only delivery): two lsp children are connected; the
// document is owned by A. The routed edit reaches exactly A — B, live and
// subscribed, receives nothing — and the confirmed echo leaves the daemon
// buffer carrying the written content.
@(test)
two_writer_owner_only_delivery :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "own.go"
	v1 := "package main\n\nfunc base() {}\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)
	bystander_rel := "other.go"
	bystander_v1 := "package main\n\nfunc bystander() {}\n"
	svc_symbol_write_file(t, pair.tmp, bystander_rel, bystander_v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/own.go", v1, 1, .Apply, &ends)
	if a == nil {
		return
	}
	defer two_writer_child_close(a)
	b := two_writer_child_connect(t, pair.daemon, bystander_rel, "file:///proj/other.go", bystander_v1, 1, .Apply, &ends)
	if b == nil {
		return
	}
	defer two_writer_child_close(b)

	two_writer_child_open(t, a, rel, 1, v1, true)
	two_writer_child_open(t, b, bystander_rel, 1, bystander_v1, true)

	// The daemon saw both opens: A owns own.go, B owns other.go.
	owner, has := svc.doc_sync_owner_of(pair.daemon.doc_sync, rel)
	testing.expectf(t, has && owner != 0, "own.go must be owned after the open")
	if !has {
		return
	}
	content := "package main\n\nfunc base() {}\n\nfunc added() {}\n"
	run := Two_Writer_Write_Run{pair = pair, rel = rel, content = content, echo = true, sink = &a.sink}
	thr := thread.create_and_start_with_poly_data(&run, two_writer_write_entry, self_cleanup = false)
	thread.join(thr)
	free(thr, context.allocator)
	testing.expectf(t, run.err == nil, "the routed write must succeed: %v", run.err)
	if run.err != nil {
		return
	}

	// The owner received exactly the one forwarded edit, pinned at the
	// observed version, in the daemon-canonical uri.
	testing.expectf(t, apply_sink_wait_requests(&a.sink, 1, 2000), "the owner must receive the forwarded edit")
	sync.mutex_lock(&a.sink.mu)
	n_a := len(a.sink.requests)
	req := a.sink.requests[0]
	uri := req.uri
	version := req.version
	sync.mutex_unlock(&a.sink.mu)
	testing.expectf(t, n_a == 1, "the owner must receive exactly one request, got %d", n_a)
	testing.expectf(t, version == 1, "the forwarded edit must pin the observed version, got %d", version)
	testing.expectf(t, strings.contains(uri, "own.go"), "the forwarded uri must name the document: %s", uri)

	// The bystander stays silent.
	testing.expectf(t, apply_sink_quiet(&b.sink, 300), "the non-owner must receive nothing")

	// The echo applied through the ordinary document-sync path: the buffer
	// carries the written content and the version home advanced past the
	// pinned V.
	buf := doc_sync_buffer_of(pair.daemon.ed, rel)
	testing.expect(t, buf != nil, "the buffer must exist after the echo")
	if buf != nil {
		testing.expect_value(t, buf.contents, content)
	}
	v, has_v := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, rel)
	testing.expectf(t, has_v && v > 1, "the echo must advance the applied version past V, got %d", v)
}

// Scenario (multi routing): a compute spanning an owned and an unowned
// document routes ONLY the owned file through the owner's applyEdit — the
// unowned file never crosses the wire (its landing is the caller's own
// direct apply) — and the round trip confirms on the owned file's echo.
// The landed set must name exactly the applied file, and must keep naming
// it when its ownership vanishes afterwards.
Multi_Filter_State :: struct {
	pair:        ^Daemon_Pair,
	owned_rel:   string,
	unowned_rel: string,
	sink:        ^Apply_Sink,
}

multi_filter_compute :: proc(user: rawptr, a: mem.Allocator) -> ([]svc.Edit_Doc_Changes, string, platform.Err) {
	st := cast(^Multi_Filter_State)user
	rels := []string{st.owned_rel, st.unowned_rel}
	changes := make([dynamic]svc.Edit_Doc_Changes, 0, 2, a)
	for rel in rels {
		edits := make([]svc.Edit_Item, 1, a)
		edits[0] = svc.Edit_Item{
			rng      = svc.Edit_Range{sl = 0, sc = 0, el = 0, ec = 0},
			new_text = "// touch\n",
		}
		append(&changes, svc.Edit_Doc_Changes{rel_path = rel, edits = edits})
	}
	return changes[:], "", nil
}

// The echo driver: wait for the forwarded request, then submit the sink's
// didChange (the editor's echo the confirmation reads).
multi_filter_echo_entry :: proc(st: ^Multi_Filter_State) {
	if !apply_sink_wait_requests(st.sink, 1, 8000) {
		return
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	apply_sink_echo(st.sink, mem.dynamic_arena_allocator(&arena), 10_000)
	mem.dynamic_arena_destroy(&arena)
}

@(test)
two_writer_multi_routes_only_owned_documents :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "own.go"
	v1 := "package main\n\nfunc base() {}\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)
	unowned := "closed.go"
	unowned_v1 := "package main\n\nfunc closed() {}\n"
	svc_symbol_write_file(t, pair.tmp, unowned, unowned_v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/own.go", v1, 1, .Apply, &ends)
	if a == nil {
		return
	}
	defer two_writer_child_close(a)
	two_writer_child_open(t, a, rel, 1, v1, true)

	st := Multi_Filter_State{
		pair        = pair,
		owned_rel   = rel,
		unowned_rel = unowned,
		sink        = &a.sink,
	}
	// The round trip runs on this thread; the echo driver plays the editor
	// side on a helper. The arena owns the compute's changes and the landed
	// set, so the assertions below read live allocations.
	thr := thread.create_and_start_with_poly_data(&st, multi_filter_echo_entry, self_cleanup = false)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	routed, landed, route_err := svc.two_writer_route_multi(
		pair.daemon.edit_tw, "multi filter", multi_filter_compute, &st, nil, mem.dynamic_arena_allocator(&arena),
	)
	thread.join(thr)
	free(thr, context.allocator)
	testing.expectf(t, route_err == nil, "the routed multi round trip must succeed: %v", route_err)
	if route_err != nil {
		return
	}
	testing.expect(t, routed, "a compute touching an owned document must route")

	// Exactly one request crossed, naming the owned document, pinned at its
	// observed version.
	testing.expectf(t, apply_sink_wait_requests(&a.sink, 1, 2000), "the owner must receive the forwarded edit")
	sync.mutex_lock(&a.sink.mu)
	n := len(a.sink.requests)
	req := a.sink.requests[0]
	sync.mutex_unlock(&a.sink.mu)
	testing.expectf(t, n == 1, "only the owned document may cross the wire, got %d requests", n)
	testing.expectf(t, strings.contains(req.uri, "own.go"), "the forwarded uri must name the owned document: %s", req.uri)
	testing.expectf(t, req.version == 1, "the forwarded edit must pin the observed version, got %d", req.version)

	// The unowned file is untouched — its landing is the caller's direct
	// apply, not this round trip.
	unowned_path, _ := filepath.join([]string{pair.tmp, unowned}, context.temp_allocator)
	disk_bytes, rerr := os.read_entire_file_from_path(unowned_path, context.temp_allocator)
	testing.expectf(t, rerr == nil, "reading the unowned file back failed: %v", rerr)
	if rerr == nil {
		testing.expect_value(t, string(disk_bytes), unowned_v1)
	}

	// And the echo advanced the owned document's applied version past V.
	v, has_v := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, rel)
	testing.expectf(t, has_v && v > 1, "the echo must advance the applied version past V, got %d", v)

	// The landed set names exactly what the round trip applied: the owned
	// document, never the unowned remainder.
	testing.expectf(t, len(landed) == 1 && landed[0] == rel, "the landed set must name only the owned document, got %v", landed)

	// The decision input survives the ownership vanishing afterwards: close
	// the document the way its owner would and observe the split — landed
	// still names the file, live ownership does not. A caller consulting
	// live ownership instead of the landed set would re-apply the file
	// directly with pre-round-trip ranges.
	owner_id, owned_now := svc.doc_sync_owner_of(pair.daemon.doc_sync, rel)
	testing.expect(t, owned_now, "the document is still owned before the owner close")
	if owned_now {
		cerr := svc.doc_sync_close(pair.daemon.doc_sync, rel, context.temp_allocator, owner_id)
		testing.expectf(t, cerr == nil, "the owner close failed: %v", cerr)
		if cerr == nil {
			_, owned_now = svc.doc_sync_owner_of(pair.daemon.doc_sync, rel)
			testing.expect(t, !owned_now, "the owner close cleared live ownership")
			testing.expectf(t, len(landed) == 1 && landed[0] == rel, "the landed set still names the landed file after its ownership vanished")
		}
	}
}

// Scenario 2 (timeout failure): an owner that never answers makes the tool
// edit fail explicitly within the bounded deadline — and the buffer stays
// untouched. No silent fallback, no hang.
@(test)
two_writer_timeout_fails_explicitly :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "stuck.go"
	v1 := "package main\n\nfunc stuck() {}\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/stuck.go", v1, 1, .Never_Answer, &ends)
	if a == nil {
		return
	}
	defer two_writer_child_close(a)
	two_writer_child_open(t, a, rel, 1, v1, true)

	pair.daemon.edit_tw.deadline_ms = 500
	started := platform.mono_ms()
	run := Two_Writer_Write_Run{pair = pair, rel = rel, content = "package main\n\nfunc rewritten() {}\n", echo = false}
	thr := thread.create_and_start_with_poly_data(&run, two_writer_write_entry, self_cleanup = false)
	thread.join(thr)
	free(thr, context.allocator)
	elapsed := platform.mono_ms() - started

	testing.expectf(t, run.err != nil, "a never-answering owner must fail the edit")
	if run.err == nil {
		return
	}
	testing.expectf(t, elapsed < 4000, "the failure must land within the bounded deadline, took %dms", elapsed)
	testing.expectf(t, platform.err_kind(run.err) == .Retryable, "the deadline failure is retryable, got %v", platform.err_kind(run.err))
	// The buffer is untouched: the routed write never fell back to a
	// direct write.
	buf := doc_sync_buffer_of(pair.daemon.ed, rel)
	if buf != nil {
		testing.expect_value(t, buf.contents, v1)
	}
	testing.expectf(t, apply_sink_wait_requests(&a.sink, 1, 2000), "the request must have reached the owner")
}

// Scenario 3 (keystroke-interrupt retry): the first applyEdit is refused
// (applied=false — the editor's version moved), a keystroke lands and
// advances the version, the daemon recomputes against the fresh text and
// retries, and the second application's positions match the POST-keystroke
// document — the anti-corruption assertion.
@(test)
two_writer_keystroke_retry_applies_current_text :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "race.go"
	v1 := "alpha\nbeta\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/race.go", v1, 1, .Reject_Then_Apply, &ends)
	if a == nil {
		return
	}
	defer two_writer_child_close(a)
	two_writer_child_open(t, a, rel, 1, v1, true)

	// The driver thread plays the editor side: after the refused first
	// attempt, a keystroke lands (v2: one more line), and the second
	// attempt's echo reports the applied view.
	driver := new(Two_Writer_Retry_Driver, context.allocator)
	driver^ = {sink = &a.sink, conn = a.conn, rel = strings.clone(rel, context.allocator)}
	thr := thread.create_and_start_with_poly_data(driver, two_writer_retry_driver_entry, self_cleanup = false)
	defer {
		thread.join(thr)
		free(thr, context.allocator)
		delete(driver.rel, context.allocator)
		free(driver, context.allocator)
	}

	content := "alpha\nbeta\ngamma\n"
	// The write runs on this thread; the driver handles the editor side.
	overwrote, werr := svc.file_write(pair.daemon.ed, rel, content, context.temp_allocator, pair.daemon.edit_tw)
	testing.expectf(t, werr == nil, "the retried write must succeed: %v", werr)
	if werr != nil {
		return
	}
	testing.expect(t, overwrote, "the write overwrites the existing document")

	// Two attempts: the first pinned v1 (rejected), the second pinned v2
	// (the post-keystroke document).
	testing.expectf(t, apply_sink_wait_requests(&a.sink, 2, 5000), "both attempts must reach the owner")
	sync.mutex_lock(&a.sink.mu)
	r1 := a.sink.requests[0]
	r2 := a.sink.requests[1]
	sync.mutex_unlock(&a.sink.mu)
	testing.expectf(t, r1.version == 1, "the first attempt must pin v1, got %d", r1.version)
	testing.expectf(t, r2.version == 2, "the retried attempt must pin the fresh v2, got %d", r2.version)
	// The anti-corruption assertion: the first attempt's range belongs to
	// v1 (an insert at that document's end), while the retried range
	// belongs to the POST-keystroke document — it spans exactly the
	// "KEYSTROKE" word the keystroke left on line 2, and applying it lands
	// the written content on the current text.
	testing.expectf(t, r1.sl == 2 && r1.sc == 0 && r1.el == 2 && r1.ec == 0, "the first attempt must target the v1 document end, got (%d,%d)-(%d,%d)", r1.sl, r1.sc, r1.el, r1.ec)
	testing.expectf(t, r2.sl == 2 && r2.sc == 0 && r2.el == 2 && r2.ec == 9, "the retried range must span the keystroke's word on the current text, got (%d,%d)-(%d,%d)", r2.sl, r2.sc, r2.el, r2.ec)
	text, _ := apply_sink_state(&a.sink, context.temp_allocator)
	testing.expect_value(t, text, content)

	// The echo's application through the document-sync face left the
	// daemon buffer at the written content, version home past v2.
	buf := doc_sync_buffer_of(pair.daemon.ed, rel)
	testing.expect(t, buf != nil, "the buffer must exist after the echo")
	if buf != nil {
		testing.expect_value(t, buf.contents, content)
	}
	v, has := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, rel)
	testing.expectf(t, has && v >= 3, "the version home must carry the echo's version, got %d", v)
}

Two_Writer_Retry_Driver :: struct {
	sink: ^Apply_Sink,
	conn: ^jsonrpc.Conn,
	rel:  string,
}

// two_writer_retry_driver_entry plays the editor side of the retry:
// keystroke after the refusal (v2, one more line), then the echo of the
// second attempt's applied view.
two_writer_retry_driver_entry :: proc(d: ^Two_Writer_Retry_Driver) {
	if !apply_sink_wait_requests(d.sink, 1, 10_000) {
		return
	}
	// The keystroke: the editor moves to v2 (one more line) and reports it
	// through the ordinary document-sync path — the daemon's catch-up wait
	// reads exactly this.
	apply_sink_set_view(d.sink, "alpha\nbeta\nKEYSTROKE\n", 2)
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	cc := svc.client_doc_change(d.conn, d.rel, 2, "alpha\nbeta\nKEYSTROKE\n", mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 10_000)
	if cc.call_err != .None {
		mem.dynamic_arena_destroy(&arena)
		return
	}
	// The second attempt applies in the sink (version 3 there); echo it so
	// the confirmation reads the version advance past the retried pin.
	if !apply_sink_wait_requests(d.sink, 2, 10_000) {
		mem.dynamic_arena_destroy(&arena)
		return
	}
	if !apply_sink_wait_version(d.sink, 3, 10_000) {
		mem.dynamic_arena_destroy(&arena)
		return
	}
	apply_sink_echo(d.sink, mem.dynamic_arena_allocator(&arena), 10_000)
	mem.dynamic_arena_destroy(&arena)
	free_all(context.temp_allocator)
}

// Scenario 4 (post-apply keystroke): the round trip succeeds and a
// keystroke lands before the daemon's confirmation read — the version has
// advanced past V and the confirmation does NOT false-fail.
@(test)
two_writer_post_apply_keystroke_confirms :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "confirm.go"
	v1 := "package main\n\nfunc confirm() {}\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/confirm.go", v1, 1, .Apply, &ends)
	if a == nil {
		return
	}
	defer two_writer_child_close(a)
	two_writer_child_open(t, a, rel, 1, v1, true)

	// The driver waits for the forwarded request (the sink answers
	// applied=true immediately) and slips a keystroke in before the
	// confirmation can read: v2 moves the version past V either way.
	driver := new(Two_Writer_Keystroke_Driver, context.allocator)
	driver^ = {sink = &a.sink, conn = a.conn, rel = strings.clone(rel, context.allocator)}
	thr := thread.create_and_start_with_poly_data(driver, two_writer_keystroke_driver_entry, self_cleanup = false)
	defer {
		thread.join(thr)
		free(thr, context.allocator)
		delete(driver.rel, context.allocator)
		free(driver, context.allocator)
	}

	content := "package main\n\nfunc rewritten() {}\n"
	_, werr := svc.file_write(pair.daemon.ed, rel, content, context.temp_allocator, pair.daemon.edit_tw)
	testing.expectf(t, werr == nil, "the write must succeed despite the racing keystroke: %v", werr)
	if werr != nil {
		return
	}
	v, has := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, rel)
	testing.expectf(t, has && v > 1, "the version must have advanced past the pinned V, got %d", v)
}

Two_Writer_Keystroke_Driver :: struct {
	sink: ^Apply_Sink,
	conn: ^jsonrpc.Conn,
	rel:  string,
}

two_writer_keystroke_driver_entry :: proc(d: ^Two_Writer_Keystroke_Driver) {
	if !apply_sink_wait_requests(d.sink, 1, 10_000) {
		return
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	// v2 is the applied echo's version when it already landed (sink
	// bumped), else the keystroke itself moves past V — both satisfy the
	// confirmation. Send the keystroke at the sink's CURRENT version + 1
	// so it always advances the daemon's version home.
	_, version := apply_sink_state(d.sink, mem.dynamic_arena_allocator(&arena))
	cc := svc.client_doc_change(d.conn, d.rel, version + 1, "package main\n\nfunc keystroke() {}\n", mem.dynamic_arena_allocator(&arena), platform.mono_ms() + 10_000)
	_ = cc
	mem.dynamic_arena_destroy(&arena)
	free_all(context.temp_allocator)
}

// Scenario 5 (owner disconnect): the owner child goes away; its documents
// return to the non-open state — the next edit to the document takes the
// direct path (disk write, no forwarded request).
@(test)
two_writer_owner_disconnect_resumes_direct :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "gone.go"
	v1 := "package main\n\nfunc gone() {}\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/gone.go", v1, 1, .Apply, &ends)
	if a == nil {
		return
	}
	two_writer_child_open(t, a, rel, 1, v1, true)
	owner, has := svc.doc_sync_owner_of(pair.daemon.doc_sync, rel)
	testing.expectf(t, has && owner != 0, "the document must be owned before the disconnect")
	if !has {
		two_writer_child_close(a)
		return
	}

	// The child goes away: its documents return to the non-open state.
	two_writer_child_close(a)
	deadline := platform.mono_ms() + 10_000
	for {
		_, still := svc.doc_sync_owner_of(pair.daemon.doc_sync, rel)
		if !still {
			break
		}
		if platform.mono_ms() >= deadline {
			testing.expect(t, false, "the owned document must return to the non-open state")
			return
		}
		time.sleep(2 * time.Millisecond)
	}
	_, has_v := svc.doc_sync_last_applied_version(pair.daemon.doc_sync, rel)
	testing.expect(t, !has_v, "the version record clears with the non-open state")

	// The next edit takes the direct path: the disk carries it, and no
	// request can reach the closed child.
	content := "package main\n\nfunc direct() {}\n"
	overwrote, werr := svc.file_write(pair.daemon.ed, rel, content, context.temp_allocator, pair.daemon.edit_tw)
	testing.expectf(t, werr == nil, "the direct write must succeed: %v", werr)
	if werr != nil {
		return
	}
	testing.expect(t, overwrote, "the direct write overwrites the file")
	disk := two_writer_read_disk(t, pair.tmp, rel)
	defer delete(disk, context.allocator)
	testing.expect(t, strings.contains(disk, "func direct"), "the direct path must write the disk")
	sync.mutex_lock(&a.sink.mu)
	n := len(a.sink.requests)
	sync.mutex_unlock(&a.sink.mu)
	testing.expectf(t, n == 0, "the closed owner must receive nothing, got %d", n)
}

// two_writer_read_disk reads a file's raw disk bytes (caller-owned
// string on context.allocator). Directory-based, so the freshness lazy
// tests read their fixture files through it too. The path is frame scratch.
two_writer_read_disk :: proc(t: ^testing.T, dir, rel: string) -> string {
	path, _ := filepath.join([]string{dir, rel}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		testing.expectf(t, false, "disk read failed for %s", rel)
		return ""
	}
	defer delete(data)
	return strings.clone(string(data), context.allocator)
}

// The routing gate's negative half (daemon side): an lsp child that
// opened its document WITHOUT the applyEdit capability bits turns edits to
// that document into an explicit failure at the gate — no request is sent,
// and the buffer is untouched.
@(test)
two_writer_capability_gate_daemon_side :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	ends := Two_Writer_Ends{}
	ends.ends = make([dynamic]^rpc.Chan_Endpoint, 0, 4, context.allocator)
	defer two_writer_daemon_ends_destroy(&ends)
	defer pair_shutdown(pair)
	testing.expect(t, wait_index_warm(pair, 10_000), "index warm timed out")

	rel := "nocap.go"
	v1 := "package main\n\nfunc nocap() {}\n"
	svc_symbol_write_file(t, pair.tmp, rel, v1)

	a := two_writer_child_connect(t, pair.daemon, rel, "file:///proj/nocap.go", v1, 1, .Apply, &ends)
	if a == nil {
		return
	}
	defer two_writer_child_close(a)
	// The open declares NO applyEdit support.
	two_writer_child_open(t, a, rel, 1, v1, false)
	owner, has := svc.doc_sync_owner_of(pair.daemon.doc_sync, rel)
	testing.expectf(t, has && owner != 0, "the document is still owned (the editor holds it open)")
	if !has {
		return
	}

	content := "package main\n\nfunc rewritten() {}\n"
	_, werr := svc.file_write(pair.daemon.ed, rel, content, context.temp_allocator, pair.daemon.edit_tw)
	testing.expectf(t, werr != nil, "an incapable editor must fail the edit explicitly")
	if werr == nil {
		return
	}
	testing.expect(t, strings.contains(platform.err_message(werr, context.temp_allocator), "applyEdit"), "the refusal names the missing capability")
	sync.mutex_lock(&a.sink.mu)
	n := len(a.sink.requests)
	sync.mutex_unlock(&a.sink.mu)
	testing.expectf(t, n == 0, "no request may reach an incapable editor, got %d", n)
	buf := doc_sync_buffer_of(pair.daemon.ed, rel)
	if buf != nil {
		testing.expect_value(t, buf.contents, v1)
	}
}

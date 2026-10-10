// lspserver publish tests: the debounced tree-sitter diagnostics publish
// over the same synchronous pipe harness as the face tests (shared host
// fakes, pipes, and frame helpers — see lspserver_face_test.odin). The
// test advances a virtual clock to move the debounce window and calls the
// face's fire pass directly — no threads; the publish notifications are
// read back off the down pipe the dispatch wrote synchronously.
package tests

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:lsp"
import "src:lspserver"
import "src:platform"

// --- publish readers --------------------------------------------------------

// lsppub_read_publish pops one frame off the down pipe and returns the
// publishDiagnostics params. Everything borrows the temp allocator's
// parse scratch — consumed within the test step.
lsppub_read_publish :: proc(t: ^testing.T, p: ^Lspface_Pair) -> json.Value {
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

lsppub_uri :: proc(t: ^testing.T, params: json.Value) -> string {
	v, ok := jsonutil.obj_get(params, "uri")
	testing.expect(t, ok, "publish params carry no uri")
	if !ok {
		return ""
	}
	return jsonutil.value_str(v)
}

// lsppub_version returns the params' version member and whether it was
// present at all (the didClose clear omits it).
lsppub_version :: proc(params: json.Value) -> (i64, bool) {
	v, ok := jsonutil.obj_get(params, "version")
	return jsonutil.value_int(v), ok
}

lsppub_diag_count :: proc(t: ^testing.T, params: json.Value) -> int {
	v, ok := jsonutil.obj_get(params, "diagnostics")
	testing.expect(t, ok, "publish params carry no diagnostics")
	if !ok {
		return 0
	}
	items, is_arr := jsonutil.as_array(v)
	testing.expect(t, is_arr, "diagnostics is not an array")
	if !is_arr {
		return 0
	}
	return len(items)
}

// lsppub_diag_pos returns diagnostic i's start/end positions and pins its
// severity (1 = Error for both walk kinds) and source tag.
lsppub_diag_pos :: proc(t: ^testing.T, params: json.Value, i: int) -> (sl, sc, el, ec: i64) {
	diags_v, ok := jsonutil.obj_get(params, "diagnostics")
	testing.expect(t, ok, "publish params carry no diagnostics")
	if !ok {
		return
	}
	items, is_arr := jsonutil.as_array(diags_v)
	testing.expect(t, is_arr, "diagnostics is not an array")
	if !is_arr {
		return
	}
	testing.expectf(t, i < len(items), "diagnostic %d missing (%d published)", i, len(items))
	if i >= len(items) {
		return
	}
	item := items[i]
	rng, rok := jsonutil.obj_get(item, "range")
	testing.expect(t, rok, "diagnostic carries no range")
	if !rok {
		return
	}
	start, _ := jsonutil.obj_get(rng, "start")
	end, _ := jsonutil.obj_get(rng, "end")
	sl = jsonutil.obj_get_int(start, "line")
	sc = jsonutil.obj_get_int(start, "character")
	el = jsonutil.obj_get_int(end, "line")
	ec = jsonutil.obj_get_int(end, "character")
	sev := jsonutil.obj_get_int(item, "severity")
	testing.expectf(t, sev == 1, "diagnostic severity must be 1 (Error), got %d", sev)
	if src_v, found := jsonutil.obj_get(item, "source"); found {
		testing.expectf(t, jsonutil.value_str(src_v) == "aubade", "diagnostic source must be aubade")
	}
	return
}

// --- tests ---------------------------------------------------------------------

@(test)
lsppub_storm_coalesces_to_one_publish :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	// The face answer carries its own version — never the last change's.
	p.host.diagnostics.version = 42
	p.host.diagnostics.has_version = true
	hits := make([]lspserver.Diag_Hit, 1, context.temp_allocator)
	hits[0] = {start_byte = 0, end_byte = 7, message = "syntax"}
	lspface_set_diagnostics(&p.host, hits)

	// Open plus three changes inside the window: every mark moves the due
	// point, so one window end covers the whole storm.
	now := platform.clock_now(&clock)
	lspserver.publish_mark(&p.server, uri, now)
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":2},"contentChanges":[{"text":"package main\n"}]`)
	lspserver.publish_mark(&p.server, uri, now + 10)
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":3},"contentChanges":[{"text":"package main\n"}]`)
	lspserver.publish_mark(&p.server, uri, now + 20)
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":4},"contentChanges":[{"text":"package main\n"}]`)
	lspserver.publish_mark(&p.server, uri, now + 30)

	// Before the window ends: nothing fires.
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	testing.expectf(t, len(p.down.buf) == 0, "a publish before the window end must not happen")

	// Past the last mark's window: exactly one publish, drained by the pass.
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params) == uri, "the publish names the changed document")
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 42, "the publish must stamp the face answer's version (42), got %d", version)
	testing.expectf(t, lsppub_diag_count(t, params) == 1, "the tree-sitter answer's diagnostics are published")
	testing.expectf(t, len(p.down.buf) == 0, "the storm must coalesce into ONE publish")

	// The drained set stays empty: a second fire pass is a no-op.
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	testing.expectf(t, len(p.down.buf) == 0, "a drained document must not publish again")
	testing.expectf(t, p.host.diagnostics_calls == 1, "the fire must fetch exactly once, got %d", p.host.diagnostics_calls)
}

@(test)
lsppub_two_windows_publish_twice :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	p.host.diagnostics.version = 5
	p.host.diagnostics.has_version = true

	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	lspserver.publish_mark(&p.server, uri, 0)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 100)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params) == uri, "the first window publishes")

	// A change past the first window opens a second one and publishes
	// again — the debouncer coalesces inside a window, not across them.
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":2},"contentChanges":[{"text":"package main // v2\n"}]`)
	lspserver.publish_mark(&p.server, uri, platform.clock_now(&clock))
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 100)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params2 := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params2) == uri, "the second window publishes")
	testing.expectf(t, len(p.down.buf) == 0, "exactly two publishes must have fired")
	testing.expectf(t, p.host.diagnostics_calls == 2, "each window fetches once, got %d", p.host.diagnostics_calls)
}

@(test)
lsppub_version_truth_is_the_face_answer :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	// Version skew: the daemon computed over an older applied version than
	// the last didChange sent. The publish stamps the FACE's version — the
	// version the computation actually used, data on the path, never
	// inferred from apply order.
	p.host.diagnostics.version = 9
	p.host.diagnostics.has_version = true
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":10},"contentChanges":[{"text":"package main\n"}]`)
	lspserver.publish_mark(&p.server, uri, 0)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 9, "the publish must carry the face's version 9, got %d", version)
}

@(test)
lsppub_readiness_swap_suppresses_and_restores :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":5,"text":"package main\n"}`)

	// Not live: the tree-sitter answer publishes. The preset carries a
	// synced version — the daemon answered the open buffer's bytes.
	hits := make([]lspserver.Diag_Hit, 1, context.temp_allocator)
	hits[0] = {start_byte = 0, end_byte = 7, message = "syntax"}
	lspface_set_diagnostics(&p.host, hits)
	p.host.diagnostics.has_version = true
	lspserver.publish_mark(&p.server, uri, 0)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params) == 1, "a not-live language publishes the tree-sitter answer")
	testing.expectf(t, p.host.diagnostics_calls == 1, "the not-live fire fetches diagnostics")
	testing.expectf(t, p.host.readiness_calls == 1, "the fire consults readiness first")

	// Live: the next fire publishes the empty set that clears the
	// tree-sitter squiggles — and never fetches diagnostics.
	p.host.readiness_live = true
	lspface_notify(t, p, lsp.METHOD_DID_CHANGE, `"textDocument":{"uri":"file:///w/prog.go","version":6},"contentChanges":[{"text":"package main\n"}]`)
	lspserver.publish_mark(&p.server, uri, platform.clock_now(&clock))
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params2 := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params2) == 0, "a live language suppresses the tree-sitter answer")
	version, has_version := lsppub_version(params2)
	// The didChange moved the view to version 6 before this fire, so the
	// suppression publish stamps the view's current version.
	testing.expectf(t, has_version && version == 6, "the suppression publish stamps the view's version, got %d", version)
	testing.expectf(t, p.host.diagnostics_calls == 1, "a live language must not fetch tree-sitter diagnostics")
}

@(test)
lsppub_utf16_spans_convert_through_the_view :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// utf-16 connection: byte spans convert through the open document's
	// per-version line index. "héllo" holds one two-byte rune, so byte and
	// utf-16 columns diverge. Bytes: x[0] ' '[:] '='[3] ' '[4] '"'[5]
	// h[6] é[7,8] l l o '"[12] \n[13] y[14] ' '[:] '='[17] ' '1[19] \n[20].
	lspface_default_initialize(t, p, `["utf-16"]`)
	uri := "file:///w/prog.thing"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.thing","languageId":"odin","version":1,"text":"x := \"héllo\"\ny := 1\n"}`)

	hits := make([]lspserver.Diag_Hit, 2, context.temp_allocator)
	hits[0] = {start_byte = 5, end_byte = 12, message = "unterminated string"} // `"héllo`: 7 bytes, 6 utf-16 units
	hits[1] = {start_byte = 19, end_byte = 20, message = "missing semicolon"}
	lspface_set_diagnostics(&p.host, hits)
	// A synced-document answer: the spans index the open buffer's bytes.
	p.host.diagnostics.has_version = true

	lspserver.publish_mark(&p.server, uri, 0)
	clock: platform.Clock
	platform.clock_init(&clock, true)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params) == 2, "both hits publish")
	sl, sc, el, ec := lsppub_diag_pos(t, params, 0)
	testing.expectf(t, sl == 0 && sc == 5 && el == 0 && ec == 11, "hit 0 must convert to (0,5)-(0,11) utf-16, got (%d,%d)-(%d,%d)", sl, sc, el, ec)
	sl, sc, el, ec = lsppub_diag_pos(t, params, 1)
	testing.expectf(t, sl == 1 && sc == 5 && el == 1 && ec == 6, "hit 1 must convert to (1,5)-(1,6), got (%d,%d)-(%d,%d)", sl, sc, el, ec)
}

@(test)
lsppub_close_publishes_empty_immediately :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)
	lspserver.publish_mark(&p.server, uri, 0)

	// The close publish is immediate (not debounced): one empty,
	// UNVERSIONED set — the specification makes the version optional and a
	// close names no version.
	lspface_notify(t, p, lsp.METHOD_DID_CLOSE, `"textDocument":{"uri":"file:///w/prog.go"}`)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params) == uri, "the close publish names the closed document")
	_, has_version := lsppub_version(params)
	testing.expect(t, !has_version, "the close publish must be unversioned")
	testing.expectf(t, lsppub_diag_count(t, params) == 0, "the close publish must be empty")
	testing.expectf(t, len(p.down.buf) == 0, "the close publishes exactly one notification")

	// The due set dropped the uri: the pending window never fires.
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	testing.expectf(t, len(p.down.buf) == 0, "a closed document must not publish through the debounce window")
}

@(test)
lsppub_decline_and_failure_publish_empty_once_logged :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	// A decline publishes the empty set, still version-stamped with the
	// face answer's version, and logs once per open.
	p.host.diagnostics.decline = "no_grammar"
	p.host.diagnostics.version = 7
	p.host.diagnostics.has_version = true
	lspserver.publish_mark(&p.server, uri, 0)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params) == 0, "a declined document publishes empty")
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 7, "the empty publish is still version-stamped, got %d", version)
	testing.expectf(t, len(p.host.logs) == 1, "the decline logs once per open, got %d", len(p.host.logs))
	testing.expectf(t, strings.contains(p.host.logs[0], "no_grammar"), "the decline log names the decline kind")

	// The second window publishes empty again; the latch keeps the log at
	// one line for the open.
	lspserver.publish_mark(&p.server, uri, platform.clock_now(&clock))
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params2 := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params2) == 0, "the second declined window publishes empty too")
	testing.expectf(t, len(p.host.logs) == 1, "the latch holds one line per open, got %d", len(p.host.logs))

	// A fetch failure degrades the same way; with no face answer to stamp,
	// the publish carries the view's version (the client state the empty
	// answer is read against).
	p.host.diagnostics.decline = ""
	p.host.diagnostics.has_version = false
	p.host.diagnostics.failed = true
	p.host.diagnostics.err_message = "the daemon link is down"
	lspserver.publish_mark(&p.server, uri, platform.clock_now(&clock))
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params3 := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params3) == 0, "a failed fetch publishes empty")
	version3, has_version3 := lsppub_version(params3)
	testing.expectf(t, has_version3 && version3 == 1, "a failed fetch stamps the view's version 1, got %d", version3)
	testing.expectf(t, len(p.host.logs) == 1, "the failure stays inside the one-line latch, got %d", len(p.host.logs))
}

// A "\r\n" line ending counts neither half as a line character: a span
// ending on the '\r' converts to the line's text tail, not one past it.
@(test)
lsppub_crlf_line_end_publishes_text_tail_columns :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	// Bytes: x[0] y[1] \r[2] \n[3] z[4] \r[5] \n[6].
	lspface_default_initialize(t, p, `["utf-16"]`)
	uri := "file:///w/crlf.thing"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/crlf.thing","languageId":"odin","version":1,"text":"xy\r\nz\r\n"}`)

	hits := make([]lspserver.Diag_Hit, 1, context.temp_allocator)
	hits[0] = {start_byte = 0, end_byte = 3, message = "through the terminator"} // "xy\r"
	lspface_set_diagnostics(&p.host, hits)
	// A synced-document answer: the spans index the open buffer's bytes.
	p.host.diagnostics.has_version = true

	lspserver.publish_mark(&p.server, uri, 0)
	clock: platform.Clock
	platform.clock_init(&clock, true)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	sl, sc, el, ec := lsppub_diag_pos(t, params, 0)
	testing.expectf(t, sl == 0 && sc == 0 && el == 0 && ec == 2, "a span ending on the '\r' must convert to (0,0)-(0,2), got (%d,%d)-(%d,%d)", sl, sc, el, ec)
}

// The disk-truth degradation: a diagnostics answer without a synced
// version (the daemon's buffer for the document was evicted) carries spans
// that index disk bytes — LF-folded, BOM-stripped — not the open view's
// text. A bounds check alone would pass the shorter spans through and
// misplace their columns; the currency rule publishes the empty set
// stamped with the view's version instead.
@(test)
lsppub_disk_truth_after_eviction_publishes_empty :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	clock: platform.Clock
	platform.clock_init(&clock, true)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":6,"text":"package main\r\n"}`)

	// Spans that fit inside the view's bounds (the disk's folded bytes are
	// SHORTER) — only the missing synced version marks them disk truth.
	hits := make([]lspserver.Diag_Hit, 1, context.temp_allocator)
	hits[0] = {start_byte = 0, end_byte = 7, message = "syntax"}
	lspface_set_diagnostics(&p.host, hits)
	p.host.diagnostics.has_version = false

	lspserver.publish_mark(&p.server, uri, 0)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)
	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_diag_count(t, params) == 0, "disk-truth spans must publish empty, not misplaced columns")
	version, has_version := lsppub_version(params)
	testing.expectf(t, has_version && version == 6, "the empty publish stamps the view's version, got %d", version)
	testing.expectf(t, len(p.host.logs) == 1, "the disk-truth degradation logs once per open, got %d lines", len(p.host.logs))
	testing.expectf(t, strings.contains(p.host.logs[0], "disk truth"), "the log names the disk-truth degradation: %s", p.host.logs[0])
}

// A didClose landing mid-pass — dispatched from inside the diagnostics
// fetch — stays ordered against the close-clear: the pass's fetches run
// outside the lock, so the close frees the view and sends its clear while
// the pass is still working, and the pass's send re-checks the view under
// the same mutex. Exactly one notification goes out — the unversioned
// clear — and the stale set never follows it.
@(test)
lsppub_close_mid_pass_orders_before_the_stale_publish :: proc(t: ^testing.T) {
	p := lspface_pair_init(t)
	defer lspface_pair_destroy(p)

	lspface_default_initialize(t, p, `["utf-8"]`)
	uri := "file:///w/prog.go"
	lspface_notify(t, p, lsp.METHOD_DID_OPEN, `"textDocument":{"uri":"file:///w/prog.go","languageId":"go","version":1,"text":"package main\n"}`)

	hits := make([]lspserver.Diag_Hit, 1, context.temp_allocator)
	hits[0] = {start_byte = 0, end_byte = 7, message = "syntax"}
	lspface_set_diagnostics(&p.host, hits)
	// A synced-document answer: the spans index the open buffer's bytes.
	p.host.diagnostics.has_version = true
	p.host.close_uri = strings.clone(uri, p.host.allocator)

	lspserver.publish_mark(&p.server, uri, 0)
	clock: platform.Clock
	platform.clock_init(&clock, true)
	platform.clock_advance(&clock, lspserver.PUBLISH_DEBOUNCE_MS + 1)
	lspserver.publish_due(&p.server, platform.clock_now(&clock), context.temp_allocator)

	params := lsppub_read_publish(t, p)
	testing.expectf(t, lsppub_uri(t, params) == uri, "the close publish names the closed document")
	_, has_version := lsppub_version(params)
	testing.expect(t, !has_version, "the close publish must be unversioned")
	testing.expectf(t, lsppub_diag_count(t, params) == 0, "the close publish must be empty")
	testing.expectf(t, len(p.down.buf) == 0, "no publish may follow the close-clear")
	testing.expectf(t, len(p.host.closes) == 1 && p.host.closes[0] == uri, "the mid-pass close must reach the host callback")
}

// Tests for the svc.doc/diagnostics face: syntax diagnostics served over
// the real daemon handler against the same real TS_Source + Doc_Sync pair
// the highlights face tests drive (that fixture and the JSON field
// helpers are shared, not redefined — one tests package). Covers the
// degradation ladder (no_grammar, source_too_large), the version
// contract, unsaved-client-text truth, the DIAGNOSTICS_MAX truncation
// flag, and — engine-direct — the iterative walk's survival on
// pathological nesting depth, the stack-hazard regression.
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:daemon"
import "jsonutil:jsonutil"
import "src:platform"
import "src:svc"
import "src:ts"

// dface_call drives the real handler; the params object and the result
// live in the caller's arena.
dface_call :: proc(f: ^Hlface_Fixture, rel: string, a: mem.Allocator) -> (json.Value, platform.Err) {
	ctx := hlface_ctx(f, a)
	body := strings.concatenate({`{"relative_path": "`, rel, `"}`}, a)
	return daemon.handle_doc_diagnostics(&ctx, hlface_params(body, a))
}

// dface_diags_valid fetches the response's diagnostics array and checks
// the invariants every answer must hold: kinds from the walk's wire
// vocabulary, spans inside the KNOWN text (0 <= start <= end <= len),
// starts ascending. It returns the array with the kind counts, so a test
// asserts its own coverage honestly (an assertion over an empty array
// proves nothing).
dface_diags_valid :: proc(t: ^testing.T, result: json.Value, text: string) -> (arr: json.Value, errors, missings: int) {
	got, aok := jsonutil.obj_get(result, "diagnostics")
	testing.expect_value(t, aok, true)
	if !aok {
		return
	}
	arr = got
	n := json_array_len(arr)
	prev: i64 = -1
	for i in 0..<n {
		e := json_array_at(arr, i)
		kind, kok := json_str_field(e, "kind")
		testing.expectf(t, kok && (kind == "error" || kind == "missing"), "diagnostic %d carries kind %q", i, kind)
		start, sok := json_int_field(e, "start_byte")
		end, eok := json_int_field(e, "end_byte")
		testing.expectf(t, sok && eok, "diagnostic %d lacks its span", i)
		if !sok || !eok {
			continue
		}
		testing.expectf(
			t,
			0 <= start && start <= end && end <= i64(len(text)),
			"diagnostic %d span [%d,%d) escapes the %d-byte text",
			i, start, end, len(text),
		)
		testing.expectf(t, start >= prev, "diagnostic %d starts before its predecessor", i)
		prev = start
		if kind == "error" {
			errors += 1
		} else if kind == "missing" {
			missings += 1
		}
	}
	return
}

// dface_has_span_exact reports whether some diagnostic's range slices
// exactly `want` out of the known text.
dface_has_span_exact :: proc(result: json.Value, text, want: string) -> bool {
	arr, ok := jsonutil.obj_get(result, "diagnostics")
	if !ok {
		return false
	}
	n := json_array_len(arr)
	for i in 0..<n {
		e := json_array_at(arr, i)
		start, sok := json_int_field(e, "start_byte")
		end, eok := json_int_field(e, "end_byte")
		if !sok || !eok {
			continue
		}
		if 0 <= start && start <= end && end <= i64(len(text)) && text[start:end] == want {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// 1. Broken source through the face, with the open's version
// ---------------------------------------------------------------------------

@(test)
dface_error_diagnostics_over_synced_document :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The client text is broken where the disk text is clean, so only the
	// synced bytes can explain an error diagnostic.
	text := "package main\nfunc broken( {\n"
	hlface_write_file(t, f, "broken.go", "package main\n")
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "broken.go", "go", 11, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	result, err := dface_call(f, "broken.go", a)
	testing.expectf(t, err == nil, "diagnostics: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	version, vok := json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 11)
	}
	has_version, hok := hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, has_version, "an applied document must carry its version")
	}
	_, errors, _ := dface_diags_valid(t, result, text)
	testing.expectf(t, errors >= 1, "a broken document must answer at least one error diagnostic")
}

// ---------------------------------------------------------------------------
// 2. MISSING recovery through the face
// ---------------------------------------------------------------------------

// The short-variable-declaration shape the engine tests prove recovers by
// insertion (a zero-width MISSING leaf), served through the face.
@(test)
dface_missing_diagnostics_over_the_face :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	text := "package main\n\nfunc main() {\n\tx :=\n}\n"
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "missing.go", "go", 4, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	result, err := dface_call(f, "missing.go", a)
	testing.expectf(t, err == nil, "diagnostics: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	_, _, missings := dface_diags_valid(t, result, text)
	testing.expectf(t, missings >= 1, "an incomplete declaration must answer a missing diagnostic")
}

// ---------------------------------------------------------------------------
// 3. Clean source and the version contract (open -> change -> close)
// ---------------------------------------------------------------------------

@(test)
dface_clean_source_and_version_contract :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	clean := "package main\n\nfunc dface_clean_fn() {}\n"
	hlface_write_file(t, f, "clean.go", clean)

	// Closed: disk truth, no version, no diagnostics.
	result, err := dface_call(f, "clean.go", a)
	testing.expectf(t, err == nil, "closed call: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	has_version, hok := hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, !has_version, "no document is open — disk truth carries no version")
	}
	version, vok := json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 0)
	}
	_, errors, missings := dface_diags_valid(t, result, clean)
	testing.expect_value(t, errors, 0)
	testing.expect_value(t, missings, 0)

	// Open applies the client bytes: the answer's version follows the
	// document, not the call order.
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "clean.go", "go", 3, clean, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	result, err = dface_call(f, "clean.go", a)
	testing.expectf(t, err == nil, "open call: %v", err)
	if err != nil {
		return
	}
	version, vok = json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 3)
	}

	_, cerr := svc.doc_sync_change(f.ds, "clean.go", 4, clean, nil, deadline, a)
	testing.expectf(t, cerr == nil, "change failed: %v", cerr)
	if cerr != nil {
		return
	}
	result, err = dface_call(f, "clean.go", a)
	testing.expectf(t, err == nil, "changed call: %v", err)
	if err != nil {
		return
	}
	version, vok = json_int_field(result, "version")
	testing.expect_value(t, vok, true)
	if vok {
		testing.expect_value(t, version, 4)
	}

	// Close reverts the answer to disk truth.
	clerr := svc.doc_sync_close(f.ds, "clean.go", a)
	testing.expectf(t, clerr == nil, "close failed: %v", clerr)
	if clerr != nil {
		return
	}
	result, err = dface_call(f, "clean.go", a)
	testing.expectf(t, err == nil, "post-close call: %v", err)
	if err != nil {
		return
	}
	has_version, hok = hlface_bool_field(result, "has_version")
	testing.expect_value(t, hok, true)
	if hok {
		testing.expect(t, !has_version, "the document was closed")
	}
}

// ---------------------------------------------------------------------------
// 4. Degradation ladder: no_grammar, source_too_large
// ---------------------------------------------------------------------------

@(test)
dface_declines_no_grammar :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// No grammar serves .txt — the ladder's first rung, answered before
	// any parse.
	hlface_write_file(t, f, "notes.txt", "plain text\n")

	result, err := dface_call(f, "notes.txt", a)
	testing.expectf(t, err == nil, "diagnostics: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "no_grammar")
	_, errors, missings := dface_diags_valid(t, result, "")
	testing.expect_value(t, errors, 0)
	testing.expect_value(t, missings, 0)
}

@(test)
dface_declines_source_too_large :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Disk truth over the bound (no document open): the gate fires before
	// any parse. The face inherits the highlights face's magnitude — same
	// source class, same whole-file parse — instead of a second number.
	big, rerr := strings.repeat("a", ts.HIGHLIGHTS_MAX_SOURCE_BYTES + 16)
	testing.expectf(t, rerr == nil, "repeat failed: %v", rerr)
	if rerr != nil {
		return
	}
	hlface_write_file(t, f, "big.go", big)
	delete(big, context.allocator)

	result, err := dface_call(f, "big.go", a)
	testing.expectf(t, err == nil, "diagnostics: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "source_too_large")
	_, errors, missings := dface_diags_valid(t, result, "")
	testing.expect_value(t, errors, 0)
	testing.expect_value(t, missings, 0)
}

// ---------------------------------------------------------------------------
// 5. Unsaved text: the ranges slice the CLIENT's bytes, not the disk's
// ---------------------------------------------------------------------------

@(test)
dface_serves_unsaved_client_text_not_disk :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The disk file is broken near its END (a long tail); the client text
	// is broken at that same offset with a one-byte stray token and is
	// SHORTER than the disk text. A disk-served range would overflow the
	// client bounds; a client-served error range slices exactly "@".
	disk_text := "package main\n\nfunc ok_fn() {}\n\nfunc disk_broken( {\n"
	hlface_write_file(t, f, "unsaved.go", disk_text)
	client_text := "package main\n\nfunc ok_fn() {}\n\n@\n"
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "unsaved.go", "go", 2, client_text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	result, err := dface_call(f, "unsaved.go", a)
	testing.expectf(t, err == nil, "diagnostics: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	// Every span is bounds-checked against the CLIENT text inside
	// dface_diags_valid — the disk text is longer, so a disk-served range
	// cannot pass — and the stray byte is covered exactly.
	dface_diags_valid(t, result, client_text)
	testing.expect(
		t,
		dface_has_span_exact(result, client_text, "@"),
		"the face must diagnose the unsaved client text's stray byte",
	)
}

// ---------------------------------------------------------------------------
// 6. The DIAGNOSTICS_MAX bound truncates observably
// ---------------------------------------------------------------------------

// 600 stray tokens, each between valid statements: the resync-friendly
// shape where tree-sitter recovers per token, so the walk collects past
// the bound and the face cuts the wire answer to DIAGNOSTICS_MAX with
// truncated set.
@(test)
dface_truncates_at_the_bound :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	b := strings.builder_make_len_cap(0, 600*20+64, context.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "package main\n\nfunc f() {\n")
	for _ in 0..<600 {
		strings.write_string(&b, "\tx := 1\n\t@\n")
	}
	strings.write_string(&b, "}\n")
	// to_string views the builder's buffer — clone out before it dies.
	text := strings.clone(strings.to_string(b), context.allocator)
	defer delete(text, context.allocator)

	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "bound.go", "go", 1, text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	result, err := dface_call(f, "bound.go", a)
	testing.expectf(t, err == nil, "diagnostics: %v", err)
	if err != nil {
		return
	}
	decline, _ := json_str_field(result, "decline")
	testing.expect_value(t, decline, "")
	truncated, tok := hlface_bool_field(result, "truncated")
	testing.expect_value(t, tok, true)
	if tok {
		testing.expect(t, truncated, "a source past the bound must answer truncated")
	}
	arr, errors, _ := dface_diags_valid(t, result, text)
	n := json_array_len(arr)
	testing.expectf(t, n == ts.DIAGNOSTICS_MAX, "a truncated answer serves exactly the bound, got %d", n)
	testing.expectf(t, errors >= 1, "a truncated answer must still carry diagnostics")
}

// ---------------------------------------------------------------------------
// 7. Engine-direct: the iterative walk survives pathological nesting
// ---------------------------------------------------------------------------

// A file of 100_000 unmatched open parens is the deep-nesting hazard the
// walk's explicit stack exists for — a recursive walk would overflow the
// daemon thread's stack exactly here. Parse and walk complete; every
// diagnostic stays inside the source (diag_check_flat, shared with the
// engine tests). The recovery shape is not pinned: broken bytes may come
// back as ERROR regions, inserted MISSING leaves, or both.
@(test)
dface_walk_survives_deep_nesting :: proc(t: ^testing.T) {
	source, rerr := strings.repeat("(", 100_000)
	testing.expectf(t, rerr == nil, "repeat failed: %v", rerr)
	if rerr != nil {
		return
	}
	defer delete(source, context.allocator)

	pr, perr := ts.parse(source, "go")
	testing.expectf(t, perr == "", "parse: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	diags := ts.diagnostics_tree(pr.tree, context.allocator)
	defer ts.diagnostics_destroy(diags)
	diag_check_flat(t, diags, len(source))
	testing.expectf(t, len(diags) >= 1, "a fully broken source must carry damage")
}

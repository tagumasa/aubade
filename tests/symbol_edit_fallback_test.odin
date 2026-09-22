// Tests for the symbol-edit path's TS→LSP source order: files the
// tree-sitter pass cannot outline (no grammar) resolve through the LSP
// producer's document symbols and edit through the same editor
// transactions, while grammar-backed files never contact a language
// server (a name-path typo answers from the TS outline alone).
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:editor"
import "src:jsonrpc"
import "src:lsp"
import "src:platform"
import "src:store"
import "src:svc"

// h_zork_symbols_from_line0 answers with one function covering the
// whole file (lines 0..2).
h_zork_symbols_from_line0 :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"name":"alpha","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":1}},"selectionRange":{"start":{"line":0,"character":3},"end":{"line":0,"character":8}}}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// h_zork_symbols_after_comment answers with one function starting below
// a leading comment line (the docstring ops scan upward past it).
h_zork_symbols_after_comment :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"name":"alpha","kind":12,"range":{"start":{"line":1,"character":0},"end":{"line":3,"character":1}},"selectionRange":{"start":{"line":1,"character":3},"end":{"line":1,"character":8}}}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// h_zork_document_symbol_error answers the request with a protocol error:
// the port succeeded, so the producer already holds the server pin when
// the round trip fails.
h_zork_document_symbol_error :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	return {is_error = true, err_code = .Internal_Error, err_message = "zork server exploded"}, .Respond
}

// h_zork_flat_symbols answers with the flat SymbolInformation form —
// servers that never grew hierarchical DocumentSymbol reply this way, and
// the body range rides in the location.
h_zork_flat_symbols :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"name":"alpha","kind":12,"location":{"uri":"file:///proj/g.zork","range":{"start":{"line":1,"character":0},"end":{"line":3,"character":1}}}}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// h_zork_two_alphas answers with the same leaf name under two different
// parents: a bare pattern suffix-matches both, and neither full path is
// the exact pattern — the unique find must refuse. (Two same-named
// siblings instead get overload indices; a bare name matches the first
// by design, so that shape is not ambiguous.)
h_zork_two_alphas :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"name":"One","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":4,"character":1}},"selectionRange":{"start":{"line":0,"character":4},"end":{"line":0,"character":7}},"children":[{"name":"alpha","kind":12,"range":{"start":{"line":1,"character":2},"end":{"line":3,"character":3}},"selectionRange":{"start":{"line":1,"character":5},"end":{"line":1,"character":10}}}]},{"name":"Two","kind":23,"range":{"start":{"line":5,"character":0},"end":{"line":9,"character":1}},"selectionRange":{"start":{"line":5,"character":4},"end":{"line":5,"character":7}},"children":[{"name":"alpha","kind":12,"range":{"start":{"line":6,"character":2},"end":{"line":8,"character":3}},"selectionRange":{"start":{"line":6,"character":5},"end":{"line":6,"character":10}}}]}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// Symbol_Edit_Fallback_Env is the shared harness: temp project root with
// the fixture written, real SQLite + clock, a TS source, an editor, and
// an LSP source wired to a fake peer (or a refusing port when
// with_client=false — its failure is the proof a path never called it).
Symbol_Edit_Fallback_Env :: struct {
	dir:     string,
	db_dir:  string,
	db:      ^store.DB,
	clock:   ^platform.Clock,
	ts_src:  ^svc.TS_Source,
	lsp_src: ^svc.LSP_Source,
	ed:      ^editor.Editor,
	pair:    ^Lsp_Pair,
	port:    Fake_LSP_Port,
}

symbol_edit_fallback_setup :: proc(t: ^testing.T, name: string, content: string, with_client: bool) -> ^Symbol_Edit_Fallback_Env {
	env := new(Symbol_Edit_Fallback_Env, context.allocator)
	dir, derr := os.make_directory_temp("", "aubade-symfb-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	db_dir, dderr := os.make_directory_temp("", "aubade-symfbdb-", context.allocator)
	testing.expectf(t, dderr == nil, "temp db dir failed")
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "db open failed")

	lsp_write_file(dir, name, content)

	env.dir = dir
	env.db_dir = db_dir
	env.db = db
	env.clock = new(platform.Clock, context.allocator)
	platform.clock_init(env.clock, true, context.allocator)
	env.ts_src = new(svc.TS_Source, context.allocator)
	svc.ts_source_init(env.ts_src, dir, db, env.clock, context.allocator)
	env.ed = new(editor.Editor, context.allocator)
	editor.editor_init(env.ed, dir, .Lf, "", svc.editor_file_io_port(), context.allocator)

	if with_client {
		p := lsp_pair_init(t)
		testing.expectf(t, p != nil, "lsp pair init failed")
		if p == nil {
			// The pair never came alive; free what setup already owns
			// (an early return past live state must not skip cleanup).
			editor.editor_destroy(env.ed)
			free(env.ed, context.allocator)
			svc.ts_source_destroy(env.ts_src)
			free(env.ts_src, context.allocator)
			platform.clock_destroy(env.clock)
			free(env.clock, context.allocator)
			store.db_close(env.db)
			_ = os.remove_all(env.dir)
			delete(env.dir)
			_ = os.remove_all(env.db_dir)
			delete(env.db_dir)
			free(env, context.allocator)
			return nil
		}
		env.pair = p
		env.port = {client = p.client, language_id = "zork"}
	} else {
		env.port = {fail = true}
	}
	env.lsp_src = new(svc.LSP_Source, context.allocator)
	svc.lsp_source_init(env.lsp_src, dir, db, env.clock, nil, fake_lsp_port, &env.port, fake_lsp_release, context.allocator)
	return env
}

symbol_edit_fallback_teardown :: proc(env: ^Symbol_Edit_Fallback_Env) {
	editor.editor_destroy(env.ed)
	free(env.ed, context.allocator)
	svc.lsp_source_destroy(env.lsp_src)
	free(env.lsp_src, context.allocator)
	svc.ts_source_destroy(env.ts_src)
	free(env.ts_src, context.allocator)
	if env.pair != nil {
		lsp_pair_shutdown(env.pair)
	}
	// Both sources referenced the clock; it dies after they do.
	platform.clock_destroy(env.clock)
	free(env.clock, context.allocator)
	store.db_close(env.db)
	_ = os.remove_all(env.dir)
	delete(env.dir)
	_ = os.remove_all(env.db_dir)
	delete(env.db_dir)
	free(env, context.allocator)
}

// symbol_edit_fallback_read returns the file's current bytes as an
// owned string (the read itself is scratch).
symbol_edit_fallback_read :: proc(t: ^testing.T, env: ^Symbol_Edit_Fallback_Env, name: string) -> string {
	path, _ := filepath.join([]string{env.dir, name}, context.temp_allocator)
	data, ok := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expectf(t, ok == nil, "read back %s failed", name)
	return strings.clone(string(data), context.allocator)
}

// A grammar-less file resolves through the fake server's document
// symbols and the edit lands on disk through the normal editor path.
@(test)
symbol_edit_lsp_fallback_replaces_body :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "a.zork",
		"fn alpha {\n  ret 1\n}\n",
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_symbols_from_line0)

	// The ops allocate their forests in `a` — the request arena in
	// production; a per-test arena plays that role here.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "a.zork",
		"fn alpha {\n  ret 42\n}",
		env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expectf(t, err == nil, "replace: %s", platform.err_message(err))

	got := symbol_edit_fallback_read(t, env, "a.zork")
	defer delete(got, context.allocator)
	testing.expect(t, strings.contains(got, "ret 42"))
	testing.expect(t, !strings.contains(got, "ret 1"))
	testing.expect_value(t, strings.count(got, "fn alpha"), 1)
}

// The fallback's language id feeds the comment patterns: the docstring
// replace scans upward with the C-family default for an unlisted id.
@(test)
symbol_edit_lsp_fallback_replaces_docstring :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "b.zork",
		"// old note.\nfn alpha {\n  ret 1\n}\n",
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_symbols_after_comment)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_docstring(
		env.ts_src, env.ed, "alpha", "b.zork",
		"// new note.", env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expectf(t, err == nil, "replace docstring: %s", platform.err_message(err))

	got := symbol_edit_fallback_read(t, env, "b.zork")
	defer delete(got, context.allocator)
	testing.expect(t, !strings.contains(got, "old note"))
	testing.expect(t, strings.contains(got, "// new note.\nfn alpha"))
}

// A grammar-backed file with a name-path typo answers from the TS
// outline alone: the refusing port proves the fallback is never reached
// (a wrongly-fired one would surface the port's refusal instead of the
// find error).
@(test)
symbol_edit_typo_on_grammar_file_never_contacts_lsp :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "c.go",
		"package main\n\nfunc beta() int {\n\treturn 2\n}\n",
		with_client = false,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "nosuch", "c.go", "x",
		env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expect(t, err != nil, "typo must fail")
	testing.expect(
		t, platform.err_kind(err) == .NotFound,
		"No_Match maps to NotFound, got %s", platform.kind_name(platform.err_kind(err)),
	)
	msg := platform.err_message(err)
	testing.expect(t, strings.contains(msg, "no symbol matching 'nosuch'"), "find error expected, got: %s", msg)
}

// A documentSymbol error reply must still return the server pin: the
// producer's error contract empties its returns, so the producer drops
// its own hand-out — before the fix the pin leaked (a retired server is
// destroyed only at inflight zero).
@(test)
symbol_edit_lsp_fallback_request_error_releases_pin :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "e.zork",
		"fn alpha {\n  ret 1\n}\n",
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_document_symbol_error)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "e.zork", "x",
		env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expect(t, err != nil, "the request failure must propagate")
	testing.expect_value(t, env.port.releases, 1)
}

// A second edit over byte-identical content resolves from the L1 payload
// row: no port round trip (the release count stays at one), and the edit
// still applies through the cached ranges.
@(test)
symbol_edit_lsp_fallback_second_edit_serves_from_l1 :: proc(t: ^testing.T) {
	content := "fn alpha {\n  ret 1\n}\n"
	env := symbol_edit_fallback_setup(
		t, "f.zork",
		content,
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_symbols_from_line0)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	first := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "f.zork",
		"fn alpha {\n  ret 42\n}", env.lsp_src, alloc,
	)
	testing.expectf(t, first == nil, "first edit: %s", platform.err_message(first))
	testing.expect_value(t, env.port.releases, 1)

	// The producer's contents come from the disk here (the harness wires
	// no editor into the LSP source), so restoring the exact indexed
	// bytes makes the next resolve an L1 hit.
	lsp_write_file(env.dir, "f.zork", content)

	second := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "f.zork",
		"fn alpha {\n  ret 99\n}", env.lsp_src, alloc,
	)
	testing.expectf(t, second == nil, "second edit: %s", platform.err_message(second))
	testing.expect_value(t, env.port.releases, 1) // unchanged: the hit path pins nothing

	got := symbol_edit_fallback_read(t, env, "f.zork")
	defer delete(got, context.allocator)
	testing.expect(t, strings.contains(got, "ret 99"))
	testing.expect(t, !strings.contains(got, "ret 1"))
}

// Flat SymbolInformation replies carry the body range in their location;
// the converter mirrors it into rng so the edit applies. The astral emoji
// on the comment line also pins the byte line-start bookkeeping.
@(test)
symbol_edit_lsp_fallback_flat_reply :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "g.zork",
		"// 😀 注釈\nfn alpha {\n  ret 1\n}\n",
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_flat_symbols)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "g.zork",
		"fn alpha {\n  ret 42\n}", env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expectf(t, err == nil, "flat reply edit: %s", platform.err_message(err))

	got := symbol_edit_fallback_read(t, env, "g.zork")
	defer delete(got, context.allocator)
	testing.expect(t, strings.contains(got, "ret 42"))
	testing.expect(t, !strings.contains(got, "ret 1"))
	testing.expect_value(t, strings.count(got, "fn alpha"), 1)
}

// Non-ASCII content through the whole seam: multi-byte lines shift byte
// line starts, and the UTF-16 columns must land on the right bytes.
@(test)
symbol_edit_lsp_fallback_non_ascii_content :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "i.zork",
		"// 😀 注釈\nfn alpha {\n  ret 「四十二」\n}\n",
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_symbols_after_comment)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "i.zork",
		"fn alpha {\n  ret 42\n}", env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expectf(t, err == nil, "non-ascii edit: %s", platform.err_message(err))

	got := symbol_edit_fallback_read(t, env, "i.zork")
	defer delete(got, context.allocator)
	testing.expect(t, strings.contains(got, "ret 42"))
	testing.expect(t, !strings.contains(got, "「四十二」"))
}

// The same leaf name under two different parents is ambiguous for a
// bare pattern; the unique find must refuse before any edit.
@(test)
symbol_edit_lsp_fallback_ambiguous_name :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "h.zork",
		"grp One {\n  fn alpha {\n    ret 1\n  }\n}\ngrp Two {\n  fn alpha {\n    ret 2\n  }\n}\n",
		with_client = true,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	jsonrpc.conn_register(env.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_zork_two_alphas)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "h.zork", "x",
		env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expect(t, err != nil, "ambiguous name must fail")
	testing.expect(
		t, platform.err_kind(err) == .Invalid,
		"Ambiguous maps to Invalid, got %s", platform.kind_name(platform.err_kind(err)),
	)
	msg := platform.err_message(err)
	testing.expect(t, strings.contains(msg, "multiple symbols match"), "ambiguity error expected, got: %s", msg)
}

// An external writer rewrites a buffered grammar-backed file: the TS arm
// resolves through the editor's view and the editor adopts the external
// bytes on reuse, so the second edit builds on the NEW disk content.
// Pre-fix the fresh-disk positions landed on the stale buffer (position
// outside file) — or, with a view-unified-but-stale buffer, the save
// would revert the external change wholesale.
@(test)
symbol_edit_ts_arm_builds_on_external_change :: proc(t: ^testing.T) {
	env := symbol_edit_fallback_setup(
		t, "shift.go",
		"package main\n\nfunc alpha() int {\n\treturn 1\n}\n",
		with_client = false,
	)
	if env == nil {
		return
	}
	defer symbol_edit_fallback_teardown(env)
	// The daemon wires the TS source's editor view; the harness default
	// (nil) is the pure-disk test configuration.
	env.ts_src.ed = env.ed

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	// Edit #1 opens the buffer (and saves synchronously).
	err := svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "shift.go",
		"func alpha() int {\n\treturn 11\n}",
		env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expectf(t, err == nil, "edit1: %s", platform.err_message(err))

	// The external writer moves alpha deep into a longer file: the old
	// buffer ends at line 4, the new alpha body ends at line 14, so
	// positions resolved against one view cannot land on the other.
	external := strings.concatenate({
		"package main\n",
		"// pad line 2\n// pad line 3\n// pad line 4\n// pad line 5\n",
		"// pad line 6\n// pad line 7\n// pad line 8\n// pad line 9\n",
		"// pad line 10\n// pad line 11\n// pad line 12\n",
		"func alpha() int {\n\treturn 2\n}\n",
	}, context.temp_allocator)
	lsp_write_file(env.dir, "shift.go", external)

	// Edit #2 targets alpha in the external content.
	err = svc.symbol_edit_replace_body(
		env.ts_src, env.ed, "alpha", "shift.go",
		"func alpha() int {\n\treturn 42\n}",
		env.lsp_src, mem.dynamic_arena_allocator(&arena),
	)
	testing.expectf(t, err == nil, "edit2: %s", platform.err_message(err))

	got := symbol_edit_fallback_read(t, env, "shift.go")
	defer delete(got, context.allocator)
	testing.expect(t, strings.contains(got, "return 42"))
	testing.expect(t, !strings.contains(got, "return 2"))
	// The external padding survived — the edit built ON the new bytes.
	testing.expect(t, strings.contains(got, "// pad line 12"))
	testing.expect_value(t, strings.count(got, "func alpha"), 1)

	// The read side resolves the same live view: the fresh outline
	// carries the externally moved symbol without any crawl.
	roots, terr := svc.ts_source_file_symbols(env.ts_src, "shift.go", mem.dynamic_arena_allocator(&arena))
	testing.expectf(t, terr == nil, "symbols: %s", platform.err_message(terr))
	found := false
	for r in roots {
		if r.name == "alpha" {
			found = true
		}
	}
	testing.expect(t, found, "alpha missing from the live-view outline")
}

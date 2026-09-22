// Contract tests for the five LSP-required symbol ops over a fake-peer
// language server: name-path resolution through document symbols, the
// references filters (self/import/file-symbol fallback), implementation
// resolution with hover info, declaration anchoring, the rename workspace
// edit applied through the real editor to real temp files, and the
// references-checked delete (refusal + both delete forms). Everything
// rides the Client_For_File_Proc seam — no manager, no process. Handlers
// never call testing.fail_now (a live pair would wedge the runner); every
// failing expectation is followed by an early return while the fixture
// teardown stays on the defer stack. Op results live on a per-test arena
// (the op frees its internal caches; the results themselves die with the
// arena, the same free_all discipline the daemon's request arenas use).
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:editor"
import "src:jsonrpc"
import "src:jsonutil"
import "src:lsp"
import "src:platform"
import "src:store"
import "src:safety"
import "src:symbol"
import "src:svc"
import "src:tools"
import "src:util"

Sym_Lsp_Fixture :: struct {
	dir:    string,
	db_dir: string,
	db:     ^store.DB,
	clock:  ^platform.Clock,
	ed:     ^editor.Editor,
	src:    ^svc.LSP_Source,
	pair:   ^Lsp_Pair,
	port:   Fake_LSP_Port,
}

// sym_fixture builds the two-file project, the editor, and the fake-peer
// LSP source. a.go declares Widget on line 3 (a comment line above); b.go
// holds the function Make whose body references it on line 3.
// bare_locations hands the peer the ols-like capability set (definition
// and references only) for the capability-gate decline tests.
sym_fixture :: proc(t: ^testing.T, bare_locations: bool = false) -> ^Sym_Lsp_Fixture {
	f := new(Sym_Lsp_Fixture, context.allocator)

	f.dir, _ = os.make_directory_temp("", "aubade-symlsp-", context.allocator)
	f.db_dir, _ = os.make_directory_temp("", "aubade-symlspdb-", context.allocator)
	testing.expectf(t, f.dir != "" && f.db_dir != "", "temp dirs failed")
	if f.dir == "" || f.db_dir == "" {
		sym_fixture_destroy(f)
		return nil
	}
	db_path, _ := filepath.join([]string{f.db_dir, "symbols.db"}, context.allocator)
	defer delete(db_path)
	f.db, _ = store.db_open(db_path, context.allocator)
	testing.expectf(t, f.db != nil, "db open failed")

	lsp_write_file(f.dir, "a.go", "package a\n\n// Widget is a thing.\ntype Widget struct{}\n")
	lsp_write_file(f.dir, "b.go", "package b\n\nfunc Make() {\n\t_ = a.Widget{}\n}\n")

	f.clock = new(platform.Clock, context.allocator)
	platform.clock_init(f.clock, true, context.allocator)
	f.ed = new(editor.Editor, context.allocator)
	editor.editor_init(f.ed, f.dir, .Lf, "", svc.editor_file_io_port(), context.allocator)

	f.pair = lsp_pair_init(t)
	if f.pair == nil {
		testing.expectf(t, false, "pair init failed")
		sym_fixture_destroy(f)
		return nil
	}
	f.pair.fake.bare_locations = bare_locations
	root_uri := strings.concatenate({"file://", f.dir}, context.temp_allocator)
	folders := []lsp.Folder{{uri = root_uri, name = "proj"}}
	_, _, _, ierr := lsp.client_initialize(f.pair.client, folders, context.temp_allocator)
	testing.expect_value(t, ierr, jsonrpc.Call_Err.None)
	// The handshake does not derive the workspace root (the production
	// factory assigns it): without it, location enrichment cannot turn
	// server URIs into project-relative paths. Mirror the factory's
	// canonicalization: the base must carry the symlink-resolved spelling
	// (macOS temp trees sit behind /var -> /private/var) or every prefix
	// compare against editor/index paths misses.
	root_base := f.dir
	if resolved, perr := safety.pathguard_validate_contained_dir(f.dir, f.dir, context.temp_allocator); perr.reason == "" {
		root_base = resolved
	}
	f.pair.client.root_abs = strings.clone(root_base, f.pair.client.allocator)

	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_sym_document_symbols)
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_REFERENCES, h_sym_references)
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_IMPLEMENTATION, h_sym_implementation)
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_DECLARATION, h_sym_declaration)
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_RENAME, h_sym_rename)
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_HOVER, h_sym_hover)

	f.port = Fake_LSP_Port{client = f.pair.client, language_id = "go", normalize = lsp_split_receiver}
	f.src = new(svc.LSP_Source, context.allocator)
	svc.lsp_source_init(f.src, f.dir, f.db, f.clock, f.ed, fake_lsp_port, &f.port, nil, context.allocator)
	return f
}

sym_fixture_destroy :: proc(f: ^Sym_Lsp_Fixture) {
	if f.src != nil {
		svc.lsp_source_destroy(f.src)
		free(f.src, context.allocator)
		f.src = nil
	}
	if f.pair != nil {
		lsp_pair_shutdown(f.pair)
		f.pair = nil
	}
	if f.ed != nil {
		editor.editor_destroy(f.ed)
		free(f.ed, context.allocator)
		f.ed = nil
	}
	if f.clock != nil {
		platform.clock_destroy(f.clock)
		free(f.clock, context.allocator)
		f.clock = nil
	}
	if f.db != nil {
		store.db_close(f.db)
		f.db = nil
	}
	if f.dir != "" {
		_ = os.remove_all(f.dir)
		delete(f.dir)
		f.dir = ""
	}
	if f.db_dir != "" {
		_ = os.remove_all(f.db_dir)
		delete(f.db_dir)
		f.db_dir = ""
	}
	free(f, context.allocator)
}

// sym_req_uri pulls params.textDocument.uri out of a request envelope.
sym_req_uri :: proc(env: ^jsonrpc.Envelope, arena: mem.Allocator) -> string {
	td, ok := jsonutil.obj_get(env.params, "textDocument")
	if !ok {
		return ""
	}
	u, uok := jsonutil.obj_get(td, "uri")
	if !uok {
		return ""
	}
	return jsonutil.value_str(u)
}

// h_sym_document_symbols answers per file: a.go declares Widget on line
// 3 (selection at col 5), b.go declares Make spanning lines 2-4
// (selection at line 2 col 5).
h_sym_document_symbols :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	uri := sym_req_uri(env, arena)
	body := "[]"
	if strings.contains(uri, "a.go") {
		body = `[{"name":"Widget","kind":23,"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":19}},"selectionRange":{"start":{"line":3,"character":5},"end":{"line":3,"character":11}}}]`
	} else if strings.contains(uri, "b.go") {
		body = `[{"name":"Make","kind":12,"range":{"start":{"line":2,"character":0},"end":{"line":4,"character":1}},"selectionRange":{"start":{"line":2,"character":5},"end":{"line":2,"character":9}}}]`
	}
	v, _ := json.parse_string(body, spec = .JSON, parse_integers = true, allocator = arena)
	return {result = v}, .Respond
}

// h_sym_references answers three sites for the Widget position: the
// symbol's own declaration (a.go line 3 col 5), a use inside Make's body
// (b.go line 3 col 6), and an uncontained site on b.go's package line
// (line 0).
h_sym_references :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	return sym_locations_reply(env, arena, {
		{same_file = true, line = 3, start_col = 5, end_col = 11},
		{same_file = false, line = 3, start_col = 6, end_col = 12},
		{same_file = false, line = 0, start_col = 8, end_col = 9},
	})
}

// h_sym_references_none answers no sites (the unreferenced-symbol case).
h_sym_references_none :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string("[]", spec = .JSON, parse_integers = true, allocator = arena)
	return {result = v}, .Respond
}

Sym_Site :: struct {
	same_file: bool,
	line:      int,
	start_col: int,
	end_col:   int,
}

// sym_locations_reply builds a Location[] answer for a request against
// a.go: same_file sites reuse the requested URI, others point at b.go.
sym_locations_reply :: proc(env: ^jsonrpc.Envelope, arena: mem.Allocator, sites: []Sym_Site) -> (jsonrpc.Reply, jsonrpc.Action) {
	uri := sym_req_uri(env, arena)
	if !strings.contains(uri, "a.go") {
		v, _ := json.parse_string("[]", spec = .JSON, parse_integers = true, allocator = arena)
		return {result = v}, .Respond
	}
	b_uri := strings.concatenate({uri[:len(uri) - len("a.go")], "b.go"}, arena)
	body := strings.builder_make(arena)
	strings.write_string(&body, "[")
	for s, i in sites {
		if i > 0 {
			strings.write_string(&body, ",")
		}
		target := uri
		if !s.same_file {
			target = b_uri
		}
		seg := strings.concatenate({
			`{"uri":"`, target,
			`","range":{"start":{"line":`, util.int_to_dec(s.line, arena),
			`,"character":`, util.int_to_dec(s.start_col, arena),
			`},"end":{"line":`, util.int_to_dec(s.line, arena),
			`,"character":`, util.int_to_dec(s.end_col, arena),
			`}}}`,
		}, arena)
		strings.write_string(&body, seg)
	}
	strings.write_string(&body, "]")
	v, perr := json.parse_string(strings.to_string(body), spec = .JSON, parse_integers = true, allocator = arena)
	_ = perr
	return {result = v}, .Respond
}

// h_sym_implementation reports Make as the implementation.
h_sym_implementation :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	return sym_locations_reply(env, arena, {
		{same_file = false, line = 2, start_col = 5, end_col = 9},
	})
}

// h_sym_declaration points back at Widget's declaration position.
h_sym_declaration :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	return sym_locations_reply(env, arena, {
		{same_file = true, line = 3, start_col = 5, end_col = 11},
	})
}

// h_sym_rename renames Widget to Gadget in both files (documentChanges
// form, edits against the pre-edit document).
h_sym_rename :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	uri := sym_req_uri(env, arena)
	b_uri := strings.concatenate({uri[:len(uri) - len("a.go")], "b.go"}, arena)
	body := strings.concatenate({
		`{"documentChanges":[`,
		`{"textDocument":{"uri":"`, uri, `"},"edits":[{"range":{"start":{"line":3,"character":5},"end":{"line":3,"character":11}},"newText":"Gadget"}]}`,
		`,{"textDocument":{"uri":"`, b_uri, `"},"edits":[{"range":{"start":{"line":3,"character":7},"end":{"line":3,"character":13}},"newText":"Gadget"}]}`,
		`]}`,
	}, arena)
	v, _ := json.parse_string(body, spec = .JSON, parse_integers = true, allocator = arena)
	return {result = v}, .Respond
}

// h_sym_rename_none answers an empty workspace edit.
h_sym_rename_none :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string("{}", spec = .JSON, parse_integers = true, allocator = arena)
	return {result = v}, .Respond
}

// h_sym_hover answers a plaintext hover for any position.
h_sym_hover :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`{"contents":{"kind":"plaintext","value":"Make hover text"}}`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// sym_hover_clock hands the budget test's hover handler the fixture's
// virtual clock so each answer can advance time past the batch deadline.
sym_hover_clock: ^platform.Clock = nil

// h_sym_hover_advance answers hover text but first advances the virtual
// clock 60 s, exhausting a smaller batch budget for later entries.
h_sym_hover_advance :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	if sym_hover_clock != nil {
		platform.clock_advance(sym_hover_clock, 60_000)
	}
	v, _ := json.parse_string(
		`{"contents":{"kind":"plaintext","value":"Budget hover text"}}`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// h_sym_implementation_two reports Make twice — the budget test needs a
// batch of two.
h_sym_implementation_two :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	return sym_locations_reply(env, arena, {
		{same_file = false, line = 2, start_col = 5, end_col = 9},
		{same_file = false, line = 2, start_col = 5, end_col = 9},
	})
}

// sym_read_disk reads a project file for post-edit assertions (the bytes
// belong to the tracking allocator: tests read, assert, and let the
// per-test cleanup own nothing — the read result is used inline only).
sym_read_disk :: proc(f: ^Sym_Lsp_Fixture, name: string) -> string {
	path, _ := filepath.join([]string{f.dir, name}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return ""
	}
	return transmute(string)data
}

@(test)
symbol_lsp_references_contract :: proc(t: ^testing.T) {
	f := sym_fixture(t)
	if f == nil {
		return
	}
	defer sym_fixture_destroy(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Default filters: the self site and the uncontained package-line site
	// drop out; the use inside Make resolves to the Make symbol.
	refs, err := svc.symbol_lsp_find_references(f.src, f.ed, "Widget", "a.go", false, false, false, nil, nil, a, nil)
	testing.expectf(t, err == nil, "references: %s", platform.err_message(err))
	if err != nil {
		return
	}
	testing.expect_value(t, len(refs), 1)
	if len(refs) != 1 {
		return
	}
	testing.expect_value(t, refs[0].sym.name, "Make")
	testing.expect_value(t, symbol.kind_name(refs[0].sym.kind), "Function")
	testing.expect_value(t, refs[0].sym.location.rel_path, "b.go")
	testing.expect_value(t, refs[0].line, 3)
	testing.expect(t, strings.contains(refs[0].content_around, "func Make()"))

	// include_self adds the symbol's own declaration site.
	self_refs, serr := svc.symbol_lsp_find_references(f.src, f.ed, "Widget", "a.go", false, true, false, nil, nil, a, nil)
	testing.expectf(t, serr == nil, "references self: %s", platform.err_message(serr))
	testing.expect_value(t, len(self_refs), 2)

	// include_file_symbols keeps the uncontained site as a File entry.
	file_refs, ferr := svc.symbol_lsp_find_references(f.src, f.ed, "Widget", "a.go", false, false, true, nil, nil, a, nil)
	testing.expectf(t, ferr == nil, "references file: %s", platform.err_message(ferr))
	testing.expect_value(t, len(file_refs), 2)
	if len(file_refs) != 2 {
		return
	}
	testing.expect_value(t, file_refs[1].sym.kind, symbol.Symbol_Kind.File)
	testing.expect_value(t, file_refs[1].sym.location.rel_path, "b.go")

	// The kind filter gates the resolved entries (12 = Function).
	filtered, xerr := svc.symbol_lsp_find_references(f.src, f.ed, "Widget", "a.go", false, false, false, nil, []u32{12}, a, nil)
	testing.expectf(t, xerr == nil, "references filtered: %s", platform.err_message(xerr))
	testing.expect_value(t, len(filtered), 0)

	// Strict resolution: a failed port propagates instead of reading as
	// "not served here".
	f.port.fail = true
	no_server, nerr := svc.symbol_lsp_find_references(f.src, f.ed, "Widget", "a.go", false, false, false, nil, nil, a, nil)
	testing.expect(t, nerr != nil)
	testing.expect_value(t, len(no_server), 0)
	f.port.fail = false

	// Unknown name paths answer NotFound.
	_, uerr := svc.symbol_lsp_find_references(f.src, f.ed, "Nosuch", "a.go", false, false, false, nil, nil, a, nil)
	testing.expect(t, uerr != nil)
	testing.expect(t, strings.contains(platform.err_message(uerr, context.temp_allocator), "no symbol matching"))
}

@(test)
symbol_lsp_implementations_and_declaration :: proc(t: ^testing.T) {
	f := sym_fixture(t)
	if f == nil {
		return
	}
	defer sym_fixture_destroy(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	entries, err := svc.symbol_lsp_find_implementations(f.src, "Widget", "a.go", true, nil, nil, a, nil)
	testing.expectf(t, err == nil, "implementations: %s", platform.err_message(err))
	if err != nil {
		return
	}
	testing.expect_value(t, len(entries), 1)
	if len(entries) != 1 {
		return
	}
	testing.expect_value(t, entries[0].sym.name, "Make")
	testing.expect_value(t, entries[0].sym.location.rel_path, "b.go")
	testing.expect_value(t, entries[0].info, "Make hover text")

	// Excluding Function (12) filters the resolved implementation out.
	filtered, ferr := svc.symbol_lsp_find_implementations(f.src, "Widget", "a.go", false, nil, []u32{12}, a, nil)
	testing.expectf(t, ferr == nil, "implementations filtered: %s", platform.err_message(ferr))
	testing.expect_value(t, len(filtered), 0)

	// The declaration answer anchors the queried symbol's name at the
	// reported location.
	decls, derr := svc.symbol_lsp_find_declaration(f.src, "Widget", "a.go", a, nil)
	testing.expectf(t, derr == nil, "declaration: %s", platform.err_message(derr))
	if derr != nil {
		return
	}
	testing.expect_value(t, len(decls), 1)
	if len(decls) != 1 {
		return
	}
	testing.expect_value(t, decls[0].name, "Widget")
	testing.expect_value(t, symbol.kind_name(decls[0].kind), "Struct")
	testing.expect_value(t, decls[0].rel_path, "a.go")
	testing.expect_value(t, decls[0].line, 3)
	testing.expect_value(t, decls[0].col, 5)
}

// The batch hover pass runs under the symbol_info_budget: once the batch
// deadline is spent, remaining entries return without info instead of
// issuing further hover round-trips. The first hover's handler advances
// the source's virtual clock past the 10 s budget, so the second of two
// implementations answers empty — deterministically, on the same clock
// the deadline check reads.
@(test)
symbol_lsp_hover_budget_bounds_batch :: proc(t: ^testing.T) {
	f := sym_fixture(t)
	if f == nil {
		return
	}
	defer sym_fixture_destroy(f)

	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_IMPLEMENTATION, h_sym_implementation_two)
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_HOVER, h_sym_hover_advance)
	sym_hover_clock = f.clock
	defer sym_hover_clock = nil
	f.src.symbol_info_budget_s = 10.0

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	entries, err := svc.symbol_lsp_find_implementations(f.src, "Widget", "a.go", true, nil, nil, a, nil)
	testing.expectf(t, err == nil, "implementations: %s", platform.err_message(err))
	if err != nil {
		return
	}
	testing.expect_value(t, len(entries), 2)
	if len(entries) != 2 {
		return
	}
	testing.expect_value(t, entries[0].sym.name, "Make")
	testing.expect_value(t, entries[0].info, "Budget hover text")
	testing.expect_value(t, entries[1].info, "")
}

// The capability gate: against a server that never declared
// declarationProvider / implementationProvider (the ols shape), the ops
// decline with a clean message naming the language and the missing
// capability instead of surfacing the server's raw method-not-found
// error; references (declared) keep answering on the same pair.
@(test)
symbol_lsp_capability_decline :: proc(t: ^testing.T) {
	f := sym_fixture(t, true)
	if f == nil {
		return
	}
	defer sym_fixture_destroy(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	_, derr := svc.symbol_lsp_find_declaration(f.src, "Widget", "a.go", a, nil)
	testing.expectf(t, derr != nil, "declaration must decline without declarationProvider")
	if derr != nil {
		msg := platform.err_message(derr, context.temp_allocator)
		testing.expect(t, strings.contains(msg, "does not support declaration lookups"))
		testing.expect(t, strings.contains(msg, "declarationProvider"))
		testing.expect(t, strings.contains(msg, "symbol_find"))
	}

	_, ierr := svc.symbol_lsp_find_implementations(f.src, "Widget", "a.go", false, nil, nil, a, nil)
	testing.expectf(t, ierr != nil, "implementation must decline without implementationProvider")
	if ierr != nil {
		msg := platform.err_message(ierr, context.temp_allocator)
		testing.expect(t, strings.contains(msg, "does not support implementation lookups"))
		testing.expect(t, strings.contains(msg, "implementationProvider"))
	}

	refs, rerr := svc.symbol_lsp_find_references(f.src, f.ed, "Widget", "a.go", false, false, false, nil, nil, a, nil)
	testing.expectf(t, rerr == nil, "references stay answered: %s", platform.err_message(rerr))
	testing.expect_value(t, len(refs), 1)
}

@(test)
symbol_lsp_rename_contract :: proc(t: ^testing.T) {
	f := sym_fixture(t)
	if f == nil {
		return
	}
	defer sym_fixture_destroy(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	summary, err := svc.symbol_lsp_rename(f.src, f.ed, "Widget", "a.go", "Gadget", a, nil)
	testing.expectf(t, err == nil, "rename: %s", platform.err_message(err))
	if err != nil {
		return
	}
	testing.expect(t, strings.contains(summary, "2 edits applied"))

	a_after := sym_read_disk(f, "a.go")
	b_after := sym_read_disk(f, "b.go")
	testing.expect(t, strings.contains(a_after, "type Gadget struct{}"), "a.go not renamed on disk")
	// The comment line legitimately keeps the old name: only the
	// definition site was renamed.
	testing.expect(t, !strings.contains(a_after, "type Widget"), "a.go keeps the old definition")
	testing.expectf(t, strings.contains(b_after, "a.Gadget{}"), "b.go not renamed on disk: %q", b_after)

	// A server answering no edits refuses instead of reporting success.
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_RENAME, h_sym_rename_none)
	_, none_err := svc.symbol_lsp_rename(f.src, f.ed, "Widget", "a.go", "Other", a, nil)
	testing.expect(t, none_err != nil)
	testing.expect(t, strings.contains(platform.err_message(none_err, context.temp_allocator), "no rename edits"))
}

@(test)
symbol_lsp_delete_contract :: proc(t: ^testing.T) {
	f := sym_fixture(t)
	if f == nil {
		return
	}
	defer sym_fixture_destroy(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Referenced symbol: refusal naming the sites, file untouched.
	refusal, err := svc.symbol_lsp_delete(f.src, f.ed, "Widget", "a.go", false, a, nil)
	testing.expectf(t, err == nil, "delete: %s", platform.err_message(err))
	if err != nil {
		return
	}
	testing.expect(t, strings.contains(refusal, "Cannot delete"))
	testing.expect(t, strings.contains(refusal, "b.go"))
	testing.expect(t, strings.contains(sym_read_disk(f, "a.go"), "type Widget struct{}"))

	// Unreferenced, plain delete: the definition goes, the comment stays.
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_REFERENCES, h_sym_references_none)
	_, err2 := svc.symbol_lsp_delete(f.src, f.ed, "Widget", "a.go", false, a, nil)
	testing.expectf(t, err2 == nil, "delete plain: %s", platform.err_message(err2))
	after_plain := sym_read_disk(f, "a.go")
	testing.expect(t, !strings.contains(after_plain, "type Widget"), "plain delete left the definition")
	testing.expect(t, strings.contains(after_plain, "// Widget is a thing."), "plain delete removed the comment")

	// Unreferenced, with comments: the block above goes too. The file is
	// rewritten on disk, so the editor's cached buffer must go first.
	lsp_write_file(f.dir, "a.go", "package a\n\n// Widget is a thing.\ntype Widget struct{}\n")
	editor.editor_drop_buffer(f.ed, "a.go")
	_, err3 := svc.symbol_lsp_delete(f.src, f.ed, "Widget", "a.go", true, a, nil)
	testing.expectf(t, err3 == nil, "delete comments: %s", platform.err_message(err3))
	after_full := sym_read_disk(f, "a.go")
	testing.expect(t, !strings.contains(after_full, "Widget"), "comment delete left remains")
	jsonrpc.conn_register(f.pair.fake.conn, lsp.METHOD_REFERENCES, h_sym_references)
}

@(test)
symbol_lsp_svc_contract :: proc(t: ^testing.T) {
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

	// Strict resolution through the daemon: a missing file answers
	// NotFound (the svc mapping of NotFound is Method_Not_Found) before
	// any language server is consulted.
	missing := svc.client_symbol_find_references(
		pair.conn, "Widget", "nosuch.go", false, false, false, nil, nil, alloc, deadline,
	)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(missing.err_message, "path not found"))

	decl := svc.client_symbol_find_declaration(pair.conn, "Widget", "nosuch.go", alloc, deadline)
	testing.expect_value(t, decl.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect(t, strings.contains(decl.err_message, "path not found"))

	// Rename/delete mutate project files: read-only sessions are refused
	// at the svc boundary.
	pair.daemon.cfg.read_only = true
	rn := svc.client_symbol_rename(pair.conn, "Widget", "a.go", "Gadget", alloc, deadline)
	testing.expect_value(t, rn.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, rn.err_code, jsonrpc.Err_Code.Invalid_Request)

	del := svc.client_symbol_delete(pair.conn, "Widget", "a.go", false, alloc, deadline)
	testing.expect_value(t, del.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, del.err_code, jsonrpc.Err_Code.Invalid_Request)
	pair.daemon.cfg.read_only = false
}

@(test)
symbol_lsp_tool_surface :: proc(t: ^testing.T) {
	// The five tools are base-visible with their caps; the mutating pair
	// strips under read-only like the other editing tools.
	all := tools.fold_visibility({.Project, .Svc, .Editor, .Shell}, false, nil, nil)
	testing.expect(t, tools.Tool_ID.Symbol_Find_References in all)
	testing.expect(t, tools.Tool_ID.Symbol_Find_Implementations in all)
	testing.expect(t, tools.Tool_ID.Symbol_Find_Declaration in all)
	testing.expect(t, tools.Tool_ID.Symbol_Rename in all)
	testing.expect(t, tools.Tool_ID.Symbol_Delete in all)

	ro := tools.fold_visibility({.Project, .Svc, .Editor}, true, nil, nil)
	testing.expect(t, tools.Tool_ID.Symbol_Find_References in ro)
	testing.expect(t, tools.Tool_ID.Symbol_Rename not_in ro)
	testing.expect(t, tools.Tool_ID.Symbol_Delete not_in ro)

	// Int_Array validation accepts integer arrays and rejects strings.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	table := tools.TOOLS
	good, gerr := tools.validate_args(
		&table[int(tools.Tool_ID.Symbol_Find_References)],
		parse_obj(`{"name_path":"W","relative_path":"a.go","include_kinds":[6,12]}`),
		alloc,
	)
	testing.expect_value(t, gerr, "")
	testing.expect_value(t, len(good), 3)

	bad, berr := tools.validate_args(
		&table[int(tools.Tool_ID.Symbol_Find_References)],
		parse_obj(`{"name_path":"W","relative_path":"a.go","include_kinds":["nope"]}`),
		alloc,
	)
	testing.expect(t, berr != "")
	testing.expect_value(t, len(bad), 0)
}

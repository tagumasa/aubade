// Tests for the LSP symbol source and the editor→LSP sync bridge: a
// fake-peer language server answers documentSymbol, and the producer's
// forest (finalize pipeline with the receiver hook) plus its
// single-transaction index write are verified against a real SQLite
// store. The bridge test observes didOpen/didChange/didClose on the fake
// wire. Both ride the Client_For_File_Proc seam — no manager, no process.
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
import "src:symbol"
import "src:svc"

// Fake_LSP_Port hands out the pair's client for every file (the language
// id and hook mirror what the registry entry would supply); fail=true
// simulates "no server for this file". releases counts the pins returned
// through the release hook (the pair owns the client itself).
Fake_LSP_Port :: struct {
	client:     ^lsp.Client,
	language_id: string,
	normalize:  symbol.Normalize_Name_Proc,
	fail:       bool,
	releases:   int,
	// how many resolutions arrived asking to START a server — the sync
	// bridge must never be among them (a spawn under the file lock).
	starts_requested: int,
}

fake_lsp_port :: proc(
	user: rawptr,
	rel_path: string,
	may_start: bool,
	arena: mem.Allocator,
	token: ^platform.Cancel_Token,
) -> (client: ^lsp.Client, language_id: string, normalize: symbol.Normalize_Name_Proc, err: platform.Err) {
	fp := cast(^Fake_LSP_Port)user
	if may_start {
		fp.starts_requested += 1
	}
	if fp.fail {
		return nil, "", nil, platform.Err(.NotFound)
	}
	return fp.client, fp.language_id, fp.normalize, nil
}

// fake_lsp_release counts returned pins — the observable side of the
// producer's hand-out discipline.
fake_lsp_release :: proc(user: rawptr, client: ^lsp.Client) {
	fp := cast(^Fake_LSP_Port)user
	fp.releases += 1
}

// h_go_document_symbols mirrors a gopls-shaped reply: one type with a
// field child, plus a receiver-qualified method at the top level.
h_go_document_symbols :: proc(conn: ^jsonrpc.Conn, env: ^jsonrpc.Envelope, arena: mem.Allocator) -> (jsonrpc.Reply, jsonrpc.Action) {
	v, _ := json.parse_string(
		`[{"name":"Client","kind":23,"range":{"start":{"line":0,"character":0},"end":{"line":9,"character":0}},"selectionRange":{"start":{"line":0,"character":6},"end":{"line":0,"character":12}},"children":[{"name":"ID","kind":8,"range":{"start":{"line":1,"character":1},"end":{"line":1,"character":5}},"selectionRange":{"start":{"line":1,"character":1},"end":{"line":1,"character":3}}}]},{"name":"(*Client).Call","kind":6,"range":{"start":{"line":3,"character":0},"end":{"line":5,"character":1}},"selectionRange":{"start":{"line":3,"character":20},"end":{"line":3,"character":24}}}]`,
		spec = .JSON, parse_integers = true, allocator = arena,
	)
	return {result = v}, .Respond
}

// lsp_split_receiver splits Go receiver-qualified method names (the shape
// the go registry entry normalizes with).
lsp_split_receiver :: proc(kind: symbol.Symbol_Kind, name: string, rel_path: string) -> (normalized: string, receiver: string) {
	if !strings.has_prefix(name, "(*") {
		return name, ""
	}
	if close := strings.index(name, ")"); close >= 0 && close + 2 < len(name) && name[close + 1] == '.' {
		return name[close + 2:], name[2:close]
	}
	return name, ""
}

lsp_write_file :: proc(root: string, name: string, content: string) {
	path, _ := filepath.join([]string{root, name}, context.temp_allocator)
	os.make_directory_all(filepath.dir(path), os.Permissions{.Read_User, .Write_User, .Execute_User})
	fp, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	if err != nil {
		return
	}
	os.write(fp, transmute([]u8)content)
	os.close(fp)
}

@(test)
lsp_source_indexes_document_symbols :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-lspsrc-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	db_dir, dderr := os.make_directory_temp("", "aubade-lspsrcdb-", context.allocator)
	testing.expectf(t, dderr == nil, "temp db dir failed")
	defer {
		_ = os.remove_all(dir)
		delete(dir)
		_ = os.remove_all(db_dir)
		delete(db_dir)
	}
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "db open failed")
	defer store.db_close(db)

	lsp_write_file(dir, "src/mod.go", "package mod\n\ntype Client struct {\n\tID int\n}\n")

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true, context.allocator)
	defer {
		platform.clock_destroy(clock)
		free(clock, context.allocator)
	}

	p := lsp_pair_init(t)
	defer lsp_pair_shutdown(p)
	jsonrpc.conn_register(p.fake.conn, lsp.METHOD_DOCUMENT_SYMBOL, h_go_document_symbols)

	port := Fake_LSP_Port{client = p.client, language_id = "go", normalize = lsp_split_receiver}
	src := new(svc.LSP_Source, context.allocator)
	svc.lsp_source_init(src, dir, db, clock, nil, fake_lsp_port, &port, nil, context.allocator)
	defer {
		svc.lsp_source_destroy(src)
		free(src, context.allocator)
	}

	roots, err := svc.lsp_source_file_symbols(src, "src/mod.go", context.allocator)
	testing.expectf(t, err == nil, "source: %s", platform.err_message(err))
	defer symbol.symbol_forest_destroy(roots, context.allocator)

	// The receiver-qualified method nested under its type; the pipeline
	// anchored locations to the file. The children count is asserted
	// before the indexing guard: a regression that drops them must fail
	// the count, not return past the checks.
	testing.expect_value(t, len(roots), 1)
	if len(roots) != 1 {
		return
	}
	testing.expectf(t, len(roots[0].children) == 2, "Client children: %d", len(roots[0].children))
	if len(roots[0].children) != 2 {
		return
	}
	testing.expect_value(t, roots[0].name, "Client")
	testing.expect_value(t, roots[0].children[1].name, "Call")
	testing.expect_value(t, roots[0].children[1].location.rel_path, "src/mod.go")

	// The producer wrote the same single-transaction rows the TS source
	// writes: name lookups answer with parent and file.
	// rows_destroy frees through context.allocator: allocate the rows
	// there, not in temp.
	rows, lerr := store.symbol_names_lookup(db, "Call", context.allocator)
	testing.expectf(t, lerr == nil, "lookup: %s", platform.err_message(lerr))
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 1)
	if len(rows) != 1 {
		return
	}
	testing.expect_value(t, rows[0].path, "src/mod.go")
	testing.expect_value(t, rows[0].parent, "Client")
	testing.expect_value(t, rows[0].kind, "Method")
	testing.expect(t, rows[0].hash != "")
}

@(test)
lsp_source_without_server :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-lspnone-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_dir, _ := os.make_directory_temp("", "aubade-lspnonedb-", context.allocator)
	defer {
		_ = os.remove_all(db_dir)
		delete(db_dir)
	}
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "db open failed")
	defer store.db_close(db)

	lsp_write_file(dir, "a.py", "def f():\n    pass\n")

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true, context.allocator)
	defer {
		platform.clock_destroy(clock)
		free(clock, context.allocator)
	}

	// Resolution failure is "not served here": empty roots, no error —
	// the caller's source order stays in charge.
	port := Fake_LSP_Port{fail = true}
	src := new(svc.LSP_Source, context.allocator)
	svc.lsp_source_init(src, dir, db, clock, nil, fake_lsp_port, &port, nil, context.allocator)
	defer {
		svc.lsp_source_destroy(src)
		free(src, context.allocator)
	}
	roots, err := svc.lsp_source_file_symbols(src, "a.py", context.allocator)
	testing.expectf(t, err == nil, "source: %s", platform.err_message(err))
	testing.expect_value(t, len(roots), 0)
}

// lsp_source_port_error_keeps_kind pins the strict core's re-wrap: a bare
// Err_Kind from the port (the production resolver's "no server" answer)
// must surface with its own kind, not flattened to Internal.
@(test)
lsp_source_port_error_keeps_kind :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-lspbare-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	if derr != nil {
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_dir, dderr := os.make_directory_temp("", "aubade-lspbaredb-", context.allocator)
	testing.expectf(t, dderr == nil, "temp db dir failed")
	if dderr != nil {
		return
	}
	defer {
		_ = os.remove_all(db_dir)
		delete(db_dir)
	}
	db_path, _ := filepath.join([]string{db_dir, "symbols.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "db open failed")
	if oerr != nil {
		return
	}
	defer store.db_close(db)

	lsp_write_file(dir, "a.py", "def f():\n    pass\n")

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true, context.allocator)
	defer {
		platform.clock_destroy(clock)
		free(clock, context.allocator)
	}

	port := Fake_LSP_Port{fail = true}
	src := new(svc.LSP_Source, context.allocator)
	svc.lsp_source_init(src, dir, db, clock, nil, fake_lsp_port, &port, nil, context.allocator)
	defer {
		svc.lsp_source_destroy(src)
		free(src, context.allocator)
	}

	roots, client, uri, lang, err := svc.lsp_document_symbols(src, "a.py", context.allocator)
	testing.expect(t, err != nil, "port failure must surface from the strict core")
	testing.expect(t, roots == nil && client == nil && uri == "" && lang == "", "failed resolution must return nothing else")
	testing.expect(t, platform.err_kind(err) == .NotFound, "bare .NotFound must survive the re-wrap, got %s", platform.kind_name(platform.err_kind(err)))
	// The strict contract owns the re-wrapped message in the caller's
	// allocator.
	#partial switch w in err {
	case platform.Wrapped:
		if w.msg != "" {
			delete(w.msg, context.allocator)
		}
	case:
	}
}

@(test)
editor_sync_forwards_document_lifecycle :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-lspsync-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	lsp_write_file(dir, "s.go", "package x\n\nfunc f() {}\n")

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "", svc.editor_file_io_port(), context.allocator)
	p := lsp_pair_init(t)

	port := Fake_LSP_Port{client = p.client, language_id = "go"}
	sync := new(svc.Editor_Sync, context.allocator)
	svc.editor_sync_init(sync, dir, fake_lsp_port, &port, context.allocator)
	svc.editor_sync_install(sync, e)

	werr, wmsg := editor.editor_insert_at_line(e, "s.go", 1, "// hi\n")
	testing.expectf(t, werr == .None, "insert: %s", wmsg)

	// didOpen carried the pre-edit contents; the durable change carried
	// the post-save text.
	fake_note_wait(p.fake, lsp.METHOD_DID_OPEN, 1)
	opened := fake_note_get(p.fake, lsp.METHOD_DID_OPEN, 0)
	testing.expect(t, strings.contains(opened, "file://"))
	testing.expect(t, strings.contains(opened, "s.go"))
	testing.expect(t, strings.contains(opened, "package x"))

	fake_note_wait(p.fake, lsp.METHOD_DID_CHANGE, 1)
	changed := fake_note_get(p.fake, lsp.METHOD_DID_CHANGE, 0)
	testing.expect(t, strings.contains(changed, "// hi"))

	// A second edit changes only — one didOpen per document.
	werr, wmsg = editor.editor_insert_at_line(e, "s.go", 0, "// top\n")
	testing.expectf(t, werr == .None, "insert 2: %s", wmsg)
	fake_note_wait(p.fake, lsp.METHOD_DID_CHANGE, 2)
	testing.expect_value(t, fake_note_count(p.fake, lsp.METHOD_DID_OPEN), 1)

	editor.editor_drop_buffer(e, "s.go")
	fake_note_wait(p.fake, lsp.METHOD_DID_CLOSE, 1)
	closed := fake_note_get(p.fake, lsp.METHOD_DID_CLOSE, 0)
	testing.expect(t, strings.contains(closed, "s.go"))

	// The listener must come off before either side goes away.
	svc.editor_sync_uninstall(sync, e)
	svc.editor_sync_destroy(sync)
	free(sync, context.allocator)
	lsp_pair_shutdown(p)
	editor.editor_destroy(e)
	free(e, context.allocator)
}

// Buffer lifecycle — open, edit, external-change adoption on read, close —
// must resolve against running servers only: a spawn (fork/exec plus the
// handshake) would run inside the notification, under the editor's file
// lock. The port counts start requests; every editor-driven path here
// must leave it at zero.
@(test)
editor_sync_never_requests_a_start :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-lspsync-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	lsp_write_file(dir, "s.go", "package x\n\nfunc f() {}\n")

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "", svc.editor_file_io_port(), context.allocator)
	p := lsp_pair_init(t)

	port := Fake_LSP_Port{client = p.client, language_id = "go"}
	sync := new(svc.Editor_Sync, context.allocator)
	svc.editor_sync_init(sync, dir, fake_lsp_port, &port, context.allocator)
	svc.editor_sync_install(sync, e)

	werr, wmsg := editor.editor_insert_at_line(e, "s.go", 1, "// hi\n")
	testing.expectf(t, werr == .None, "insert: %s", wmsg)

	// The read-side adoption path (an external write under a held buffer)
	// notifies a change — lazily, without asking for a server.
	lsp_write_file(dir, "s.go", "package x\n\nfunc f() { return 2 }\n")
	adopted, rerr, _ := editor.editor_read_file(e, "s.go")
	testing.expect(t, rerr == .None)
	delete(adopted, e.allocator)

	editor.editor_drop_buffer(e, "s.go")
	testing.expect_value(t, port.starts_requested, 0)

	svc.editor_sync_uninstall(sync, e)
	svc.editor_sync_destroy(sync)
	free(sync, context.allocator)
	lsp_pair_shutdown(p)
	editor.editor_destroy(e)
	free(e, context.allocator)
}

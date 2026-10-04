// The index-freshness contract: symbol_find must not answer from rows
// whose file has disappeared, and file_delete/file_move must purge the
// old path's rows instead of waiting out the TTL sweep. The lazy
// invalidation tests below pin the write side of the same contract: a
// buffer change writes no rows, and the first read over a file's rows
// rewrites them from the editor's current bytes. Drives the real daemon
// handlers against a minimal daemon (editor + store db + project root —
// no sockets, no tracker, no language servers). The lazy-invalidation
// tests run on the highlights face tests' shared Hlface_Fixture lazy
// fixture — the fixture family is shared across files, not redefined (one
// tests package).
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "src:daemon"
import "src:editor"
import "src:jsonutil"
import "src:platform"
import "src:store"
import "src:svc"
import "src:util"

// Freshness_Fixture is the minimal index-test daemon: editor + store db +
// project root, no sockets, no tracker, no language servers. The
// lazy-invalidation tests that attach the tree-sitter producer, the
// document-sync face, and the sync bridge run on the shared Hlface_Fixture
// lazy fixture (highlights_face_test.odin), so the lazy fields below stay
// nil here; the type remains field-identical to Hlface_Fixture.
Freshness_Fixture :: struct {
	d:      ^daemon.Daemon,
	root:   string,
	clock:  ^platform.Clock,
	token:  platform.Cancel_Token,
	src:    ^svc.TS_Source,
	ds:     ^svc.Doc_Sync,
	bridge: ^svc.Editor_Sync,
	worker: ^thread.Thread,
}

freshness_fixture :: proc(t: ^testing.T) -> ^Freshness_Fixture {
	root, rerr := os.make_directory_temp("", "aubade-fresh-", context.allocator)
	if rerr != nil {
		testing.fail_now(t, "temp root failed")
	}
	f := new(Freshness_Fixture, context.allocator)
	f.root = root

	state, _ := filepath.join([]string{root, ".aubade"}, context.allocator)
	if merr := os.make_directory_all(state, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil {
		testing.fail_now(t, "state dir failed")
	}
	db_path, _ := filepath.join([]string{state, "aubade.db"}, context.allocator)
	delete(state, context.allocator)

	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	delete(db_path, context.allocator)

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true) // virtual: nothing here waits

	d := new(daemon.Daemon, context.allocator)
	d^ = {}
	d.cfg = daemon.default_config(root, root, clock)
	d.db = db
	ed := new(editor.Editor, context.allocator)
	editor.editor_init(ed, root, .Lf, "utf-8", svc.editor_file_io_port(), context.allocator)
	d.ed = ed

	platform.token_init_root(&f.token)
	f.d = d
	f.clock = clock
	return f
}

// freshness_teardown frees the fixture's daemon pieces in the reverse of
// their build order.
freshness_teardown :: proc(f: ^Freshness_Fixture) {
	editor.editor_destroy(f.d.ed)
	free(f.d.ed, context.allocator)
	store.db_close(f.d.db)
	platform.clock_destroy(f.clock)
	free(f.clock, context.allocator)
	_ = os.remove_all(f.root)
	delete(f.root, context.allocator)
	free(f.d, context.allocator)
	free(f, context.allocator)
}

freshness_ctx :: proc(f: ^Freshness_Fixture, a: mem.Allocator) -> svc.Svc_Ctx {
	return {allocator = a, token = &f.token, user = f.d}
}

freshness_params :: proc(body: string, a: mem.Allocator) -> json.Value {
	value, perr := json.parse_bytes(transmute([]u8)body, spec = .JSON, parse_integers = true, allocator = a)
	if perr != nil {
		return nil
	}
	return value
}

freshness_seed :: proc(t: ^testing.T, f: ^Freshness_Fixture, path, name: string) {
	names := [1]store.Symbol_Name_Row{{name = name, kind = "Struct", line = 1, parent = ""}}
	payload := [2]u8{1, 2}
	err := store.write_symbol_index(f.d.db, path, "h1", "go", names[:], payload[:], 1000)
	testing.expectf(t, err == nil, "seed %s: %v", path, err)
}

freshness_write_file :: proc(t: ^testing.T, f: ^Freshness_Fixture, rel, content: string) {
	abs, _ := filepath.join([]string{f.root, rel}, context.temp_allocator)
	// Report, do not fail_now: the caller's fixture teardown is
	// defer-protected, and fail_now fires past that defer stack while the
	// daemon pair is still alive.
	if werr := os.write_entire_file_from_bytes(abs, transmute([]u8)content); werr != nil {
		testing.expectf(t, false, "fixture file write failed: %s", rel)
	}
}

// freshness_rows_of looks one name up in the L0 index; the rows are
// cloned into context.allocator and the caller frees them with
// store.symbol_names_rows_destroy.
freshness_rows_of :: proc(t: ^testing.T, db: ^store.DB, name: string) -> []store.Symbol_Name_Row_With_File {
	rows, lerr := store.symbol_names_lookup(db, name, context.allocator)
	testing.expectf(t, lerr == nil, "lookup %s failed: %v", name, lerr)
	if lerr != nil {
		return nil
	}
	return rows
}

// freshness_rows_count_at asserts the index answers exactly `want` rows
// for `name` in `rel` (rel "" skips the path check) and frees the rows.
freshness_rows_count_at :: proc(t: ^testing.T, db: ^store.DB, name, rel: string, want: int) {
	rows := freshness_rows_of(t, db, name)
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expectf(t, len(rows) == want, "lookup %s: got %d rows, want %d", name, len(rows), want)
	if rel == "" {
		return
	}
	for r in rows {
		testing.expectf(t, r.path == rel, "lookup %s: row path %s, want %s", name, r.path, rel)
	}
}

@(test)
symbol_find_drops_and_purges_ghost_rows :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// live.go exists on disk; gone.go never does. Both carry the name.
	freshness_write_file(t, f, "live.go", "body")
	freshness_seed(t, f, "live.go", "Ghost")
	freshness_seed(t, f, "gone.go", "Ghost")

	ctx := freshness_ctx(f, a)
	result, err := daemon.handle_symbol_find(&ctx, freshness_params(`{"name": "ghost"}`, a))
	testing.expectf(t, err == nil, "find: %v", err)
	if err != nil {
		return
	}
	matches, ok := jsonutil.obj_get(result, "matches")
	testing.expect_value(t, ok, true)
	if !ok {
		return
	}
	testing.expect_value(t, json_array_len(matches), 1)
	if json_array_len(matches) == 1 {
		path, _ := json_str_field(json_array_at(matches, 0), "path")
		testing.expect_value(t, path, "live.go")
	}

	// The purge landed: the store itself no longer serves gone.go.
	rows, lerr := store.symbol_names_lookup(f.d.db, "Ghost", context.allocator)
	testing.expectf(t, lerr == nil, "relookup: %v", lerr)
	if lerr != nil {
		return
	}
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].path, "live.go")
	}

	// L1 payloads went with the L0 rows: the gone path has no cache row.
	got, _, found, gerr := store.symbol_cache_get(f.d.db, "gone.go", "h1", 2000, context.allocator)
	testing.expectf(t, gerr == nil, "cache get: %v", gerr)
	testing.expect_value(t, found, false)
	if got != nil {
		delete(got)
	}
}

@(test)
file_delete_and_move_purge_index_rows :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	freshness_write_file(t, f, "src.txt", "body")
	freshness_seed(t, f, "src.txt", "Purgee")

	ctx := freshness_ctx(f, a)

	_, derr := daemon.handle_file_delete(&ctx, freshness_params(`{"relative_path": "src.txt"}`, a))
	testing.expectf(t, derr == nil, "delete: %v", derr)
	if derr != nil {
		return
	}
	rows, lerr := store.symbol_names_lookup(f.d.db, "Purgee", context.allocator)
	testing.expectf(t, lerr == nil, "lookup after delete: %v", lerr)
	if lerr != nil {
		return
	}
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 0)

	// The move flavor purges the source path the same way.
	freshness_write_file(t, f, "mv.txt", "body")
	freshness_seed(t, f, "mv.txt", "Movee")
	_, merr := daemon.handle_file_move(
		&ctx,
		freshness_params(`{"source_relative_path": "mv.txt", "target_relative_path": "sub/renamed.txt"}`, a),
	)
	testing.expectf(t, merr == nil, "move: %v", merr)
	if merr != nil {
		return
	}
	mrows, mlerr := store.symbol_names_lookup(f.d.db, "Movee", context.allocator)
	testing.expectf(t, mlerr == nil, "lookup after move: %v", mlerr)
	if mlerr != nil {
		return
	}
	defer store.symbol_names_rows_destroy(mrows, context.allocator)
	testing.expect_value(t, len(mrows), 0)
}

// ---------------------------------------------------------------------------
// Lazy L0 invalidation: the change path writes no rows; the reader pays
// ---------------------------------------------------------------------------

// freshness_crawl_all fills the lazy fixture's index from its disk files.
// The crawl is also the only writer that records the disk fingerprints the
// read side's incremental skip compares against, so the lazy tests crawl
// before opening a document: their heal must run against a live
// fingerprint that the skip would otherwise trust.
freshness_crawl_all :: proc(t: ^testing.T, f: ^Hlface_Fixture) {
	stats: svc.Crawl_Stats
	cerr := svc.ts_source_crawl(f.src, "", &stats, {}, nil)
	testing.expectf(t, cerr == nil, "crawl failed: %v", cerr)
}

// The lazy contract over the document-sync face: a storm of applied
// changes writes no L0 rows (the index keeps describing the disk text,
// and idle time — however much — moves nothing), the first find over the
// file's rows rewrites them exactly once from the buffer's current text,
// and a read after the document closes reverts the rows to the disk.
@(test)
symbol_find_lazy_storm_defers_rows_until_a_reader :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	disk_text := "package main\n\nfunc lazy_disk_symbol() {}\n"
	hlface_write_file(t, f, "lazy.go", disk_text)
	freshness_crawl_all(t, f)
	freshness_rows_count_at(t, f.d.db, "lazy_disk_symbol", "lazy.go", 1)

	// Open with client text that replaces the disk symbol, then storm
	// changes. Every change applies to the buffer; none may write rows.
	texts := [4]string{
		"package main\n\nfunc lazy_open_marker() {}\n",
		"package main\n\nfunc lazy_storm_two() {}\n",
		"package main\n\nfunc lazy_storm_three() {}\n",
		"package main\n\nfunc lazy_storm_final() {}\n",
	}
	deadline := platform.mono_ms() + 10_000
	outcome, oerr := svc.doc_sync_open(f.ds, "lazy.go", "go", 1, texts[0], nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}
	testing.expect(t, !outcome.superseded, "a plain open must apply")
	for text, i in texts {
		if i == 0 {
			continue
		}
		ch_outcome, cherr := svc.doc_sync_change(f.ds, "lazy.go", i32(i + 1), text, nil, deadline, a)
		testing.expectf(t, cherr == nil, "change v%d failed: %v", i + 1, cherr)
		if cherr != nil {
			return
		}
		testing.expectf(t, !ch_outcome.superseded && ch_outcome.version == i32(i + 1), "change v%d must apply", i + 1)
	}

	// The storm settled with zero row writes: the index still describes
	// the disk text, and no applied text's symbol is indexed.
	freshness_rows_count_at(t, f.d.db, "lazy_disk_symbol", "lazy.go", 1)
	freshness_rows_count_at(t, f.d.db, "lazy_open_marker", "", 0)
	freshness_rows_count_at(t, f.d.db, "lazy_storm_two", "", 0)
	freshness_rows_count_at(t, f.d.db, "lazy_storm_final", "", 0)
	disk := two_writer_read_disk(t, f.root, "lazy.go")
	testing.expect(t, strings.contains(disk, "func lazy_disk_symbol"), "the storm must not reach the disk")
	delete(disk, context.allocator)

	// The reader pays — the find over the file's existing rows rewrites
	// them once from the buffer's current text: the searched-for name
	// honestly vanishes, the storm's final symbol becomes indexed, and
	// the row hash is the buffer text's hash. (The run happens while the
	// crawl fingerprint is live, so the empty re-seed's on-miss walk
	// skips the unchanged-on-disk file instead of re-indexing the disk
	// bytes over the buffer truth.)
	ctx := hlface_ctx(f, a)
	result, err := daemon.handle_symbol_find(&ctx, hlface_params(`{"name": "lazy_disk_symbol"}`, a))
	testing.expectf(t, err == nil, "find old name: %v", err)
	if err != nil {
		return
	}
	matches, ok := jsonutil.obj_get(result, "matches")
	testing.expect_value(t, ok, true)
	if ok {
		testing.expect_value(t, json_array_len(matches), 0)
	}
	freshness_rows_count_at(t, f.d.db, "lazy_disk_symbol", "", 0)

	client_hash := editor.content_hash_hex(texts[3], context.temp_allocator)
	final_rows := freshness_rows_of(t, f.d.db, "lazy_storm_final")
	testing.expect_value(t, len(final_rows), 1)
	if len(final_rows) == 1 {
		testing.expect_value(t, final_rows[0].path, "lazy.go")
		testing.expect_value(t, final_rows[0].hash, client_hash)
	}
	store.symbol_names_rows_destroy(final_rows, context.allocator)

	// The rewrite's L1 payload is stamped with this find's clock reading.
	// The probe clones the row's language string too — free it with the
	// payload (the second return is owned, not borrowed).
	got, lang, found, gerr := store.symbol_cache_get(f.d.db, "lazy.go", client_hash, platform.clock_now(f.clock), context.allocator)
	testing.expectf(t, gerr == nil, "payload probe: %v", gerr)
	testing.expect_value(t, found, true)
	if got != nil {
		delete(got)
	}
	if lang != "" {
		delete(lang, context.allocator)
	}

	// Idle time moves nothing and the next read writes nothing further:
	// advancing well past the payload TTL leaves the L0 rows answering,
	// while the payload probe shows nothing re-stamped them — the first
	// find was the only write.
	platform.clock_advance(f.clock, 2 * store.DEFAULT_TTL_MS)
	freshness_rows_count_at(t, f.d.db, "lazy_storm_final", "lazy.go", 1)
	result, err = daemon.handle_symbol_find(&ctx, hlface_params(`{"name": "lazy_storm_final"}`, a))
	testing.expectf(t, err == nil, "second find: %v", err)
	if err != nil {
		return
	}
	matches, ok = jsonutil.obj_get(result, "matches")
	testing.expect_value(t, ok, true)
	if ok {
		testing.expect_value(t, json_array_len(matches), 1)
	}
	got, lang, found, gerr = store.symbol_cache_get(f.d.db, "lazy.go", client_hash, platform.clock_now(f.clock), context.allocator)
	testing.expectf(t, gerr == nil, "payload probe: %v", gerr)
	testing.expect_value(t, found, false)
	if got != nil {
		delete(got)
	}
	if lang != "" {
		delete(lang, context.allocator)
	}

	// Closing the document returns the truth to the disk; the next read
	// over the rows reverts them (the buffer is gone, so the heal reads
	// the disk bytes).
	cerr := svc.doc_sync_close(f.ds, "lazy.go", a)
	testing.expectf(t, cerr == nil, "close failed: %v", cerr)
	if cerr != nil {
		return
	}
	result, err = daemon.handle_symbol_find(&ctx, hlface_params(`{"name": "lazy_storm_final"}`, a))
	testing.expectf(t, err == nil, "post-close find: %v", err)
	if err != nil {
		return
	}
	matches, ok = jsonutil.obj_get(result, "matches")
	testing.expect_value(t, ok, true)
	if ok {
		testing.expect_value(t, json_array_len(matches), 0)
	}
	freshness_rows_count_at(t, f.d.db, "lazy_disk_symbol", "lazy.go", 1)
	freshness_rows_count_at(t, f.d.db, "lazy_storm_final", "", 0)
}

// The heal gate an open document needs: the file's disk fingerprint is
// live and matching (the skip's condition holds — asserted directly), yet
// a find over the file's rows still rewrites them from the unsaved buffer
// text. Without the doc-sync presence gate the fingerprint skip would
// suppress this heal and the stale rows would keep answering.
@(test)
symbol_find_heals_open_document_over_live_fingerprint :: proc(t: ^testing.T) {
	f := hlface_lazy_fixture(t)
	defer hlface_lazy_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	disk_text := "package main\n\nfunc gate_disk_symbol() {}\n"
	hlface_write_file(t, f, "gate.go", disk_text)
	freshness_crawl_all(t, f)
	freshness_rows_count_at(t, f.d.db, "gate_disk_symbol", "gate.go", 1)

	client_text := "package main\n\nfunc gate_client_symbol() {}\n"
	deadline := platform.mono_ms() + 10_000
	_, oerr := svc.doc_sync_open(f.ds, "gate.go", "go", 1, client_text, nil, deadline, a)
	testing.expectf(t, oerr == nil, "open failed: %v", oerr)
	if oerr != nil {
		return
	}

	// The skip's own condition holds: the disk stat still matches the
	// crawl's record and the rows are live. This is the state that hid
	// unsaved buffer drift before the gate.
	abs, _ := filepath.join([]string{f.root, "gate.go"}, context.temp_allocator)
	_, size, mtime_ns, sok := util.stat_kind_size_mtime(abs)
	testing.expect(t, sok, "gate.go must exist on disk")
	if sok {
		skip := store.fingerprint_skip(f.d.db, "gate.go", mtime_ns, size, platform.clock_now(f.clock))
		testing.expect(t, skip, "the disk fingerprint must still skip — the gate, not the stat, moves the rows")
	}

	// The reader heals through the open document anyway.
	ctx := hlface_ctx(f, a)
	result, err := daemon.handle_symbol_find(&ctx, hlface_params(`{"name": "gate_disk_symbol"}`, a))
	testing.expectf(t, err == nil, "find: %v", err)
	if err != nil {
		return
	}
	matches, ok := jsonutil.obj_get(result, "matches")
	testing.expect_value(t, ok, true)
	if ok {
		testing.expect_value(t, json_array_len(matches), 0)
	}
	client_rows := freshness_rows_of(t, f.d.db, "gate_client_symbol")
	testing.expect_value(t, len(client_rows), 1)
	if len(client_rows) == 1 {
		testing.expect_value(t, client_rows[0].path, "gate.go")
		testing.expect_value(t, client_rows[0].hash, editor.content_hash_hex(client_text, context.temp_allocator))
	}
	store.symbol_names_rows_destroy(client_rows, context.allocator)
	freshness_rows_count_at(t, f.d.db, "gate_disk_symbol", "", 0)

	disk := two_writer_read_disk(t, f.root, "gate.go")
	testing.expect(t, strings.contains(disk, "func gate_disk_symbol"), "the heal must not reach the disk")
	delete(disk, context.allocator)
}

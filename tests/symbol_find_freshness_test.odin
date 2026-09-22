// The index-freshness contract: symbol_find must not answer from rows
// whose file has disappeared, and file_delete/file_move must purge the
// old path's rows instead of waiting out the TTL sweep. Drives the real
// daemon handlers against a minimal daemon (editor + store db + project
// root — no sockets, no tracker, no language servers).
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "src:daemon"
import "src:editor"
import "src:jsonutil"
import "src:platform"
import "src:store"
import "src:svc"

Freshness_Fixture :: struct {
	d:     ^daemon.Daemon,
	root:  string,
	clock: ^platform.Clock,
	token: platform.Cancel_Token,
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

freshness_write_file :: proc(t: ^testing.T, f: ^Freshness_Fixture, rel: string) {
	abs, _ := filepath.join([]string{f.root, rel}, context.temp_allocator)
	data := "body"
	// Report, do not fail_now: the caller's fixture teardown is
	// defer-protected, and fail_now fires past that defer stack while the
	// daemon pair is still alive.
	if werr := os.write_entire_file_from_bytes(abs, transmute([]u8)data); werr != nil {
		testing.expectf(t, false, "fixture file write failed: %s", rel)
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
	freshness_write_file(t, f, "live.go")
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

	freshness_write_file(t, f, "src.txt")
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
	freshness_write_file(t, f, "mv.txt")
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

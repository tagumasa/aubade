// Contract tests for the symbol/index svc face over the channel transport:
// a real in-process daemon serves svc.symbol/list, svc.symbol/find, and
// svc.index/crawl against a real SQLite index; the child side drives them
// through the typed client proxies.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "src:jsonrpc"
import "src:jsonutil"
import "src:platform"
import "src:svc"

// A setup write failure fails the test loudly (a swallowed failure reads
// downstream as missing files, not as a broken fixture) — through
// expectf plus an early return, never fail_now: callers run this with a
// live daemon pair, and fail_now fires past the pair's teardown defers.
svc_symbol_write_file :: proc(t: ^testing.T, root: string, name: string, content: string) {
	path, _ := filepath.join([]string{root, name}, context.temp_allocator)
	if parent, _ := filepath.split(path); parent != "" {
		if merr := os.mkdir_all(parent, {.Read_User, .Write_User, .Execute_User}); merr != nil && merr != .Exist {
			testing.expectf(t, false, "fixture mkdir failed for %s: %s", name, os.error_string(merr))
			return
		}
	}
	fp, err := os.open(path, {.Write, .Create, .Trunc}, {
		.Read_User, .Write_User, .Read_Group, .Read_Other,
	})
	if err != nil {
		testing.expectf(t, false, "fixture write failed for %s: %s", name, os.error_string(err))
		return
	}
	if _, werr := os.write(fp, transmute([]u8)content); werr != nil {
		os.close(fp)
		testing.expectf(t, false, "fixture write failed for %s: %s", name, os.error_string(werr))
		return
	}
	if cerr := os.close(fp); cerr != nil {
		testing.expectf(t, false, "fixture close failed for %s: %s", name, os.error_string(cerr))
		return
	}
}

json_array_len :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Array:
		return len(x)
	case:
		return -1
	}
}

json_array_at :: proc(v: json.Value, i: int) -> json.Value {
	#partial switch x in v {
	case json.Array:
		if i >= 0 && i < len(x) {
			return x[i]
		}
	case:
	}
	return nil
}

json_str_field :: proc(v: json.Value, key: string) -> (string, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.String:
			return string(x), true
		case:
		}
	}
	return "", false
}

json_int_field :: proc(v: json.Value, key: string) -> (i64, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Integer:
			return i64(x), true
		case:
		}
	}
	return 0, false
}

@(test)
svc_symbol_list_find_crawl :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "alpha.go", "package main\n\nfunc Alpha() int { return 1 }\n")
	svc_symbol_write_file(t, pair.tmp, "sub/beta.go", "package sub\n\nfunc Beta() {}\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	hello_params := jsonutil.json_object(1, alloc)
	jsonutil.obj_set(&hello_params, "client_pid", jsonutil.json_int(4242))
	_, _, _, hcerr := jsonrpc.conn_call(pair.conn, svc.METHOD_HELLO, json.Value(json.Object(hello_params)), alloc, deadline)
	testing.expect_value(t, hcerr, jsonrpc.Call_Err.None)

	// symbol/list: one file, finalized shape (kind, location).
	list := svc.client_symbol_list(pair.conn, "alpha.go", alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.None)
	syms, ok := jsonutil.obj_get(list.result, "symbols")
	testing.expect(t, ok)
	testing.expect_value(t, json_array_len(syms), 1)
	node := json_array_at(syms, 0)
	name, nok := json_str_field(node, "name")
	kind, kok := json_str_field(node, "kind_name")
	testing.expect(t, nok && kok)
	testing.expect_value(t, name, "Alpha")
	testing.expect_value(t, kind, "Function")
	if loc, lok := jsonutil.obj_get(node, "location"); lok {
		rel, rok := json_str_field(loc, "rel_path")
		testing.expect(t, rok)
		testing.expect_value(t, rel, "alpha.go")
	} else {
		testing.expectf(t, false, "location missing")
	}

	// symbol/list also fills the index, so find sees the file without any
	// crawl — case-insensitively.
	find := svc.client_symbol_find(pair.conn, "alpha", alloc, deadline)
	testing.expect_value(t, find.call_err, jsonrpc.Call_Err.None)
	matches, mok := jsonutil.obj_get(find.result, "matches")
	testing.expect(t, mok)
	testing.expect_value(t, json_array_len(matches), 1)
	if json_array_len(matches) == 1 {
		line, lok := json_int_field(json_array_at(matches, 0), "line")
		testing.expect(t, lok)
		testing.expect_value(t, line, 2)
	}

	// Unknown names are an empty result, not an error.
	find_none := svc.client_symbol_find(pair.conn, "NoSuchSymbol", alloc, deadline)
	testing.expect_value(t, find_none.call_err, jsonrpc.Call_Err.None)
	if none_matches, nm_ok := jsonutil.obj_get(find_none.result, "matches"); nm_ok {
		testing.expect_value(t, json_array_len(none_matches), 0)
	}

	// index/crawl over the whole project: the on-miss walk behind the
	// previous find already indexed BOTH files and recorded their
	// fingerprints, so the crawl's incremental skip reports them unchanged
	// instead of re-parsing — both are in the index either way (the Beta
	// find below is the behavioral proof).
	crawl := svc.client_index_crawl(pair.conn, "", alloc, deadline)
	testing.expect_value(t, crawl.call_err, jsonrpc.Call_Err.None)
	stats, sok := jsonutil.obj_get(crawl.result, "stats")
	testing.expect(t, sok)
	indexed, iok := json_int_field(stats, "files_indexed")
	unchanged, uok := json_int_field(stats, "files_unchanged")
	testing.expect(t, iok && uok)
	testing.expect_value(t, indexed, 0)
	testing.expect_value(t, unchanged, 2)

	find_beta := svc.client_symbol_find(pair.conn, "Beta", alloc, deadline)
	testing.expect_value(t, find_beta.call_err, jsonrpc.Call_Err.None)
	beta_matches, bok := jsonutil.obj_get(find_beta.result, "matches")
	testing.expect(t, bok)
	testing.expect_value(t, json_array_len(beta_matches), 1)
	if json_array_len(beta_matches) == 1 {
		path, pok := json_str_field(json_array_at(beta_matches, 0), "path")
		testing.expect(t, pok)
		testing.expect_value(t, path, "sub/beta.go")
	}
}

// An edit through the editor rewrites the file's L0 rows in the same
// transaction (the change listener's post-edit refresh): a renamed symbol
// is findable under its new name immediately, and the old name stops
// answering.
@(test)
svc_symbol_find_refreshes_after_edit :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "alpha.go", "package main\n\nfunc Alpha() int { return 1 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Fill the index for the file (symbol/list parses and writes rows).
	list := svc.client_symbol_list(pair.conn, "alpha.go", alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.None)

	// Rename the symbol through the editor path — the post-edit refresh
	// must land without any other op touching the file.
	repl := svc.client_file_replace(pair.conn, "alpha.go", "func Alpha()", "func Zeta()", "literal", false, alloc, deadline)
	testing.expect_value(t, repl.call_err, jsonrpc.Call_Err.None)

	find_old := svc.client_symbol_find(pair.conn, "Alpha", alloc, deadline)
	testing.expect_value(t, find_old.call_err, jsonrpc.Call_Err.None)
	if old_matches, ook := jsonutil.obj_get(find_old.result, "matches"); ook {
		testing.expect_value(t, json_array_len(old_matches), 0)
	} else {
		testing.expectf(t, false, "old-name find: matches missing")
	}

	find_new := svc.client_symbol_find(pair.conn, "Zeta", alloc, deadline)
	testing.expect_value(t, find_new.call_err, jsonrpc.Call_Err.None)
	new_matches, nok := jsonutil.obj_get(find_new.result, "matches")
	testing.expect(t, nok)
	testing.expect_value(t, json_array_len(new_matches), 1)
	if json_array_len(new_matches) == 1 {
		line, lok := json_int_field(json_array_at(new_matches, 0), "line")
		testing.expect(t, lok)
		testing.expect_value(t, line, 2)
	}
}

// An out-of-band disk edit (no editor buffer, no notification) leaves the
// rows stale; symbol_find's content-freshness heal re-indexes the
// mismatched path before answering: the reported line tracks the file's
// current bytes, and a renamed-away name stops answering. A name that
// exists only in the new bytes stays undiscoverable from this side — no
// row for it triggers the hash check — the write-side refresh (aubade
// edits) and the crawl fill those.
@(test)
svc_symbol_find_heals_disk_edit :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "ren.go", "package main\n\nfunc Keeper() int { return 1 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	list := svc.client_symbol_list(pair.conn, "ren.go", alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.None)

	// Shift the symbol down three lines, behind every writer.
	svc_symbol_write_file(t, pair.tmp, "ren.go", "package main\n\n// note\n// note\n\nfunc Keeper() int { return 1 }\n")

	find := svc.client_symbol_find(pair.conn, "Keeper", alloc, deadline)
	testing.expect_value(t, find.call_err, jsonrpc.Call_Err.None)
	matches, mok := jsonutil.obj_get(find.result, "matches")
	testing.expect(t, mok)
	testing.expect_value(t, json_array_len(matches), 1)
	if json_array_len(matches) == 1 {
		line, lok := json_int_field(json_array_at(matches, 0), "line")
		testing.expect(t, lok)
		testing.expect_value(t, line, 5)
	}

	// Rename the symbol away on disk: the stale rows must not keep
	// answering for the old name.
	svc_symbol_write_file(t, pair.tmp, "ren.go", "package main\n\n// note\n// note\n\nfunc Other() int { return 1 }\n")
	find_old := svc.client_symbol_find(pair.conn, "Keeper", alloc, deadline)
	testing.expect_value(t, find_old.call_err, jsonrpc.Call_Err.None)
	if old_matches, ook := jsonutil.obj_get(find_old.result, "matches"); ook {
		testing.expect_value(t, json_array_len(old_matches), 0)
	} else {
		testing.expectf(t, false, "old-name find after heal: matches missing")
	}
}

// A failed edit (needle absent) never fires the change notification: the
// rows stay as they were and the file is untouched.
@(test)
svc_symbol_find_failed_edit_leaves_index :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "stay.go", "package main\n\nfunc Stay() int { return 1 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	list := svc.client_symbol_list(pair.conn, "stay.go", alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.None)

	repl := svc.client_file_replace(pair.conn, "stay.go", "func Absent()", "func Other()", "literal", false, alloc, deadline)
	testing.expect_value(t, repl.call_err, jsonrpc.Call_Err.Error_Response)

	find := svc.client_symbol_find(pair.conn, "Stay", alloc, deadline)
	testing.expect_value(t, find.call_err, jsonrpc.Call_Err.None)
	matches, mok := jsonutil.obj_get(find.result, "matches")
	testing.expect(t, mok)
	testing.expect_value(t, json_array_len(matches), 1)
	if json_array_len(matches) == 1 {
		line, lok := json_int_field(json_array_at(matches, 0), "line")
		testing.expect(t, lok)
		testing.expect_value(t, line, 2)
	}
}

@(test)
svc_symbol_invalid_params :: proc(t: ^testing.T) {
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

	// Missing paths, escapes, and empty names are Invalid_Params error
	// responses on the wire.
	list := svc.client_symbol_list(pair.conn, "", alloc, deadline)
	testing.expect_value(t, list.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, list.err_code, jsonrpc.Err_Code.Invalid_Params)

	list_escape := svc.client_symbol_list(pair.conn, "../../etc/passwd", alloc, deadline)
	testing.expect_value(t, list_escape.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, list_escape.err_code, jsonrpc.Err_Code.Invalid_Params)

	find := svc.client_symbol_find(pair.conn, "", alloc, deadline)
	testing.expect_value(t, find.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, find.err_code, jsonrpc.Err_Code.Invalid_Params)

	// Files the tree-sitter source does not serve are empty, not errors.
	svc_symbol_write_file(t, pair.tmp, "notes.md", "# notes\n")
	notes := svc.client_symbol_list(pair.conn, "notes.md", alloc, deadline)
	testing.expect_value(t, notes.call_err, jsonrpc.Call_Err.None)
	if syms, sok := jsonutil.obj_get(notes.result, "symbols"); sok {
		testing.expect_value(t, json_array_len(syms), 0)
	}
}

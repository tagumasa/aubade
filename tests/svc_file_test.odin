// Contract tests for the file svc face over the channel transport: a real
// in-process daemon serves svc.file/* against a real project directory;
// the child side drives them through the typed client proxies.
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
import "src:platform"
import "src:svc"

json_bool_field :: proc(v: json.Value, key: string) -> (bool, bool) {
	if f, ok := jsonutil.obj_get(v, key); ok {
		#partial switch x in f {
		case json.Boolean:
			return bool(x), true
		case:
		}
	}
	return false, false
}

file_read_content :: proc(
	t: ^testing.T,
	conn: ^jsonrpc.Conn,
	rel: string,
	start_line: int,
	end_line: int,
	end_set: bool,
	allocator: mem.Allocator,
	deadline: i64,
) -> string {
	call := svc.client_file_read(conn, rel, start_line, end_line, end_set, 0, allocator, deadline)
	if call.call_err != jsonrpc.Call_Err.None {
		testing.expectf(t, false, "file read failed: %s", call.err_message)
		return ""
	}
	content, ok := json_str_field(call.result, "content")
	if !ok {
		testing.expectf(t, false, "content missing")
		return ""
	}
	return content
}

svc_file_find_count :: proc(
	conn: ^jsonrpc.Conn,
	mask: string,
	allocator: mem.Allocator,
	deadline: i64,
) -> int {
	call := svc.client_file_find(conn, mask, "", allocator, deadline)
	if call.call_err != .None {
		return -1
	}
	if files, ok := jsonutil.obj_get(call.result, "files"); ok {
		return json_array_len(files)
	}
	return -1
}

@(test)
svc_file_write_read_roundtrip :: proc(t: ^testing.T) {
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
	conn := pair.conn

	// Write creates missing parent directories and reports creation.
	w := svc.client_file_write(conn, "docs/guide.md", "# Guide\nline two\n", alloc, deadline)
	testing.expect_value(t, w.call_err, jsonrpc.Call_Err.None)
	if overwrote, ok := json_bool_field(w.result, "overwrote"); ok {
		testing.expect(t, !overwrote)
	} else {
		testing.expectf(t, false, "overwrote missing")
	}

	// Full read returns the written content.
	r := svc.client_file_read(conn, "docs/guide.md", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, r.call_err, jsonrpc.Call_Err.None)
	content, _ := json_str_field(r.result, "content")
	testing.expect_value(t, content, "# Guide\nline two\n")
	ask, _ := json_bool_field(r.result, "read_ask")
	testing.expect(t, !ask)

	// Inclusive line slice [1..1].
	sliced := file_read_content(t, conn, "docs/guide.md", 1, 1, true, alloc, deadline)
	testing.expect_value(t, sliced, "line two")

	// start_line beyond the end is an empty result, not an error.
	empty := file_read_content(t, conn, "docs/guide.md", 10, 0, false, alloc, deadline)
	testing.expect_value(t, empty, "")

	// max_answer_chars gate: content withheld, truncated set.
	gated := svc.client_file_read(conn, "docs/guide.md", 0, 0, false, 5, alloc, deadline)
	testing.expect_value(t, gated.call_err, jsonrpc.Call_Err.None)
	truncated, _ := json_bool_field(gated.result, "truncated")
	testing.expect(t, truncated)
	gated_content, _ := json_str_field(gated.result, "content")
	testing.expect_value(t, gated_content, "")

	// Credential-like names trip the read-ask heuristic.
	svc_symbol_write_file(t, pair.tmp, "creds.env", "SECRET=1\n")
	env_call := svc.client_file_read(conn, "creds.env", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, env_call.call_err, jsonrpc.Call_Err.None)
	env_content, _ := json_str_field(env_call.result, "content")
	testing.expect_value(t, env_content, "SECRET=1\n")
	env_ask, _ := json_bool_field(env_call.result, "read_ask")
	testing.expect(t, env_ask)

	// Second write overwrites and reports it.
	w2 := svc.client_file_write(conn, "docs/guide.md", "replaced\n", alloc, deadline)
	testing.expect_value(t, w2.call_err, jsonrpc.Call_Err.None)
	if overwrote2, ok := json_bool_field(w2.result, "overwrote"); ok {
		testing.expect(t, overwrote2)
	}
	after := file_read_content(t, conn, "docs/guide.md", 0, 0, false, alloc, deadline)
	testing.expect_value(t, after, "replaced\n")
}

// svc_read_raw returns a file's raw disk bytes as a caller-owned string
// (context.allocator): the caller deletes it.
svc_read_raw :: proc(root: string, name: string) -> string {
	path, _ := filepath.join([]string{root, name}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return ""
	}
	defer delete(data)
	return strings.clone(string(data), context.allocator)
}

// strip_cr normalises CRLF to LF for cross-platform content comparison.
// The test's purpose is BOM preservation, not line-ending verification.
strip_cr :: proc(s: string, a := context.allocator) -> string {
	out, _ := strings.replace_all(s, "\r\n", "\n", a)
	return out
}

@(test)
svc_file_write_preserves_bom :: proc(t: ^testing.T) {
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
	conn := pair.conn

	// A whole-file rewrite of a BOM-carried target keeps the marker: the
	// editor read face strips it, so an agent's read-modify-write cycle
	// hands BOM-less text to file_write — dropping the marker here would
	// silently re-sign the file.
	svc_symbol_write_file(t, pair.tmp, "bom.md", "\xEF\xBB\xBF# Title\nbody\n")
	w := svc.client_file_write(conn, "bom.md", "# Title\nbody two\n", alloc, deadline)
	testing.expect_value(t, w.call_err, jsonrpc.Call_Err.None)
	if overwrote, ok := json_bool_field(w.result, "overwrote"); ok {
		testing.expect(t, overwrote)
	} else {
		testing.expectf(t, false, "overwrote missing")
	}
	disk := svc_read_raw(pair.tmp, "bom.md")
	defer delete(disk, context.allocator)
	// Strip \r for comparison — the test verifies BOM preservation, not line endings.
	disk_norm := strip_cr(disk, context.temp_allocator)
	defer delete(disk_norm, context.temp_allocator)
	testing.expect_value(t, disk_norm, "\xEF\xBB\xBF# Title\nbody two\n")

	// The read face strips the marker for consumers...
	read := file_read_content(t, conn, "bom.md", 0, 0, false, alloc, deadline)
	testing.expect_value(t, read, "# Title\nbody two\n")

	// ...a brand-new file gains nothing, and content that carries its own
	// BOM is written verbatim — never doubled.
	w2 := svc.client_file_write(conn, "fresh.md", "clean\n", alloc, deadline)
	testing.expect_value(t, w2.call_err, jsonrpc.Call_Err.None)
	fresh := svc_read_raw(pair.tmp, "fresh.md")
	defer delete(fresh, context.allocator)
	fresh_norm := strip_cr(fresh, context.temp_allocator)
	defer delete(fresh_norm, context.temp_allocator)
	testing.expect_value(t, fresh_norm, "clean\n")
	w3 := svc.client_file_write(conn, "bom.md", "\xEF\xBB\xBFverbatim\n", alloc, deadline)
	testing.expect_value(t, w3.call_err, jsonrpc.Call_Err.None)
	verbatim := svc_read_raw(pair.tmp, "bom.md")
	defer delete(verbatim, context.allocator)
	verbatim_norm := strip_cr(verbatim, context.temp_allocator)
	defer delete(verbatim_norm, context.temp_allocator)
	testing.expect_value(t, verbatim_norm, "\xEF\xBB\xBFverbatim\n")
}

@(test)
svc_file_read_rejects_escape_and_missing :: proc(t: ^testing.T) {
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

	escape := svc.client_file_read(pair.conn, "../../etc/passwd", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, escape.call_err, jsonrpc.Call_Err.Error_Response)
	// Containment refusals carry the Denied kind (Invalid_Request on the
	// wire) — the typed editor boundary maps Outside_Root there.
	testing.expect_value(t, escape.err_code, jsonrpc.Err_Code.Invalid_Request)

	missing := svc.client_file_read(pair.conn, "no_such_file.txt", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
}

@(test)
svc_file_edit_ops :: proc(t: ^testing.T) {
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
	conn := pair.conn

	svc_symbol_write_file(t, pair.tmp, "edit.txt", "alpha\nbeta\ngamma\n")

	// insert at line 1 (content gains the missing trailing newline).
	ins := svc.client_file_insert_lines(conn, "edit.txt", 1, "INSERTED", alloc, deadline)
	testing.expect_value(t, ins.call_err, jsonrpc.Call_Err.None)
	testing.expect_value(
		t,
		file_read_content(t, conn, "edit.txt", 0, 0, false, alloc, deadline),
		"alpha\nINSERTED\nbeta\ngamma\n",
	)

	// replace lines 0..1 with one line.
	rl := svc.client_file_replace_lines(conn, "edit.txt", 0, 1, "ONE", alloc, deadline)
	testing.expect_value(t, rl.call_err, jsonrpc.Call_Err.None)
	testing.expect_value(
		t,
		file_read_content(t, conn, "edit.txt", 0, 0, false, alloc, deadline),
		"ONE\nbeta\ngamma\n",
	)

	// delete line 1.
	dl := svc.client_file_delete_lines(conn, "edit.txt", 1, 1, alloc, deadline)
	testing.expect_value(t, dl.call_err, jsonrpc.Call_Err.None)
	testing.expect_value(
		t,
		file_read_content(t, conn, "edit.txt", 0, 0, false, alloc, deadline),
		"ONE\ngamma\n",
	)

	// inverted ranges are rejected before the buffer is touched.
	bad := svc.client_file_delete_lines(conn, "edit.txt", 3, 1, alloc, deadline)
	testing.expect_value(t, bad.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad.err_code, jsonrpc.Err_Code.Invalid_Params)

	// literal replace: two occurrences without the flag is an error.
	svc_symbol_write_file(t, pair.tmp, "rep.txt", "foo bar foo\n")
	two := svc.client_file_replace(conn, "rep.txt", "foo", "baz", "literal", false, alloc, deadline)
	testing.expect_value(t, two.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, two.err_code, jsonrpc.Err_Code.Invalid_Params)
	all := svc.client_file_replace(conn, "rep.txt", "foo", "baz", "literal", true, alloc, deadline)
	testing.expect_value(t, all.call_err, jsonrpc.Call_Err.None)
	testing.expect_value(
		t,
		file_read_content(t, conn, "rep.txt", 0, 0, false, alloc, deadline),
		"baz bar baz\n",
	)

	// regex replace with a $!N backreference.
	svc_symbol_write_file(t, pair.tmp, "num.txt", "v1.2.3\n")
	re_repl := svc.client_file_replace(conn, "num.txt", `(\d+)\.(\d+)`, "$!2.$!1", "regex", false, alloc, deadline)
	testing.expect_value(t, re_repl.call_err, jsonrpc.Call_Err.None)
	testing.expect_value(
		t,
		file_read_content(t, conn, "num.txt", 0, 0, false, alloc, deadline),
		"v2.1.3\n",
	)

	// a missing needle is a NotFound error, not a mutation.
	none := svc.client_file_replace(conn, "num.txt", "zzz", "x", "literal", false, alloc, deadline)
	testing.expect_value(t, none.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, none.err_code, jsonrpc.Err_Code.Method_Not_Found)
}

@(test)
svc_file_list_dir :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\nfunc A() {}\n")
	svc_symbol_write_file(t, pair.tmp, "src/b.go", "package src\n")
	svc_symbol_write_file(t, pair.tmp, "src/deep/c.go", "package deep\n")
	svc_symbol_write_file(t, pair.tmp, "bin.dat", "AB\x00CD")
	svc_symbol_write_file(t, pair.tmp, "skip.me", "ignored\n")
	svc_symbol_write_file(t, pair.tmp, ".gitignore", "skip.me\ndaemon/\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Non-recursive, ignores off: root children only. The builtin
	// exclusions always drop .aubade; the daemon home is a separate temp
	// tree (the shadow repository must sit outside the workspace), so
	// only the seeded src/ shows up.
	plain := svc.client_file_list_dir(pair.conn, "", false, false, false, alloc, deadline)
	testing.expect_value(t, plain.call_err, jsonrpc.Call_Err.None)
	if dirs, ok := jsonutil.obj_get(plain.result, "dirs"); ok {
		testing.expect_value(t, json_array_len(dirs), 1) // src only
		found_src := false
		for i in 0..<json_array_len(dirs) {
			#partial switch x in json_array_at(dirs, i) {
			case json.String:
				if string(x) == "src" {
					found_src = true
				}
			case:
			}
		}
		testing.expect(t, found_src)
	} else {
		testing.expectf(t, false, "dirs missing")
	}
	if files, ok := jsonutil.obj_get(plain.result, "files"); ok {
		testing.expect_value(t, json_array_len(files), 4) // .gitignore, a.go, bin.dat, skip.me
		#partial switch x in json_array_at(files, 0) {
		case json.String:
			testing.expect_value(t, string(x), ".gitignore")
		case:
			testing.expectf(t, false, "file entry not a string")
		}
	} else {
		testing.expectf(t, false, "files missing")
	}

	// Recursive with ignore scoping and line counts: skip.me is ignored,
	// binary files report "binary", text files report line counts.
	full := svc.client_file_list_dir(pair.conn, "", true, true, true, alloc, deadline)
	testing.expect_value(t, full.call_err, jsonrpc.Call_Err.None)
	dirs2, _ := jsonutil.obj_get(full.result, "dirs")
	testing.expect_value(t, json_array_len(dirs2), 2) // src, src/deep
	files2, _ := jsonutil.obj_get(full.result, "files")
	testing.expect_value(t, json_array_len(files2), 5) // .gitignore, a.go, bin.dat, src/b.go, src/deep/c.go
	if json_array_len(files2) == 5 {
		bin_entry := json_array_at(files2, 2)
		bin_name, bnok := json_str_field(bin_entry, "name")
		bin_lines, blok := json_str_field(bin_entry, "lines")
		testing.expect(t, bnok && blok)
		testing.expect_value(t, bin_name, "bin.dat")
		testing.expect_value(t, bin_lines, "binary")
		a_entry := json_array_at(files2, 1)
		a_name, aok := json_str_field(a_entry, "name")
		a_lines, alok := json_int_field(a_entry, "lines")
		testing.expect(t, aok && alok)
		testing.expect_value(t, a_name, "a.go")
		testing.expect_value(t, a_lines, 3)
	}

	// A missing directory is NotFound; a file path is Invalid.
	missing := svc.client_file_list_dir(pair.conn, "nope", false, false, false, alloc, deadline)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
	file_scope := svc.client_file_list_dir(pair.conn, "a.go", false, false, false, alloc, deadline)
	testing.expect_value(t, file_scope.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, file_scope.err_code, jsonrpc.Err_Code.Invalid_Params)
}

@(test)
svc_file_find_masks :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "main.go", "x\n")
	svc_symbol_write_file(t, pair.tmp, "src/util.go", "x\n")
	svc_symbol_write_file(t, pair.tmp, "lib/util.rs", "x\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Bare masks match base names; matching is case-insensitive.
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.go", alloc, deadline), 2)
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.GO", alloc, deadline), 2)
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.rs", alloc, deadline), 1)
	// Masks with '/' match the whole relative path.
	testing.expect_value(t, svc_file_find_count(pair.conn, "src/*.go", alloc, deadline), 1)
	testing.expect_value(t, svc_file_find_count(pair.conn, "src/**", alloc, deadline), 1)
	testing.expect_value(t, svc_file_find_count(pair.conn, "**/*.go", alloc, deadline), 2)

	// A directory scope narrows the walk.
	scoped := svc.client_file_find(pair.conn, "*.go", "src", alloc, deadline)
	testing.expect_value(t, scoped.call_err, jsonrpc.Call_Err.None)
	if files, ok := jsonutil.obj_get(scoped.result, "files"); ok {
		testing.expect_value(t, json_array_len(files), 1)
		if json_array_len(files) == 1 {
			#partial switch x in json_array_at(files, 0) {
			case json.String:
				testing.expect_value(t, string(x), "src/util.go")
			case:
				testing.expectf(t, false, "find entry not a string")
			}
		}
	}
}

@(test)
svc_file_search_pattern :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "one.txt", "aaa\nMATCH here\nbbb\n")
	svc_symbol_write_file(t, pair.tmp, "two.txt", "nothing relevant\n")
	svc_symbol_write_file(t, pair.tmp, "sub/three.txt", "xxx\nMATCH deep\nMATCH again\nyyy\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	// A fresh deadline per call: one shared budget would let the setup
	// writes eat it under load and every later call time out at the same
	// already-passed instant.
	search_deadline :: proc() -> i64 {
		return platform.mono_ms() + 10_000
	}

	req: svc.File_Search_Req
	req.pattern = "MATCH"
	req.context_before = 1
	req.context_after = 1

	call := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	matches, _ := jsonutil.obj_get(call.result, "matches")
	testing.expect_value(t, json_array_len(matches), 3)
	if json_array_len(matches) == 3 {
		first := json_array_at(matches, 0)
		path, pok := json_str_field(first, "path")
		line, _ := json_int_field(first, "line")
		display, dok := json_str_field(first, "display")
		testing.expect(t, pok && dok)
		testing.expect_value(t, path, "one.txt")
		testing.expect_value(t, line, 1)
		// Context block: "...NNNN:" marks context lines, "  >NNNN:" the
		// match itself (width-4 right-aligned line numbers).
		testing.expect_value(
			t,
			display,
			"...   0:aaa\n  >   1:MATCH here\n...   2:bbb",
		)
	}

	// include glob restricts to root-level txt files (full-path match).
	req.include_glob = "*.txt"
	incl := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, incl.call_err, jsonrpc.Call_Err.None)
	incl_matches, _ := jsonutil.obj_get(incl.result, "matches")
	testing.expect_value(t, json_array_len(incl_matches), 1)

	// exclude glob drops sub/.
	req.include_glob = ""
	req.exclude_glob = "sub/**"
	excl := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, excl.call_err, jsonrpc.Call_Err.None)
	excl_matches, _ := jsonutil.obj_get(excl.result, "matches")
	testing.expect_value(t, json_array_len(excl_matches), 1)

	// single-file scope searches just that file.
	req.exclude_glob = ""
	req.scope_rel = "one.txt"
	scoped := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, scoped.call_err, jsonrpc.Call_Err.None)
	scoped_matches, _ := jsonutil.obj_get(scoped.result, "matches")
	testing.expect_value(t, json_array_len(scoped_matches), 1)

	// ^ anchors at the subject start unless multiline is set.
	req.scope_rel = ""
	req.context_before = 0
	req.context_after = 0
	req.pattern = "^MATCH"
	anchored := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, anchored.call_err, jsonrpc.Call_Err.None)
	anchored_matches, _ := jsonutil.obj_get(anchored.result, "matches")
	testing.expect_value(t, json_array_len(anchored_matches), 0)
	req.multiline = true
	multi := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, multi.call_err, jsonrpc.Call_Err.None)
	multi_matches, _ := jsonutil.obj_get(multi.result, "matches")
	testing.expect_value(t, json_array_len(multi_matches), 3)
}

@(test)
svc_file_search_pages :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// Write order deliberately disagrees with the (path, line) page order:
	// pages must not inherit directory-enumeration order.
	svc_symbol_write_file(t, pair.tmp, "b.txt", "MATCH b\n")
	svc_symbol_write_file(t, pair.tmp, "a.txt", "MATCH a1\nMATCH a2\n")
	svc_symbol_write_file(t, pair.tmp, "sub/c.txt", "MATCH c\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	search_deadline :: proc() -> i64 {
		return platform.mono_ms() + 10_000
	}

	req: svc.File_Search_Req
	req.pattern = "MATCH"

	// The plain call answers in (path, line) order with the whole-
	// population total alongside.
	call := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	matches, _ := jsonutil.obj_get(call.result, "matches")
	testing.expect_value(t, json_array_len(matches), 4)
	total, tok := json_int_field(call.result, "total_matches")
	testing.expect(t, tok)
	testing.expect_value(t, total, 4)
	if json_array_len(matches) == 4 {
		first, _ := json_str_field(json_array_at(matches, 0), "path")
		second, _ := json_str_field(json_array_at(matches, 1), "path")
		third, _ := json_str_field(json_array_at(matches, 2), "path")
		testing.expect_value(t, first, "a.txt")
		testing.expect_value(t, second, "a.txt")
		testing.expect_value(t, third, "b.txt")
	}

	// limit caps the page; the total stays whole-population.
	req.limit = 2
	lim := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, lim.call_err, jsonrpc.Call_Err.None)
	lim_matches, _ := jsonutil.obj_get(lim.result, "matches")
	testing.expect_value(t, json_array_len(lim_matches), 2)
	lim_total, _ := json_int_field(lim.result, "total_matches")
	testing.expect_value(t, lim_total, 4)
	if json_array_len(lim_matches) == 2 {
		path, _ := json_str_field(json_array_at(lim_matches, 0), "path")
		testing.expect_value(t, path, "a.txt")
	}

	// offset resumes past the sorted front.
	req.offset = 2
	req.limit = 0
	res := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, res.call_err, jsonrpc.Call_Err.None)
	res_matches, _ := jsonutil.obj_get(res.result, "matches")
	testing.expect_value(t, json_array_len(res_matches), 2)
	if json_array_len(res_matches) == 2 {
		path, _ := json_str_field(json_array_at(res_matches, 0), "path")
		testing.expect_value(t, path, "b.txt")
	}

	// offset past the end answers empty with the total unchanged.
	req.offset = 10
	past := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, past.call_err, jsonrpc.Call_Err.None)
	past_matches, _ := jsonutil.obj_get(past.result, "matches")
	testing.expect_value(t, json_array_len(past_matches), 0)
	past_total, _ := json_int_field(past.result, "total_matches")
	testing.expect_value(t, past_total, 4)

	// A negative offset is refused at the wire, not silently clamped.
	bad := jsonutil.json_object(2, alloc)
	jsonutil.obj_set(&bad, "substring_pattern", jsonutil.json_string("MATCH"))
	jsonutil.obj_set(&bad, "offset", jsonutil.json_int(-1))
	_, _, _, berr := jsonrpc.conn_call(pair.conn, svc.METHOD_FILE_SEARCH, json.Value(json.Object(bad)), alloc, search_deadline())
	testing.expect_value(t, berr, jsonrpc.Call_Err.Error_Response)
}

// The configured ignore keys reach the walks through the real wire: the
// project's ignored_paths extend the global list (both prune the search
// and find walks and the symbol crawl), and the project's gitignore gate
// turns .gitignore scoping off for the file tools.
@(test)
svc_file_ignore_config_consumed :: proc(t: ^testing.T) {
	pair := test_daemon_with_configs(
		t,
		false,
		`{"ignored_paths": ["localgen/"], "ignore_all_files_in_gitignore": false}`,
		`{"ignored_paths": ["globalgen"]}`,
	)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "keep.txt", "MATCH stays\n")
	svc_symbol_write_file(t, pair.tmp, "globalgen/one.txt", "MATCH global\n")
	svc_symbol_write_file(t, pair.tmp, "localgen/two.txt", "MATCH local\n")
	svc_symbol_write_file(t, pair.tmp, "gitignored.txt", "MATCH gate off\n")
	svc_symbol_write_file(t, pair.tmp, ".gitignore", "gitignored.txt\n")
	svc_symbol_write_file(t, pair.tmp, "visible.go", "package a\n\nfunc Visible() {}\n")
	svc_symbol_write_file(t, pair.tmp, "globalgen/hidden.go", "package a\n\nfunc Hidden() {}\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	search_deadline :: proc() -> i64 {
		return platform.mono_ms() + 10_000
	}

	// Search sees the clean files only: both configured patterns pruned
	// their subtrees, and the disabled gitignore gate lets gitignored.txt
	// back into the walk.
	req: svc.File_Search_Req
	req.pattern = "MATCH"
	call := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	matches, _ := jsonutil.obj_get(call.result, "matches")
	testing.expect_value(t, json_array_len(matches), 2)
	if json_array_len(matches) == 2 {
		first, _ := json_str_field(json_array_at(matches, 0), "path")
		second, _ := json_str_field(json_array_at(matches, 1), "path")
		testing.expect_value(t, first, "gitignored.txt")
		testing.expect_value(t, second, "keep.txt")
	}

	// Find prunes the configured subtrees the same way.
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.txt", alloc, search_deadline()), 2)

	// The crawl skips globalgen/ (dirs_pruned counts the two configured
	// subtrees; with the gitignore gate off, no stack prunes add to it)
	// and indexes the one served file outside them. The startup warm-up
	// may already have committed that file's fingerprint, so the served
	// count is indexed+unchanged (whichever walk won the race).
	crawl := svc.client_index_crawl(pair.conn, "", alloc, platform.mono_ms() + 30_000)
	testing.expect_value(t, crawl.call_err, jsonrpc.Call_Err.None)
	if stats, ok := jsonutil.obj_get(crawl.result, "stats"); ok {
		indexed, _ := json_int_field(stats, "files_indexed")
		unchanged, _ := json_int_field(stats, "files_unchanged")
		pruned, _ := json_int_field(stats, "dirs_pruned")
		testing.expect_value(t, indexed + unchanged, 1)
		testing.expect_value(t, pruned, 2)
	} else {
		testing.expectf(t, false, "crawl stats missing")
	}
}

// The sensitive-path deny gate: deny-glob targets (.env, *.pem) are
// refused by file_read, skipped by the search/find walks, and never
// indexed by the crawl — the credential files of a project are not agent
// surface. The read-ask banner keeps covering the non-glob
// credential-like names (creds.env above).
@(test)
svc_file_deny_gate_blocks_sensitive_paths :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, ".env", "MATCH denied env\n")
	svc_symbol_write_file(t, pair.tmp, "server.pem", "MATCH denied pem\n")
	svc_symbol_write_file(t, pair.tmp, "keep.txt", "MATCH stays\n")
	svc_symbol_write_file(t, pair.tmp, "visible.go", "package a\n\nfunc Visible() {}\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	search_deadline :: proc() -> i64 {
		return platform.mono_ms() + 10_000
	}

	// file_read refuses the deny-glob target before opening it (Denied
	// kind = Invalid_Request on the wire, same as containment refusals).
	env_read := svc.client_file_read(pair.conn, ".env", 0, 0, false, 0, alloc, search_deadline())
	testing.expect_value(t, env_read.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, env_read.err_code, jsonrpc.Err_Code.Invalid_Request)
	pem_read := svc.client_file_read(pair.conn, "server.pem", 0, 0, false, 0, alloc, search_deadline())
	testing.expect_value(t, pem_read.call_err, jsonrpc.Call_Err.Error_Response)

	// The single-file scope of file_search faces the same gate: a scoped
	// search cannot read the denied file's content either.
	req_env: svc.File_Search_Req
	req_env.pattern = "MATCH"
	req_env.scope_rel = ".env"
	scoped := svc.client_file_search(pair.conn, req_env, alloc, search_deadline())
	testing.expect_value(t, scoped.call_err, jsonrpc.Call_Err.Error_Response)

	// Content search cannot reach into the denied files.
	req: svc.File_Search_Req
	req.pattern = "MATCH"
	call := svc.client_file_search(pair.conn, req, alloc, search_deadline())
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	matches, _ := jsonutil.obj_get(call.result, "matches")
	testing.expect_value(t, json_array_len(matches), 1)
	if json_array_len(matches) == 1 {
		first, _ := json_str_field(json_array_at(matches, 0), "path")
		testing.expect_value(t, first, "keep.txt")
	}

	// Name enumeration skips them too.
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.pem", alloc, search_deadline()), 0)
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.txt", alloc, search_deadline()), 1)

	// The crawl counts the denied pem as ignored and indexes only the
	// clean source file (.env never reaches the deny check — its name is
	// in the built-in ignored set, which prunes before any other rule).
	// indexed+unchanged covers the startup warm-up having already
	// committed the file's fingerprint.
	crawl := svc.client_index_crawl(pair.conn, "", alloc, platform.mono_ms() + 30_000)
	testing.expect_value(t, crawl.call_err, jsonrpc.Call_Err.None)
	if stats, ok := jsonutil.obj_get(crawl.result, "stats"); ok {
		indexed, _ := json_int_field(stats, "files_indexed")
		unchanged, _ := json_int_field(stats, "files_unchanged")
		ignored, _ := json_int_field(stats, "files_ignored")
		testing.expect_value(t, indexed + unchanged, 1)
		testing.expect_value(t, ignored, 1)
	} else {
		testing.expectf(t, false, "crawl stats missing")
	}

	// A scoped crawl on the denied pem is refused before parsing: the
	// single-file branch judges the scope itself, like the walk.
	scoped_crawl := svc.client_index_crawl(pair.conn, "server.pem", alloc, platform.mono_ms() + 30_000)
	testing.expect_value(t, scoped_crawl.call_err, jsonrpc.Call_Err.Error_Response)
}

// Default polarity: with no ignore config, the walk's .gitignore scoping
// applies to the file tools as before.
@(test)
svc_file_gitignore_default_still_applies :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "keep.txt", "MATCH stays\n")
	svc_symbol_write_file(t, pair.tmp, "gitignored.txt", "MATCH skipped\n")
	svc_symbol_write_file(t, pair.tmp, ".gitignore", "gitignored.txt\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	req: svc.File_Search_Req
	req.pattern = "MATCH"
	call := svc.client_file_search(pair.conn, req, alloc, platform.mono_ms() + 10_000)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	matches, _ := jsonutil.obj_get(call.result, "matches")
	testing.expect_value(t, json_array_len(matches), 1)
	testing.expect_value(t, svc_file_find_count(pair.conn, "*.txt", alloc, platform.mono_ms() + 10_000), 1)
}

@(test)
svc_file_delete_move :: proc(t: ^testing.T) {
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
	conn := pair.conn

	svc_symbol_write_file(t, pair.tmp, "gone.txt", "bye\n")

	// An edit opens (and saves) a buffer; delete must drop it so the
	// following read does not serve stale buffer contents.
	edit := svc.client_file_replace(conn, "gone.txt", "bye", "adios", "literal", false, alloc, deadline)
	testing.expect_value(t, edit.call_err, jsonrpc.Call_Err.None)
	del := svc.client_file_delete(conn, "gone.txt", alloc, deadline)
	testing.expect_value(t, del.call_err, jsonrpc.Call_Err.None)
	read_dead := svc.client_file_read(conn, "gone.txt", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, read_dead.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, read_dead.err_code, jsonrpc.Err_Code.Method_Not_Found)

	// Move relocates a file (creating target parents) and drops the
	// source buffer.
	svc_symbol_write_file(t, pair.tmp, "movable.txt", "data\n")
	mv := svc.client_file_move(conn, "movable.txt", "moved/renamed.txt", alloc, deadline)
	testing.expect_value(t, mv.call_err, jsonrpc.Call_Err.None)
	read_old := svc.client_file_read(conn, "movable.txt", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, read_old.call_err, jsonrpc.Call_Err.Error_Response)
	read_new := svc.client_file_read(conn, "moved/renamed.txt", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, read_new.call_err, jsonrpc.Call_Err.None)
	moved, _ := json_str_field(read_new.result, "content")
	testing.expect_value(t, moved, "data\n")

	// Existing targets are rejected without touching the source.
	svc_symbol_write_file(t, pair.tmp, "other.txt", "other\n")
	bad_move := svc.client_file_move(conn, "moved/renamed.txt", "other.txt", alloc, deadline)
	testing.expect_value(t, bad_move.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad_move.err_code, jsonrpc.Err_Code.Invalid_Params)
	still := file_read_content(t, conn, "moved/renamed.txt", 0, 0, false, alloc, deadline)
	testing.expect_value(t, still, "data\n")

	// A move onto itself is rejected before locking: the target exists
	// (it is the source), and locking one handle's mutex twice would
	// self-deadlock now that the move holds both per-file locks.
	self_move := svc.client_file_move(conn, "other.txt", "other.txt", alloc, deadline)
	testing.expect_value(t, self_move.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, self_move.err_code, jsonrpc.Err_Code.Invalid_Params)
}

@(test)
svc_file_rejects_bad_targets :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "plain.txt", "x\n")
	svc_symbol_write_file(t, pair.tmp, "adir/keep.txt", "k\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Writing onto a directory fails.
	dir_target := svc.client_file_write(pair.conn, "adir", "nope\n", alloc, deadline)
	testing.expect_value(t, dir_target.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, dir_target.err_code, jsonrpc.Err_Code.Invalid_Params)

	// Deleting a missing file is NotFound; a directory is Invalid.
	missing := svc.client_file_delete(pair.conn, "nope.txt", alloc, deadline)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
	dir_del := svc.client_file_delete(pair.conn, "adir", alloc, deadline)
	testing.expect_value(t, dir_del.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, dir_del.err_code, jsonrpc.Err_Code.Invalid_Params)

	// Moving a missing source is NotFound.
	bad_src := svc.client_file_move(pair.conn, "nope.txt", "x.txt", alloc, deadline)
	testing.expect_value(t, bad_src.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bad_src.err_code, jsonrpc.Err_Code.Method_Not_Found)

	// Escaping paths are rejected across the mutating ops, too.
	escape := svc.client_file_write(pair.conn, "../outside.txt", "x\n", alloc, deadline)
	testing.expect_value(t, escape.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, escape.err_code, jsonrpc.Err_Code.Invalid_Params)
}

@(test)
read_only_daemon_refuses_mutating_file_methods :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)
	pair.daemon.cfg.read_only = true

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	deadline := platform.mono_ms() + 10_000

	// Mutating methods are refused at the daemon boundary.
	w := svc.client_file_write(pair.conn, "docs/ro.md", "nope\n", alloc, deadline)
	testing.expect_value(t, w.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, w.err_code, jsonrpc.Err_Code.Invalid_Request)

	// Reads still serve the read-only project.
	svc_symbol_write_file(t, pair.tmp, "ro.md", "seed\n")
	r := svc.client_file_read(pair.conn, "ro.md", 0, 0, false, 0, alloc, deadline)
	testing.expect_value(t, r.call_err, jsonrpc.Call_Err.None)
	content, _ := json_str_field(r.result, "content")
	testing.expect_value(t, content, "seed\n")
}

@(test)
svc_path_ignored_predicate :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-pi-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	gi_path, _ := filepath.join({tmp, ".gitignore"}, context.temp_allocator)
	gi, gierr := os.open(gi_path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if gierr != nil {
		testing.fail_now(t, "gitignore open failed")
	}
	ignore_rules := "gen/\n*.log\n"
	os.write(gi, transmute([]u8)ignore_rules)
	os.close(gi)

	// A default-ignored directory that exists on disk (the final
	// component is then judged with directory semantics).
	nm_path, _ := filepath.join({tmp, "node_modules"}, context.temp_allocator)
	os.make_directory(nm_path, {.Read_User, .Write_User, .Execute_User})

	// The walk's own predicate, asked read-only: gitignore scoping
	// (patterns and whole directories; a root-scope glob without a slash
	// matches its own level, the matcher's established semantics), the
	// default-ignored set, and the clean pass-through.
	testing.expect_value(t, svc.path_ignored(tmp, "gen/tool.go", {}), true)
	testing.expect_value(t, svc.path_ignored(tmp, "debug.log", {}), true)
	testing.expect_value(t, svc.path_ignored(tmp, "src/main.go", {}), false)
	testing.expect_value(t, svc.path_ignored(tmp, "README.md", {}), false)
	// Default-ignored directory names prune at any depth, both as a
	// component and as the final component.
	testing.expect_value(t, svc.path_ignored(tmp, "node_modules/pkg/x.js", {}), true)
	testing.expect_value(t, svc.path_ignored(tmp, "node_modules", {}), true)
	// The gitignore directory itself, judged with directory semantics.
	testing.expect_value(t, svc.path_ignored(tmp, "gen", {}), true)
	// The configured ignore paths are a hard skip on top of the walk's
	// own policy: a global config (home = tmp) carrying one extra path.
	cfg_path, _ := filepath.join({tmp, "config.jsonc"}, context.temp_allocator)
	cfg, cfgerr := os.open(cfg_path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if cfgerr != nil {
		testing.fail_now(t, "config open failed")
	}
	ignore_json := "{\"ignored_paths\": [\"skipme/\"]}"
	os.write(cfg, transmute([]u8)ignore_json)
	os.close(cfg)

	pa: mem.Dynamic_Arena
	mem.dynamic_arena_init(&pa, context.allocator)
	defer mem.dynamic_arena_destroy(&pa)
	extra := svc.ignore_config_load(tmp, tmp, mem.dynamic_arena_allocator(&pa))
	defer svc.spec_release_c_side(extra.extra)
	testing.expect_value(t, svc.path_ignored(tmp, "skipme/x.go", extra), true)
	testing.expect_value(t, svc.path_ignored(tmp, "skipme", extra), true)
	testing.expect_value(t, svc.path_ignored(tmp, "src/main.go", extra), false)
}

// set_aubade_home isolates AUBADE_HOME for tests that exercise the
// env-resolving paths (the managed-dir resolver inside the svc write gate
// and the langserver scans). The caller restores with
// restore_aubade_home; tests run serialized, so the window is the test's
// own body.
set_aubade_home :: proc(home: string) -> (old: string, had: bool) {
	old, had = os.lookup_env_alloc("AUBADE_HOME", context.allocator)
	os.set_env("AUBADE_HOME", home)
	return old, had
}

restore_aubade_home :: proc(old: string, had: bool) {
	if had {
		os.set_env("AUBADE_HOME", old)
	} else {
		os.unset_env("AUBADE_HOME")
	}
	delete(old, context.allocator)
}

// write_global_template places a global config carrying a relocated
// managed folder template into `home` — the documented, tested scenario
// the location-based state exclusions must hold for.
write_global_template :: proc(home, template: string) {
	cfg_path, _ := filepath.join({home, "config.jsonc"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(
		cfg_path,
		strings.concatenate(
			{"{\"project_aubade_folder_location\": \"", template, "\"}\n"},
			context.temp_allocator,
		),
		os.Permissions{.Read_User, .Write_User},
	)
}

@(test)
svc_managed_state_dir_excluded_by_location :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-msd-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(root)
		delete(root, context.allocator)
	}
	home, herr := os.make_directory_temp("", "aubade-msd-home-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home, context.allocator)
	}
	write_global_template(home, "$projectDir/.state")

	// A relocated state tree a daemon would own, beside real sources.
	dirs_to_make := []string{".state", ".state/memories", "src"}
	for d in dirs_to_make {
		p, _ := filepath.join({root, d}, context.temp_allocator)
		_ = os.make_directory_all(p, os.Permissions{.Read_User, .Write_User, .Execute_User})
	}
	files_to_write := []string{
		".state/aubade.db", ".state/cache.db", ".state/memories/note.md", "src/main.go", "README.md",
	}
	for f in files_to_write {
		p, _ := filepath.join({root, f}, context.temp_allocator)
		_ = os.write_entire_file_from_string(p, "content\n", os.Permissions{.Read_User, .Write_User})
	}

	pa: mem.Dynamic_Arena
	mem.dynamic_arena_init(&pa, context.allocator)
	defer mem.dynamic_arena_destroy(&pa)
	arena := mem.dynamic_arena_allocator(&pa)
	ignore := svc.ignore_config_load(root, home, arena)
	defer svc.spec_release_c_side(ignore.extra)

	// The policy predicate: the state tree is skipped at every depth;
	// project files are not.
	testing.expect_value(t, svc.path_ignored(root, ".state", ignore), true)
	testing.expect_value(t, svc.path_ignored(root, ".state/aubade.db", ignore), true)
	testing.expect_value(t, svc.path_ignored(root, ".state/memories/note.md", ignore), true)
	testing.expect_value(t, svc.path_ignored(root, "src/main.go", ignore), false)
	testing.expect_value(t, svc.path_ignored(root, "README.md", ignore), false)

	// The walk itself: a recursive root listing never enters the state
	// tree, and a listing scoped INTO it comes back empty — the state is
	// invisible to the project surface, not merely hidden from the root.
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, root, .Lf, "", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}
	res, lerr := svc.file_list_dir(e, "", true, true, false, ignore, nil, arena, nil)
	testing.expect(t, lerr == nil)
	for d in res.dirs {
		testing.expectf(t, !strings.has_prefix(d, ".state"), "state dir listed: %s", d)
	}
	for f in res.files {
		testing.expectf(t, !strings.has_prefix(f.name, ".state"), "state file listed: %s", f.name)
	}

	scoped, serr := svc.file_list_dir(e, ".state", true, true, false, ignore, nil, arena, nil)
	testing.expect(t, serr == nil)
	testing.expect_value(t, len(scoped.dirs), 0)
	testing.expect_value(t, len(scoped.files), 0)
}

@(test)
svc_managed_state_dir_write_refused :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-msw-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(root)
		delete(root, context.allocator)
	}
	home, herr := os.make_directory_temp("", "aubade-msw-home-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home, context.allocator)
	}
	write_global_template(home, "$projectDir/.state")

	state_dir, _ := filepath.join({root, ".state"}, context.temp_allocator)
	_ = os.make_directory_all(state_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	db_path, _ := filepath.join({root, ".state", "aubade.db"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(db_path, "db", os.Permissions{.Read_User, .Write_User})
	readme_path, _ := filepath.join({root, "README.md"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(readme_path, "readme\n", os.Permissions{.Read_User, .Write_User})

	// The write gate resolves the managed location through AUBADE_HOME's
	// global config — isolate it so the template above is what applies.
	old, had := set_aubade_home(home)
	defer restore_aubade_home(old, had)

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, root, .Lf, "", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}

	// The refusal errors' messages land on the caller's allocator (the
	// daemon hands a request arena); this test hands an arena the same
	// way, so the denied paths' allocations die wholesale with it.
	pa: mem.Dynamic_Arena
	mem.dynamic_arena_init(&pa, context.allocator)
	defer mem.dynamic_arena_destroy(&pa)
	arena := mem.dynamic_arena_allocator(&pa)

	_, werr := svc.file_write(e, ".state/aubade.db", "tamper\n", arena)
	testing.expect(t, werr != nil && platform.err_kind(werr) == .Denied)

	derr2 := svc.file_delete(e, ".state/aubade.db", arena)
	testing.expect(t, derr2 != nil && platform.err_kind(derr2) == .Denied)

	in_err := svc.file_move(e, "README.md", ".state/moved.md", arena)
	testing.expect(t, in_err != nil && platform.err_kind(in_err) == .Denied)

	out_err := svc.file_move(e, ".state/aubade.db", "stolen.db", arena)
	testing.expect(t, out_err != nil && platform.err_kind(out_err) == .Denied)

	// The line-edit faces carry the same refusal — the gate must not be
	// bypassable by switching from file_write to file_replace.
	rerr := svc.file_replace(e, ".state/aubade.db", "db", "x", "literal", false, arena)
	testing.expect(t, rerr != nil && platform.err_kind(rerr) == .Denied)

	// Project files outside the state tree are unaffected.
	_, ok_err := svc.file_write(e, "src/fresh.txt", "hello\n", arena)
	testing.expect(t, ok_err == nil)
}

@(test)
svc_managed_state_dir_symbol_edits_refused :: proc(t: ^testing.T) {
	root, derr := os.make_directory_temp("", "aubade-mss-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(root)
		delete(root, context.allocator)
	}
	home, herr := os.make_directory_temp("", "aubade-mss-home-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(home)
		delete(home, context.allocator)
	}
	write_global_template(home, "$projectDir/.state")

	state_dir, _ := filepath.join({root, ".state", "memories"}, context.temp_allocator)
	_ = os.make_directory_all(state_dir, os.Permissions{.Read_User, .Write_User, .Execute_User})
	note_path, _ := filepath.join({root, ".state", "memories", "note.md"}, context.temp_allocator)
	_ = os.write_entire_file_from_string(note_path, "# Title\n\ncontent\n", os.Permissions{.Read_User, .Write_User})

	old, had := set_aubade_home(home)
	defer restore_aubade_home(old, had)

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, root, .Lf, "", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}
	// A zero-value symbol source: the refusal fires before any resolution
	// touches it, and a regressed gate fails through the resolver's
	// empty-root error instead of crashing.
	src := new(svc.TS_Source, context.allocator)
	defer free(src, context.allocator)

	pa: mem.Dynamic_Arena
	mem.dynamic_arena_init(&pa, context.allocator)
	defer mem.dynamic_arena_destroy(&pa)
	arena := mem.dynamic_arena_allocator(&pa)

	// The string-payload family (body/docstring edits share the gate).
	rerr := svc.symbol_edit_replace_body(src, e, "Title", ".state/memories/note.md", "x\n", nil, arena, nil)
	testing.expect(t, rerr != nil && platform.err_kind(rerr) == .Denied)

	derr2 := svc.symbol_edit_insert_docstring(src, e, "Title", ".state/memories/note.md", "comment", nil, arena, nil)
	testing.expect(t, derr2 != nil && platform.err_kind(derr2) == .Denied)

	// move refuses both endpoints, like file_move.
	_, merr := svc.symbol_edit_move(src, e, "Title", ".state/memories/note.md", "src/x.go", "end", .Move, arena, nil)
	testing.expect(t, merr != nil && platform.err_kind(merr) == .Denied)

	_, terr := svc.symbol_edit_move(src, e, "Title", "README.md", ".state/moved.md", "end", .Move, arena, nil)
	testing.expect(t, terr != nil && platform.err_kind(terr) == .Denied)
}

@(test)
svc_file_outline_structured_reads :: proc(t: ^testing.T) {
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
	conn := pair.conn

	// A CI-shaped YAML — the grep-storm poster child.
	svc_symbol_write_file(
		t, pair.tmp, "ci.yml",
		"name: ci\n" +
			"jobs:\n" +
			"  build:\n" +
			"    runs-on: ubuntu-latest\n" +
			"    steps:\n" +
			"      - uses: actions/checkout@v4\n",
	)

	// Outline mode: the key tree with line numbers.
	call := svc.client_file_outline(conn, "ci.yml", "", 0, alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	content, _ := json_str_field(call.result, "content")
	mode, _ := json_str_field(call.result, "mode")
	testing.expect_value(t, mode, "outline")
	testing.expectf(t, strings.contains(content, "jobs: {} (L2-L5)"), content)
	testing.expectf(t, strings.contains(content, "runs-on: ubuntu-latest (L3)"), content)
	testing.expectf(t, strings.contains(content, "uses: actions/checkout@v4 (L5)"), content)

	// Path extraction: the exact value plus its line range.
	call = svc.client_file_outline(conn, "ci.yml", ".jobs.build.runs-on", 0, alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	content, _ = json_str_field(call.result, "content")
	mode, _ = json_str_field(call.result, "mode")
	testing.expect_value(t, mode, "value")
	testing.expect_value(t, content, "ubuntu-latest")
	if v, ok := jsonutil.obj_get(call.result, "start_line"); ok {
		#partial switch x in v {
		case json.Integer:
			testing.expect_value(t, int(x), 3)
		case:
			testing.expectf(t, false, "start_line must be an integer")
		}
	} else {
		testing.expectf(t, false, "start_line missing")
	}

	// A miss names the available keys at the deepest resolved prefix.
	miss := svc.client_file_outline(conn, "ci.yml", ".nope", 0, alloc, deadline)
	testing.expect_value(t, miss.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, miss.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expectf(t, strings.contains(miss.err_message, "available: name, jobs"), miss.err_message)

	// Unsupported types decline with a pointer at file_read.
	svc_symbol_write_file(t, pair.tmp, "plain.txt", "hello\n")
	unsup := svc.client_file_outline(conn, "plain.txt", "", 0, alloc, deadline)
	testing.expect_value(t, unsup.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expectf(t, strings.contains(unsup.err_message, "file_read"), unsup.err_message)

	// .jsonc rides the json5 grammar: comments are tolerated.
	svc_symbol_write_file(t, pair.tmp, "cfg.jsonc", "{\n  // note\n  \"answer\": 42,\n}\n")
	jc := svc.client_file_outline(conn, "cfg.jsonc", ".answer", 0, alloc, deadline)
	testing.expect_value(t, jc.call_err, jsonrpc.Call_Err.None)
	jc_content, _ := json_str_field(jc.result, "content")
	testing.expect_value(t, jc_content, "42")

	// Minified JSON: discovery stays on L0 and extraction still answers.
	svc_symbol_write_file(t, pair.tmp, "pkg.json", "{\"name\":\"x\",\"deps\":{\"odin\":\"0.5\"}}")
	pj := svc.client_file_outline(conn, "pkg.json", ".deps.odin", 0, alloc, deadline)
	testing.expect_value(t, pj.call_err, jsonrpc.Call_Err.None)
	pj_content, _ := json_str_field(pj.result, "content")
	testing.expect_value(t, pj_content, "\"0.5\"")

	// The max_chars cap reports truncation and keeps the partial outline.
	tr := svc.client_file_outline(conn, "ci.yml", "", 30, alloc, deadline)
	testing.expect_value(t, tr.call_err, jsonrpc.Call_Err.None)
	trunc, _ := json_bool_field(tr.result, "truncated")
	testing.expect(t, trunc)
	tr_content, _ := json_str_field(tr.result, "content")
	testing.expectf(t, len(tr_content) > 0 && len(tr_content) <= 30, "partial outline kept: %d bytes", len(tr_content))

	// Directories and missing files decline by kind.
	dir := svc.client_file_outline(conn, ".", "", 0, alloc, deadline)
	testing.expect_value(t, dir.call_err, jsonrpc.Call_Err.Error_Response)
	missing := svc.client_file_outline(conn, "no_such.yml", "", 0, alloc, deadline)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
}

@(test)
svc_file_search_windows_huge_lines :: proc(t: ^testing.T) {
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

	// A minified-JSON shape: one megabyte-scale line with the needle deep
	// inside. Unclamped, this single match eats any answer budget.
	pad := strings.repeat("x", 9000, context.allocator)
	defer delete(pad, context.allocator)
	blob := strings.concatenate({"{\"a\":\"", pad, "NEEDLE", pad, "\"}"}, context.allocator)
	defer delete(blob, context.allocator)
	svc_symbol_write_file(t, pair.tmp, "lock.json", blob)

	req: svc.File_Search_Req
	req.pattern = "NEEDLE"
	req.scope_rel = "lock.json"
	call := svc.client_file_search(pair.conn, req, alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	matches, _ := jsonutil.obj_get(call.result, "matches")
	testing.expect_value(t, json_array_len(matches), 1)
	if json_array_len(matches) == 1 {
		display, _ := json_str_field(json_array_at(matches, 0), "display")
		head := display[:min(80, len(display))]
		testing.expectf(t, strings.contains(display, "NEEDLE"), "needle must stay visible: %s", head)
		testing.expectf(t, strings.contains(display, "…"), "the cut must be marked: %s", head)
		testing.expectf(t, len(display) < 600, "one line must not eat the budget: %d bytes", len(display))
	}
}

@(test)
svc_read_text_normalise_cr_folds_pairs :: proc(t: ^testing.T) {
	// A \r\n pair is ONE newline: it folds to a single \n, never doubles; a
	// lone '\r' (content the editor's pair-only folding leaves alone)
	// rewrites to '\n'; CR-free input passes through as the same bytes.
	composed := "header\npair\r\nlone\rfinis\n"
	out := svc.read_text_normalise_cr(composed, context.temp_allocator)
	testing.expect_value(t, out, "header\npair\nlone\nfinis\n")
	plain := "a\nb\n"
	testing.expect(t, svc.read_text_normalise_cr(plain, context.temp_allocator) == plain)
}

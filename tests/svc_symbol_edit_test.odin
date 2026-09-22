// Contract tests for the symbol-edit svc face over the channel
// transport: the ops re-parse the file fresh, resolve the name path, and
// drive the editor's symbol-level transactions. Assertions are
// structural (ordering, presence) rather than whole-file equality so
// range-convention drift shows up as one failing line, not a diff wall.
package tests

import "core:mem"
import "core:strings"
import "core:testing"
import "src:jsonrpc"
import "src:platform"
import "src:svc"

@(test)
svc_symbol_edit_replace_body :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\nfunc alpha() int {\n\treturn 1\n}\n\nfunc beta() int {\n\treturn 2\n}\n")

	call := svc.client_symbol_replace_body(pair.conn, "alpha", "a.go", "func alpha() int {\n\treturn 42\n}", alloc, deadline)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)

	got := file_read_content(t, pair.conn, "a.go", 0, 0, false, alloc, deadline)
	testing.expect(t, strings.contains(got, "return 42"))
	testing.expect(t, !strings.contains(got, "return 1"))
	testing.expect(t, strings.contains(got, "func beta() int {"))
	testing.expect_value(t, strings.count(got, "func alpha"), 1)

	// Unknown symbol names are Method_Not_Found on the wire.
	missing := svc.client_symbol_replace_body(pair.conn, "nosuch", "a.go", "x", alloc, deadline)
	testing.expect_value(t, missing.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, missing.err_code, jsonrpc.Err_Code.Method_Not_Found)
	testing.expect(t, strings.contains(missing.err_message, "no symbol matching 'nosuch'"))
}

@(test)
svc_symbol_edit_insert_before_after :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\nfunc alpha() int {\n\treturn 1\n}\n")

	before := svc.client_symbol_insert_before(pair.conn, "alpha", "b.go", "func prior() {} ", alloc, deadline)
	testing.expect_value(t, before.call_err, jsonrpc.Call_Err.None)
	got := file_read_content(t, pair.conn, "b.go", 0, 0, false, alloc, deadline)
	// prior lands directly above alpha with an empty line kept between
	// definitions (alpha is a function: neighbour separation).
	prior_idx := strings.index(got, "func prior")
	alpha_idx := strings.index(got, "func alpha")
	testing.expect(t, prior_idx >= 0 && alpha_idx > prior_idx)
	testing.expect(t, strings.contains(got, "func prior() {}\n\nfunc alpha"))

	after := svc.client_symbol_insert_after(pair.conn, "alpha", "b.go", "func next() {}", alloc, deadline)
	testing.expect_value(t, after.call_err, jsonrpc.Call_Err.None)
	got2 := file_read_content(t, pair.conn, "b.go", 0, 0, false, alloc, deadline)
	alpha_idx2 := strings.index(got2, "func alpha")
	next_idx := strings.index(got2, "func next")
	testing.expect(t, alpha_idx2 >= 0 && next_idx > alpha_idx2)
	testing.expect(t, strings.contains(got2, "func alpha() int {\n\treturn 1\n}\n\nfunc next"))

	// The insert body's own trailing newlines do not stack beyond the
	// neighbour separation.
	testing.expect(t, !strings.contains(got2, "\n\n\n"))
}

@(test)
svc_symbol_edit_docstrings :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(t, pair.tmp, "c.go", "package main\n\nfunc alpha() int {\n\treturn 1\n}\n")

	ins := svc.client_symbol_insert_docstring(pair.conn, "alpha", "c.go", "// alpha returns one.", alloc, deadline)
	testing.expect_value(t, ins.call_err, jsonrpc.Call_Err.None)
	got := file_read_content(t, pair.conn, "c.go", 0, 0, false, alloc, deadline)
	testing.expect(t, strings.contains(got, "// alpha returns one.\nfunc alpha"))

	// Replace swaps the block in place.
	repl := svc.client_symbol_replace_docstring(pair.conn, "alpha", "c.go", "// alpha returns one (updated).", alloc, deadline)
	testing.expect_value(t, repl.call_err, jsonrpc.Call_Err.None)
	got2 := file_read_content(t, pair.conn, "c.go", 0, 0, false, alloc, deadline)
	testing.expect(t, !strings.contains(got2, "// alpha returns one.\n"))
	testing.expect(t, strings.contains(got2, "// alpha returns one (updated).\nfunc alpha"))

	// An empty replace comment deletes without inserting.
	del := svc.client_symbol_replace_docstring(pair.conn, "alpha", "c.go", "", alloc, deadline)
	testing.expect_value(t, del.call_err, jsonrpc.Call_Err.None)
	got3 := file_read_content(t, pair.conn, "c.go", 0, 0, false, alloc, deadline)
	testing.expect(t, !strings.contains(got3, "// alpha"))
	testing.expect(t, strings.contains(got3, "func alpha"))

	// delete_docstring on a symbol without a comment is a no-op success.
	noop := svc.client_symbol_delete_docstring(pair.conn, "alpha", "c.go", alloc, deadline)
	testing.expect_value(t, noop.call_err, jsonrpc.Call_Err.None)
	got4 := file_read_content(t, pair.conn, "c.go", 0, 0, false, alloc, deadline)
	testing.expect_value(t, got4, got3)

	// Marker-less comment text is refused, never written verbatim: a bare
	// line is not a comment, and the upward scan could not find it again.
	// Insert and replace share the gate; the file is untouched.
	bare_ins := svc.client_symbol_insert_docstring(pair.conn, "alpha", "c.go", "alpha returns one.", alloc, deadline)
	testing.expect_value(t, bare_ins.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bare_ins.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(bare_ins.err_message, "comment marker"))
	bare_repl := svc.client_symbol_replace_docstring(pair.conn, "alpha", "c.go", "alpha returns one (updated).", alloc, deadline)
	testing.expect_value(t, bare_repl.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, bare_repl.err_code, jsonrpc.Err_Code.Invalid_Params)
	got5 := file_read_content(t, pair.conn, "c.go", 0, 0, false, alloc, deadline)
	testing.expect_value(t, got5, got3)
}

@(test)
svc_symbol_edit_move_cross_file :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(t, pair.tmp, "src.go", "package main\n\n// alpha returns one.\nfunc alpha() int {\n\treturn 1\n}\n")
	svc_symbol_write_file(t, pair.tmp, "dst.go", "package main\n\nfunc keeper() int {\n\treturn 0\n}\n")

	// Move at the end: the comment block travels with the symbol.
	mv := svc.client_symbol_move(pair.conn, "alpha", "src.go", "dst.go", "end", "move", alloc, deadline)
	testing.expect_value(t, mv.call_err, jsonrpc.Call_Err.None)
	summary, sok := json_str_field(mv.result, "summary")
	testing.expectf(t, sok, "summary missing")
	testing.expect(t, strings.contains(summary, "Successfully moved symbol \"alpha\" from src.go to dst.go"))

	src := file_read_content(t, pair.conn, "src.go", 0, 0, false, alloc, deadline)
	testing.expect(t, !strings.contains(src, "func alpha"))
	testing.expect(t, !strings.contains(src, "// alpha returns one"))
	dst := file_read_content(t, pair.conn, "dst.go", 0, 0, false, alloc, deadline)
	keeper_idx := strings.index(dst, "func keeper")
	moved_idx := strings.index(dst, "func alpha")
	testing.expect(t, keeper_idx >= 0 && moved_idx > keeper_idx)
	testing.expect(t, strings.contains(dst, "// alpha returns one.\nfunc alpha() int {"))

	// Copy mode leaves the source untouched. src.go is buffered by the
	// earlier move, so the rewrite goes through the svc file face (a raw
	// disk write would leave the editor holding a stale buffer).
	rewrite := svc.client_file_write(pair.conn, "src.go", "package main\n\nfunc gamma() int {\n\treturn 3\n}\n", alloc, deadline)
	testing.expect_value(t, rewrite.call_err, jsonrpc.Call_Err.None)
	cp := svc.client_symbol_move(pair.conn, "gamma", "src.go", "dst.go", "end", "copy", alloc, deadline)
	testing.expect_value(t, cp.call_err, jsonrpc.Call_Err.None)
	src2 := file_read_content(t, pair.conn, "src.go", 0, 0, false, alloc, deadline)
	testing.expect(t, strings.contains(src2, "func gamma"))
	dst2 := file_read_content(t, pair.conn, "dst.go", 0, 0, false, alloc, deadline)
	testing.expect(t, strings.contains(dst2, "func gamma"))

	// A name-path target position anchors after that symbol (anchor.go is
	// fresh on disk, so a direct write is fine).
	svc_symbol_write_file(t, pair.tmp, "anchor.go", "package main\n\nfunc first() int {\n\treturn 1\n}\n\nfunc last() int {\n\treturn 9\n}\n")
	at := svc.client_symbol_move(pair.conn, "gamma", "src.go", "anchor.go", "first", "move", alloc, deadline)
	testing.expect_value(t, at.call_err, jsonrpc.Call_Err.None)
	anchor := file_read_content(t, pair.conn, "anchor.go", 0, 0, false, alloc, deadline)
	first_idx := strings.index(anchor, "func first")
	gamma_idx := strings.index(anchor, "func gamma")
	last_idx := strings.index(anchor, "func last")
	testing.expect(t, first_idx >= 0 && gamma_idx > first_idx && last_idx > gamma_idx)
}

@(test)
svc_symbol_edit_move_same_file :: proc(t: ^testing.T) {
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

	content := "package main\n\nfunc alpha() int {\n\treturn 1\n}\n\nfunc beta() int {\n\treturn 2\n}\n"
	svc_symbol_write_file(t, pair.tmp, "same.go", content)

	// Downward: alpha moves below beta (insert beyond its own range).
	down := svc.client_symbol_move(pair.conn, "alpha", "same.go", "same.go", "beta", "move", alloc, deadline)
	testing.expect_value(t, down.call_err, jsonrpc.Call_Err.None)
	got := file_read_content(t, pair.conn, "same.go", 0, 0, false, alloc, deadline)
	testing.expect_value(t, strings.count(got, "func alpha"), 1)
	beta_idx := strings.index(got, "func beta")
	alpha_idx := strings.index(got, "func alpha")
	testing.expect(t, beta_idx >= 0 && alpha_idx > beta_idx)

	// Upward: and back above beta. same.go is buffered by the downward
	// move, so the reset goes through the svc file face.
	reset := svc.client_file_write(pair.conn, "same.go", content, alloc, deadline)
	testing.expect_value(t, reset.call_err, jsonrpc.Call_Err.None)
	up := svc.client_symbol_move(pair.conn, "beta", "same.go", "same.go", "alpha", "move", alloc, deadline)
	testing.expect_value(t, up.call_err, jsonrpc.Call_Err.None)
	got2 := file_read_content(t, pair.conn, "same.go", 0, 0, false, alloc, deadline)
	testing.expect_value(t, strings.count(got2, "func beta"), 1)
	alpha_idx2 := strings.index(got2, "func alpha")
	beta_idx2 := strings.index(got2, "func beta")
	testing.expect(t, alpha_idx2 >= 0 && beta_idx2 > alpha_idx2)

	// Invalid mode is rejected before any edit.
	badmode := svc.client_symbol_move(pair.conn, "alpha", "same.go", "same.go", "end", "bogus", alloc, deadline)
	testing.expect_value(t, badmode.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, badmode.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(badmode.err_message, "invalid mode"))
}

@(test)
svc_symbol_edit_move_rejections :: proc(t: ^testing.T) {
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

	// A type with nested methods is not a leaf.
	svc_symbol_write_file(
		t, pair.tmp, "owner.go",
		"package main\n\ntype T struct{}\n\nfunc (t T) Method() int {\n\treturn 1\n}\n",
	)
	svc_symbol_write_file(t, pair.tmp, "dst2.go", "package main\n")

	parent := svc.client_symbol_move(pair.conn, "T", "owner.go", "dst2.go", "end", "move", alloc, deadline)
	testing.expect_value(t, parent.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, parent.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(parent.err_message, "only supports leaf symbols"))

	// Unsupported file types never reach the outline.
	svc_symbol_write_file(t, pair.tmp, "notes.txt", "plain text\n")
	unsupported := svc.client_symbol_move(pair.conn, "x", "notes.txt", "dst2.go", "end", "move", alloc, deadline)
	testing.expect_value(t, unsupported.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, unsupported.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expect(t, strings.contains(unsupported.err_message, "unsupported file type"))

	// Unknown target symbol in the target file.
	unknown := svc.client_symbol_move(pair.conn, "Method", "owner.go", "dst2.go", "nosuch", "move", alloc, deadline)
	testing.expect_value(t, unknown.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, unknown.err_code, jsonrpc.Err_Code.Method_Not_Found)
}

// The target file's existing declaration of the same name blocks the
// move/copy: a written duplicate would break every later symbol op on
// that name with ambiguous resolution.
@(test)
svc_symbol_edit_move_duplicate_rejected :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(t, pair.tmp, "src.go", "package main\n\nfunc alpha() int {\n\treturn 1\n}\n")
	svc_symbol_write_file(t, pair.tmp, "dst.go", "package main\n\nfunc alpha() int {\n\treturn 2\n}\n")

	mv := svc.client_symbol_move(pair.conn, "alpha", "src.go", "dst.go", "end", "move", alloc, deadline)
	testing.expect_value(t, mv.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, mv.err_code, jsonrpc.Err_Code.Invalid_Params)
	testing.expectf(t, strings.contains(mv.err_message, "already declares"), "steering error, got: %s", mv.err_message)

	// Copy mode collides the same way.
	cp := svc.client_symbol_move(pair.conn, "alpha", "src.go", "dst.go", "end", "copy", alloc, deadline)
	testing.expect_value(t, cp.call_err, jsonrpc.Call_Err.Error_Response)
	testing.expect_value(t, cp.err_code, jsonrpc.Err_Code.Invalid_Params)

	// Nothing was written: each file keeps exactly one declaration.
	src := file_read_content(t, pair.conn, "src.go", 0, 0, false, alloc, deadline)
	testing.expect_value(t, strings.count(src, "func alpha"), 1)
	dst := file_read_content(t, pair.conn, "dst.go", 0, 0, false, alloc, deadline)
	testing.expect_value(t, strings.count(dst, "func alpha"), 1)
}

// One file, two spellings: "./same.go" and "same.go" are the same file,
// so the move must take the same-file path — the cross-file branch would
// delete by pre-insert coordinates and mangle the file.
@(test)
svc_symbol_edit_move_path_spelling_normalized :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(
		t, pair.tmp, "same.go",
		"package main\n\nfunc alpha() int {\n\treturn 1\n}\n\nfunc beta() int {\n\treturn 2\n}\n\nfunc gamma() int {\n\treturn 3\n}\n",
	)

	mv := svc.client_symbol_move(pair.conn, "gamma", "./same.go", "same.go", "alpha", "move", alloc, deadline)
	testing.expect_value(t, mv.call_err, jsonrpc.Call_Err.None)
	got := file_read_content(t, pair.conn, "same.go", 0, 0, false, alloc, deadline)
	testing.expectf(
		t,
		got == "package main\n\nfunc alpha() int {\n\treturn 1\n}\n\nfunc gamma() int {\n\treturn 3\n}\n\nfunc beta() int {\n\treturn 2\n}\n",
		"gamma moved below alpha with beta intact: %q",
		got,
	)
}

@(test)
svc_symbol_edit_replace_body_indented :: proc(t: ^testing.T) {
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

	svc_symbol_write_file(
		t, pair.tmp, "cls.ts",
		"class Foo {\n    alpha(): number {\n        return 1\n    }\n}\n",
	)

	// The replacement body arrives unindented; the op re-indents
	// continuation lines under the definition's indent.
	call := svc.client_symbol_replace_body(
		pair.conn, "Foo/alpha", "cls.ts",
		"alpha(): number {\nreturn 42\n}",
		alloc, deadline,
	)
	testing.expect_value(t, call.call_err, jsonrpc.Call_Err.None)
	got := file_read_content(t, pair.conn, "cls.ts", 0, 0, false, alloc, deadline)
	testing.expect(t, strings.contains(got, "    alpha(): number {\n    return 42\n    }"))
}

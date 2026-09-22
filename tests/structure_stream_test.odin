// The streaming structural face: byte-scan answers for strict JSON above
// the parse-tree budget, plus JSONL streams as record sequences. The
// parity tests pin the strongest property — the same fixture answers
// identically through the tree face and the stream face — so crossing the
// budget changes nothing a caller can see.
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:editor"
import "src:svc"
import "src:ts"
import "src:util"

stream_json_fixture :: `{
  "name": "demo",
  "ver": 2,
  "arr": ["a", 1, null],
  "nest": {
    "k": "v"
  }
}
`

stream_path_parity :: proc(t: ^testing.T, fixture: string, path: string) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	pr, perr := ts.parse(fixture, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	want, werr := ts.structure_resolve_path(ts.parse_root(&pr), fixture, path, 0, a)
	got, gerr := ts.structure_stream_resolve_path(fixture, path, 0, a)
	testing.expectf(t, werr == gerr, "error parity for %q: tree %q vs stream %q", path, werr, gerr)
	testing.expectf(t, want.content == got.content, "content parity for %q: %q vs %q", path, want.content, got.content)
	testing.expectf(
		t,
		want.start_line == got.start_line && want.end_line == got.end_line,
		"line parity for %q: (%d,%d) vs (%d,%d)",
		path, want.start_line, want.end_line, got.start_line, got.end_line,
	)
	testing.expect_value(t, got.kind, want.kind)
}

@(test)
stream_outline_parity :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	fixtures := []string{
		stream_json_fixture,
		`{"a":{"b":[1,2],"c":"x"}}`,
		`[1, "two", {"three": 3}]`,
		`{"only": null}`,
		`42`,
		// Quoted scalars carrying delimiter bytes: the preview span must
		// run to the closing quote, not cut at the , } ] inside the
		// string (the tree face previews the whole node).
		`{"msg": "hello, world", "tricky": "has } ] , inside"}`,
	}
	for fixture in fixtures {
		pr, perr := ts.parse(fixture, "json")
		testing.expectf(t, perr == "", "parse failed: %s", perr)
		if perr != "" {
			continue
		}
		want, wtrunc := ts.structure_outline(ts.parse_root(&pr), fixture, {}, a)
		got, gtrunc, serr := ts.structure_stream_outline(fixture, {}, a)
		testing.expectf(t, serr == "", "stream error: %s", serr)
		testing.expectf(t, want == got, "outline parity:\ntree:\n%s\nstream:\n%s", want, got)
		testing.expect_value(t, gtrunc, wtrunc)
		ts.parse_release(&pr)
	}
}

@(test)
stream_path_parity_suite :: proc(t: ^testing.T) {
	paths := []string{
		".name",
		".ver",
		".arr",
		".arr[0]",
		".arr[2]",
		".arr[-1]",
		".nest.k",
		".nest | keys",
		".arr[]",
		".missing",
		".nest.missing",
		".arr.zzz",
		".name.deep",
		".arr[7]",
		".arr[-9]",
		".",
	}
	for path in paths {
		stream_path_parity(t, stream_json_fixture, path)
	}
}

@(test)
stream_parse_error_line :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// The error row is 0-based, matching the tree face's error line.
	_, _, err := ts.structure_stream_outline("{\n  \"a\": trx\n}\n", {}, a)
	testing.expectf(t, strings.contains(err, "near line 1"), "expected a row-1 parse error (0-based), got %q", err)
}

@(test)
stream_verdict_parity :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Verdict parity for shapes the faces could disagree on: the tree
	// face's grammar is the reference (it admits "1." and \u without hex
	// digits, rejects '+' exponents and invalid escapes), and the same
	// fixture must render on both faces or error on both.
	fixtures := []string{
		`{"esc": "\x"}`,
		`{"esc": "\q"}`,
		`{"esc": "\u12"}`,
		`{"esc": "\/"}`,
		`{"num": 1.2.3}`,
		`{"num": 01}`,
		`{"num": 1.}`,
		`{"num": 1e}`,
		`{"num": 1e+2}`,
		`{"num": 1E-2}`,
		`{"num": -}`,
		`{"num": -0.5e-3}`,
	}
	for fixture in fixtures {
		pr, perr := ts.parse(fixture, "json")
		testing.expectf(t, perr == "", "parse failed: %s", perr)
		if perr != "" {
			continue
		}
		tree_bad := ts.structure_error_row(ts.parse_root(&pr)) >= 0
		text, _, serr := ts.structure_stream_outline(fixture, {}, a)
		testing.expectf(
			t,
			tree_bad == (serr != ""),
			"verdict mismatch on %q: tree rejects=%v, stream err=%q",
			fixture,
			tree_bad,
			serr,
		)
		if !tree_bad && serr == "" {
			want, _ := ts.structure_outline(ts.parse_root(&pr), fixture, {}, a)
			testing.expectf(t, want == text, "outline parity on %q:\ntree:\n%s\nstream:\n%s", fixture, want, text)
		}
		ts.parse_release(&pr)
	}
}

@(test)
stream_jsonl_root :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	src := "{\"lvl\": \"info\", \"msg\": \"one\"}\n{\"lvl\": \"warn\", \"msg\": \"two\"}\n{\"lvl\": \"info\", \"msg\": \"three\"}\n"

	res, err := ts.structure_stream_resolve_path(src, "[1]", 0, a)
	testing.expectf(t, err == "", "index: %s", err)
	testing.expect_value(t, res.content, "{\"lvl\": \"warn\", \"msg\": \"two\"}")
	testing.expect_value(t, res.start_line, 1)
	testing.expect_value(t, res.end_line, 1)

	res, err = ts.structure_stream_resolve_path(src, "[].lvl", 0, a) // [] must be last: parse error expected
	testing.expectf(t, err != "", "[] mid-path must be rejected")

	res, err = ts.structure_stream_resolve_path(src, "[]", 40, a)
	testing.expectf(t, err == "", "iterate: %s", err)
	testing.expectf(t, strings.contains(res.content, "[0] (L0-L0):"), "iterate head: %q", res.content)
	testing.expect_value(t, res.truncated, true)

	// The field-on-records-root miss mirrors the array miss text.
	_, err = ts.structure_stream_resolve_path(src, ".lvl", 0, a)
	testing.expectf(t, strings.contains(err, "is an array"), "root miss text: %q", err)

	text, _, oerr := ts.structure_stream_outline(src, {max_chars = 200}, a)
	testing.expectf(t, oerr == "", "outline: %s", oerr)
	testing.expectf(t, strings.contains(text, "[3] (L0-L2)"), "jsonl root head: %q", text)
}

// stream_huge_source builds a deterministic >1 MiB JSON document: a head
// object plus `records`, one record per line, each padded to a known
// width so line numbers are computable (record i sits on line 3+i, the
// records array spans L2 to L(3+n)).
stream_huge_source :: proc(n: int, a := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, 1024 * 1200, a)
	strings.write_string(&b, "{\n\"head\": {\"n\": ")
	strings.write_string(&b, util.int_to_dec(n, context.temp_allocator))
	strings.write_string(&b, "},\n\"records\": [\n")
	for i := 0; i < n; i += 1 {
		strings.write_string(&b, "{\"id\": ")
		strings.write_string(&b, util.int_to_dec(i, context.temp_allocator))
		strings.write_string(&b, ", \"pad\": \"")
		// ~360 bytes of padding per record keeps the document over 1 MiB
		// while every record stays on one line.
		for p := 0; p < 360; p += 1 {
			strings.write_byte(&b, 'a')
		}
		strings.write_string(&b, "\"}")
		if i + 1 < n {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "]\n}\n")
	out := strings.clone(strings.to_string(b), a)
	strings.builder_destroy(&b)
	return out
}

@(test)
stream_above_tree_budget :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	src := stream_huge_source(3000, a)
	testing.expectf(t, len(src) > 1024 * 1024, "fixture must exceed 1 MiB, got %d", len(src))

	// Far-end path: the last record answers with its computed line.
	res, err := ts.structure_stream_resolve_path(src, ".records[2999].id", 0, a)
	testing.expectf(t, err == "", "path: %s", err)
	testing.expect_value(t, res.content, "2999")
	testing.expect_value(t, res.start_line, 3 + 2999)
	testing.expect_value(t, res.end_line, 3 + 2999)

	// Negative index against the counted total.
	res, err = ts.structure_stream_resolve_path(src, ".records[-1].pad", 0, a)
	testing.expectf(t, err == "", "negative index: %s", err)
	testing.expect_value(t, res.start_line, 3 + 2999)

	// Keys and budget truncation.
	res, err = ts.structure_stream_resolve_path(src, ".head | keys", 0, a)
	testing.expectf(t, err == "", "keys: %s", err)
	testing.expect_value(t, res.content, "n (L1)\n")

	text, truncated, oerr := ts.structure_stream_outline(src, {max_chars = 300}, a)
	testing.expectf(t, oerr == "", "outline: %s", oerr)
	testing.expect_value(t, truncated, true)
	testing.expectf(t, strings.contains(text, "records: [3000] (L2"), "outline head: %q", text)

	// A miss lists the sampled keys exactly like the tree face.
	_, err = ts.structure_stream_resolve_path(src, ".head.zz", 0, a)
	testing.expectf(t, err == "unknown field \"zz\" at path .head; available: n", "miss text: %q", err)
}

@(test)
stream_file_outline_over_budget :: proc(t: ^testing.T) {
	dir, terr := os.make_directory_temp("", "aubade-stream-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir, context.allocator)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	big := stream_huge_source(3000, a)
	big_path, _ := filepath.join([]string{dir, "big.json"}, context.temp_allocator)
	if werr := os.write_entire_file_from_bytes(big_path, transmute([]u8)big); werr != nil {
		testing.fail_now(t, "fixture write failed")
	}
	json5_full, _ := filepath.join([]string{dir, "huge.json5"}, context.temp_allocator)
	if werr := os.write_entire_file_from_bytes(json5_full, transmute([]u8)big); werr != nil {
		testing.fail_now(t, "fixture write failed")
	}

	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "utf-8", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}

	// Above the tree budget, JSON answers through the stream.
	res, err := svc.file_outline(e, nil, "big.json", ".records[2999].id", 0, a)
	testing.expectf(t, err == nil, "over-budget json must stream, got: %v", err)
	if err == nil {
		testing.expect_value(t, res.content, "2999")
		testing.expect_value(t, res.mode, svc.File_Outline_Mode.Value)
	}

	res, err = svc.file_outline(e, nil, "big.json", "", 400, a)
	testing.expectf(t, err == nil, "outline: %v", err)
	if err == nil {
		testing.expect_value(t, res.mode, svc.File_Outline_Mode.Outline)
		testing.expect_value(t, res.truncated, true)
	}

	// json5 has no stream: the tree budget still refuses.
	_, err = svc.file_outline(e, nil, "huge.json5", "", 0, a)
	testing.expectf(t, err != nil, "over-budget json5 must refuse")
}

@(test)
stream_jsonl_validates_every_record :: proc(t: ^testing.T) {
	// The whole-document contract: a torn tail is a parse error, never a
	// silently truncated outline.
	j1, e1 := ts.stream_is_jsonl(`{"a":1}`, context.temp_allocator)
	testing.expect_value(t, j1, false)
	testing.expect_value(t, e1, "")
	j2, e2 := ts.stream_is_jsonl("{\"a\":1}\n{\"b\":2}\n", context.temp_allocator)
	testing.expect_value(t, j2, true)
	testing.expect_value(t, e2, "")
	_, e3 := ts.stream_is_jsonl("{\"a\":1}\n{\"torn", context.temp_allocator)
	testing.expect(t, e3 != "", "torn tail must surface as a parse error")
}

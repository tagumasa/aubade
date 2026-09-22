// Structure walker and path resolver over the compiled json/json5/yaml
// grammars: outline shape, line numbers, previews, anchors/aliases, the
// jq-style path subset, and its self-healing miss errors.
package tests

import "core:mem"
import "core:strings"
import "core:testing"
import "src:regex"
import "src:ts"

STRUCTURE_JSON_FIXTURE :: `{
  "name": "demo",
  "ver": 2,
  "arr": ["a", 1, null],
  "nest": {
    "k": "v"
  }
}
`

@(test)
structure_outline_json :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	pr, perr := ts.parse(STRUCTURE_JSON_FIXTURE, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, truncated := ts.structure_outline(ts.parse_root(&pr), STRUCTURE_JSON_FIXTURE, {}, a)
	testing.expect(t, !truncated)
	testing.expect_value(t, text, "{} (L0-L7)\n"+
		"  name: \"demo\" (L1)\n"+
		"  ver: 2 (L2)\n"+
		"  arr: [3] (L3)\n"+
		"    [0]: \"a\" (L3)\n"+
		"    [1]: 1 (L3)\n"+
		"    [2]: null (L3)\n"+
		"  nest: {} (L4-L6)\n"+
		"    k: \"v\" (L5)\n")
}

@(test)
structure_outline_minified_json :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "{\"a\":{\"b\":[1,2],\"c\":\"x\"}}"
	pr, perr := ts.parse(code, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, _ := ts.structure_outline(ts.parse_root(&pr), code, {}, a)
	// Everything sits on L0 — discovery still works; extraction covers
	// values (line numbers are useless on one-line files by nature).
	testing.expect_value(t, text, "{} (L0)\n"+
		"  a: {} (L0)\n"+
		"    b: [2] (L0)\n"+
		"      [0]: 1 (L0)\n"+
		"      [1]: 2 (L0)\n"+
		"    c: \"x\" (L0)\n")
}

@(test)
structure_outline_yaml :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "name: x\n" +
		"jobs:\n" +
		"  build:\n" +
		"    steps:\n" +
		"      - uses: checkout\n" +
		"      - run: make test\n" +
		"anchored: &base\n" +
		"  key: val\n" +
		"ref: *base\n"
	pr, perr := ts.parse(code, "yaml")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, _ := ts.structure_outline(ts.parse_root(&pr), code, {}, a)
	// Container values report the span of their content (the nested
	// mapping's first line through its last), not the key line that
	// introduces them — that line belongs to the parent pair.
	testing.expect_value(t, text, "{} (L0-L8)\n"+
		"  name: x (L0)\n"+
		"  jobs: {} (L2-L5)\n"+
		"    build: {} (L3-L5)\n"+
		"      steps: [2] (L4-L5)\n"+
		"        [0]: {} (L4)\n" +
		"          uses: checkout (L4)\n" +
		"        [1]: {} (L5)\n" +
		"          run: make test (L5)\n" +
		"  anchored: {} (L7) &base\n" +
		"    key: val (L7)\n" +
		"  ref: *base (alias) (L8)\n")
}

@(test)
structure_outline_json5_comments :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// .jsonc content rides the json5 grammar: comments and bare keys.
	code := "{\n" +
		"  // top\n" +
		"  \"quoted key\": \"v\",\n" +
		"  bare: 1,\n" +
		"}\n"
	pr, perr := ts.parse(code, "json5")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, _ := ts.structure_outline(ts.parse_root(&pr), code, {}, a)
	testing.expect_value(t, text, "{} (L0-L4)\n"+
		"  quoted key: \"v\" (L2)\n"+
		"  bare: 1 (L3)\n")
}

@(test)
structure_outline_yaml_flow_and_block_scalar :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "flow: {a: 1, b: [2, 3]}\n" +
		"script: |\n" +
		"  echo hi\n" +
		"  echo bye\n"
	pr, perr := ts.parse(code, "yaml")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, _ := ts.structure_outline(ts.parse_root(&pr), code, {}, a)
	testing.expectf(t, strings.contains(text, "flow: {} (L0)"), "flow entry missing: %s", text)
	testing.expectf(t, strings.contains(text, "  a: 1 (L0)"), "flow pair missing: %s", text)
	testing.expectf(t, strings.contains(text, "  b: [2] (L0)"), "flow seq missing: %s", text)
	// The block scalar preview folds its newlines; inner indentation
	// stays (it is part of the value).
	testing.expectf(t, strings.contains(text, "script: |⏎  echo hi⏎  echo bye (L1-L3)"), "block scalar preview: %s", text)
}

@(test)
structure_outline_multi_document_yaml :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "a: 1\n---\nb: 2\n"
	pr, perr := ts.parse(code, "yaml")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, _ := ts.structure_outline(ts.parse_root(&pr), code, {}, a)
	testing.expectf(t, strings.contains(text, "doc[0]: {}"), "doc 0 missing: %s", text)
	testing.expectf(t, strings.contains(text, "doc[1]: {}"), "doc 1 missing: %s", text)
	testing.expectf(t, strings.contains(text, "  a: 1 (L0)"), "doc 0 key missing: %s", text)
	testing.expectf(t, strings.contains(text, "  b: 2 (L2)"), "doc 1 key missing: %s", text)
}

@(test)
structure_outline_truncates_at_max_chars :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	pr, perr := ts.parse(STRUCTURE_JSON_FIXTURE, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, truncated := ts.structure_outline(ts.parse_root(&pr), STRUCTURE_JSON_FIXTURE, {max_chars = 40}, a)
	testing.expect(t, truncated)
	testing.expect(t, len(text) <= 40)
	// Whole lines survive: the cut never slices a line in half.
	testing.expectf(t, strings.has_suffix(text, "\n"), "partial line at the cut: %q", text)
}

@(test)
structure_outline_caps_array_items :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "nums: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]\n"
	pr, perr := ts.parse(code, "yaml")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	text, _ := ts.structure_outline(ts.parse_root(&pr), code, {}, a)
	testing.expectf(t, strings.contains(text, "nums: [12] (L0)"), "count missing: %s", text)
	testing.expectf(t, strings.contains(text, "… +2 more"), "collapse marker missing: %s", text)
	testing.expect(t, !strings.contains(text, "[10]"))
}

@(test)
structure_path_value_modes :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	pr, perr := ts.parse(STRUCTURE_JSON_FIXTURE, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)

	res, err := ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".ver", 0, a)
	testing.expectf(t, err == "", "ver: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Value)
	testing.expect_value(t, res.content, "2")
	testing.expect_value(t, res.start_line, 2)

	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".nest.k", 0, a)
	testing.expectf(t, err == "", "nest.k: %s", err)
	testing.expect_value(t, res.content, "\"v\"")

	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr[1]", 0, a)
	testing.expectf(t, err == "", "arr[1]: %s", err)
	testing.expect_value(t, res.content, "1")

	// Negative index counts from the end, jq-style.
	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr[-1]", 0, a)
	testing.expectf(t, err == "", "arr[-1]: %s", err)
	testing.expect_value(t, res.content, "null")

	// Container values return their exact source slice.
	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".nest", 0, a)
	testing.expectf(t, err == "", "nest: %s", err)
	testing.expect_value(t, res.content, "{\n    \"k\": \"v\"\n  }")

	// keys lists an object's keys with their lines.
	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ". | keys", 0, a)
	testing.expectf(t, err == "", "keys: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Keys)
	testing.expect_value(t, res.content, "name (L1)\nver (L2)\narr (L3)\nnest (L4)\n")

	// [] iterates with per-item line ranges.
	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr[]", 0, a)
	testing.expectf(t, err == "", "arr[]: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Iterated)
	testing.expect_value(t, res.content, "[0] (L3-L3):\n  \"a\"\n[1] (L3-L3):\n  1\n[2] (L3-L3):\n  null\n")

	// Quoted fields reach keys the bare grammar cannot express.
	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".\"nest\".\"k\"", 0, a)
	testing.expectf(t, err == "", "quoted path: %s", err)
	testing.expect_value(t, res.content, "\"v\"")

	// Value truncation reports and slices.
	res, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".nest", 8, a)
	testing.expectf(t, err == "", "nest truncated: %s", err)
	testing.expect(t, res.truncated)
	testing.expect_value(t, len(res.content), 8)
}

@(test)
structure_path_bracket_string_subscripts :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Keys the bare grammar cannot express: '#', ']' plus a space, and a
	// '.' inside the key (a bare .v1.2 would split into two segments).
	code := "{\"we#ird\": 1, \"a]b c\": 2, \"v1.2\": 3, \"nest\": {\"k\": \"v\"}}"
	pr, perr := ts.parse(code, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)

	// jq's bracket string subscript, with or without the leading dot.
	res, err := ts.structure_resolve_path(root, code, ".[\"we#ird\"]", 0, a)
	testing.expectf(t, err == "", "dotted bracket: %s", err)
	testing.expect_value(t, res.content, "1")

	res, err = ts.structure_resolve_path(root, code, "[\"we#ird\"]", 0, a)
	testing.expectf(t, err == "", "bare bracket: %s", err)
	testing.expect_value(t, res.content, "1")

	// A ']' inside the quoted key must not close the subscript.
	res, err = ts.structure_resolve_path(root, code, "[\"a]b c\"]", 0, a)
	testing.expectf(t, err == "", "bracketed ] and space: %s", err)
	testing.expect_value(t, res.content, "2")

	res, err = ts.structure_resolve_path(root, code, ".[\"v1.2\"]", 0, a)
	testing.expectf(t, err == "", "dot inside key: %s", err)
	testing.expect_value(t, res.content, "3")

	// The bracket form chains and mixes with the other forms; it is one
	// grammar, not a second resolver.
	res, err = ts.structure_resolve_path(root, code, "[\"nest\"][\"k\"]", 0, a)
	testing.expectf(t, err == "", "chained brackets: %s", err)
	testing.expect_value(t, res.content, "\"v\"")

	res, err = ts.structure_resolve_path(root, code, ".nest[\"k\"]", 0, a)
	testing.expectf(t, err == "", "mixed forms: %s", err)
	testing.expect_value(t, res.content, "\"v\"")

	res, err = ts.structure_resolve_path(root, code, ".[\"nest\"] | keys", 0, a)
	testing.expectf(t, err == "", "keys after bracket: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Keys)

	// A miss through a bracket field self-heals like any field miss.
	_, err = ts.structure_resolve_path(root, code, ".[\"nope\"]", 0, a)
	testing.expectf(t, strings.contains(err, "unknown field"), "miss text: %s", err)

	// A bracket field advances the scan the same way an index does — the
	// terminal-[] rule still applies behind it.
	_, err = ts.structure_resolve_path(root, code, ".[\"nest\"][]extra", 0, a)
	testing.expectf(t, strings.contains(err, "[] must be the last segment"), "scan advance: %s", err)

	// Bare words stay index-only; the error steers toward the quoted form.
	_, err = ts.structure_resolve_path(root, code, ".[we#ird]", 0, a)
	testing.expectf(t, strings.contains(err, "string keys need quotes"), "steering: %s", err)

	// Trailing text after the closing quote is malformed, not a key.
	_, err = ts.structure_resolve_path(root, code, ".[\"nest\"x]", 0, a)
	testing.expectf(t, strings.contains(err, "bad subscript"), "trailing text: %s", err)

	// An unterminated quoted key swallows every ']' — the subscript never
	// closes.
	_, err = ts.structure_resolve_path(root, code, ".[\"oops", 0, a)
	testing.expectf(t, strings.contains(err, "unterminated"), "unterminated quote: %s", err)
}

@(test)
structure_path_yaml_and_json5 :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "jobs:\n" +
		"  build:\n" +
		"    steps:\n" +
		"      - uses: checkout\n" +
		"      - run: make test\n"
	pr, perr := ts.parse(code, "yaml")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)

	res, err := ts.structure_resolve_path(root, code, ".jobs.build.steps[1].run", 0, a)
	testing.expectf(t, err == "", "yaml path: %s", err)
	testing.expect_value(t, res.content, "make test")
	testing.expect_value(t, res.start_line, 4)

	res, err = ts.structure_resolve_path(root, code, ".jobs | keys", 0, a)
	testing.expectf(t, err == "", "yaml keys: %s", err)
	testing.expect_value(t, res.content, "build (L1)\n")

	res, err = ts.structure_resolve_path(root, code, ".jobs.build.steps[]", 0, a)
	testing.expectf(t, err == "", "yaml iterate: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Iterated)
	testing.expectf(t, strings.contains(res.content, "uses: checkout"), "item 0: %s", res.content)
	testing.expectf(t, strings.contains(res.content, "run: make test"), "item 1: %s", res.content)

	// json5: bare and quoted keys both resolve.
	j5 := "{\n  // c\n  \"quoted key\": \"v\",\n  bare: 1,\n}\n"
	pr5, perr5 := ts.parse(j5, "json5")
	testing.expectf(t, perr5 == "", "json5 parse failed: %s", perr5)
	if perr5 != "" {
		return
	}
	defer ts.parse_release(&pr5)
	root5 := ts.parse_root(&pr5)

	res, err = ts.structure_resolve_path(root5, j5, ".\"quoted key\"", 0, a)
	testing.expectf(t, err == "", "json5 quoted: %s", err)
	testing.expect_value(t, res.content, "\"v\"")

	res, err = ts.structure_resolve_path(root5, j5, ".bare", 0, a)
	testing.expectf(t, err == "", "json5 bare: %s", err)
	testing.expect_value(t, res.content, "1")
}

@(test)
structure_path_multi_document_index :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	code := "a: 1\n---\nb: 2\n"
	pr, perr := ts.parse(code, "yaml")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)

	res, err := ts.structure_resolve_path(ts.parse_root(&pr), code, ".[1].b", 0, a)
	testing.expectf(t, err == "", "doc index: %s", err)
	testing.expect_value(t, res.content, "2")
}

@(test)
structure_path_miss_errors_self_heal :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	pr, perr := ts.parse(STRUCTURE_JSON_FIXTURE, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)

	// A miss names the available keys at the deepest resolved prefix.
	_, err := ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".nope", 0, a)
	testing.expectf(t, strings.contains(err, "unknown field \"nope\""), "miss text: %s", err)
	testing.expectf(t, strings.contains(err, "available: name, ver, arr, nest"), "available list: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".nest.nope", 0, a)
	testing.expectf(t, strings.contains(err, "at path .nest"), "prefix in miss: %s", err)
	testing.expectf(t, strings.contains(err, "available: k"), "nested available: %s", err)

	// Shape mismatches say what the node is and what to use instead.
	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".ver.x", 0, a)
	testing.expectf(t, strings.contains(err, "is a scalar"), "scalar descend: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr.x", 0, a)
	testing.expectf(t, strings.contains(err, "is an array; use [index]"), "field on array: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".nest[0]", 0, a)
	testing.expectf(t, strings.contains(err, "is an object; use a field name"), "index on object: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr[7]", 0, a)
	testing.expectf(t, strings.contains(err, "index 7 out of range"), "oob text: %s", err)
	testing.expectf(t, strings.contains(err, "(3 items)"), "oob count: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".ver | keys", 0, a)
	testing.expectf(t, strings.contains(err, "is not an object; | keys needs one"), "keys on scalar: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".ver[]", 0, a)
	testing.expectf(t, strings.contains(err, "is not an array; [] iterates arrays"), "iterate on scalar: %s", err)

	// Path syntax errors are their own class of message.
	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".a..b", 0, a)
	testing.expectf(t, strings.contains(err, "invalid path"), "syntax error: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr[3] | filter", 0, a)
	testing.expectf(t, strings.contains(err, "unsupported operator"), "operator error: %s", err)

	_, err = ts.structure_resolve_path(root, STRUCTURE_JSON_FIXTURE, ".arr[][0]", 0, a)
	testing.expectf(t, strings.contains(err, "[] must be the last segment"), "iterate placement: %s", err)
}

@(test)
structure_error_row_finds_first_error :: proc(t: ^testing.T) {
	good, perr := ts.parse("{\"a\": 1}\n", "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&good)
	testing.expect_value(t, ts.structure_error_row(ts.parse_root(&good)), -1)

	bad, berr := ts.parse("{\n  \"a\": ,, 1\n}\n", "json")
	testing.expectf(t, berr == "", "parse failed: %s", berr)
	if berr != "" {
		return
	}
	defer ts.parse_release(&bad)
	testing.expect_value(t, ts.structure_error_row(ts.parse_root(&bad)), 1)
}

@(test)
structure_error_row_prefers_earliest_error :: proc(t: ^testing.T) {
	// Two bad values on different lines: the reported row must be the
	// earliest one in document order, not whichever subtree a reversed
	// depth-first walk would meet first.
	bad, berr := ts.parse("{\n  \"a\": @@,\n  \"b\": ##\n}\n", "json")
	testing.expectf(t, berr == "", "parse failed: %s", berr)
	if berr != "" {
		return
	}
	defer ts.parse_release(&bad)
	testing.expect_value(t, ts.structure_error_row(ts.parse_root(&bad)), 1)
}

@(test)
structure_path_quoted_pipe_field :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	source := "{\"odd|key\": {\"x\": 1}}"
	pr, perr := ts.parse(source, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)

	// A bar inside a quoted field is field text, not the keys operator.
	res, err := ts.structure_resolve_path(root, source, ".\"odd|key\"", 0, a)
	testing.expectf(t, err == "", "quoted pipe: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Value)
	testing.expectf(t, res.content == "{\"x\": 1}", "quoted pipe content: %s", res.content)

	// The operator is still detected after a quoted field containing one.
	res, err = ts.structure_resolve_path(root, source, ".\"odd|key\"|keys", 0, a)
	testing.expectf(t, err == "", "keys after quoted pipe: %s", err)
	testing.expect_value(t, res.kind, ts.Structure_Path_Kind.Keys)
	testing.expectf(t, res.content == "x (L0)\n", "keys content: %s", res.content)

	// A trailing bare bar is rejected, not folded into the field name.
	_, err = ts.structure_resolve_path(root, source, ".odd|", 0, a)
	testing.expectf(t, strings.contains(err, "dangling '|'"), "dangling bar: %s", err)
}

@(test)
ts_regex_predicates_ride_the_build_allocator :: proc(t: ^testing.T) {
	// A regex predicate's boxed Regex is allocated on the builder's `a`
	// and outlives the building call (outliners hold their predicates for
	// the daemon's life while the building thread's scratch resets after
	// the request): the compile must ride `a` too, or the predicate reads
	// freed memory on the next match. The scribble makes that visible.
	toks := []ts.Pred_Token{
		{is_capture = true, text = "@name"},
		{text = "^main$"},
	}
	p, perr := ts.build_regex_predicate(toks, .Match, "match?", context.allocator)
	testing.expectf(t, perr == "", "predicate builds: %s", perr)
	if perr != "" {
		return
	}
	// The boxed Regex and its pcre2 internals ride context.allocator (the
	// build's `a`); release both through the same owner.
	defer {
		regex.regex_destroy(p.regex)
		free(p.regex, context.allocator)
	}

	mem.free_all(context.temp_allocator)
	noise := make([]u8, 1 << 20, context.temp_allocator)
	for i in 0..<len(noise) {
		noise[i] = 0xAA
	}

	testing.expect(t, regex.regex_match(p.regex, "main"), "predicate matches after the scratch reset")
	testing.expect(t, !regex.regex_match(p.regex, "other"))

	delete(noise, context.temp_allocator)
}

@(test)
structure_path_index_overflow_rejected :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	src := `["zero","one"]`
	pr, perr := ts.parse(src, "json")
	testing.expectf(t, perr == "", "parse failed: %s", perr)
	if perr != "" {
		return
	}
	defer ts.parse_release(&pr)
	root := ts.parse_root(&pr)

	// 2^64+1 wraps to 1 without the guard and silently resolves "one";
	// it must be rejected as a path instead. Plain [1] keeps resolving.
	_, oerr := ts.structure_resolve_path(root, src, ".[18446744073709551617]", 4096, a)
	testing.expect(t, oerr != "", "overflowing index must be an error, not a wrapped item")
	_, perr1 := ts.structure_resolve_path(root, src, ".[1]", 4096, a)
	testing.expect(t, perr1 == "", "plain [1] still resolves")
}

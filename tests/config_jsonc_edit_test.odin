// Tests for src/config/jsonc_edit.odin: format-preserving member insertion
// into JSONC client configs. Goldens are exact-byte — a byte drift means an
// editing regression (comment loss, indent change, stray comma).
package tests

import "core:strings"
import "core:testing"
import "src:config"

jsonc_of :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

@(test)
jsonc_edit_insert_preserves_comments_and_format :: proc(t: ^testing.T) {
	src := jsonc_of(
		"{\n" +
		"  // main settings\n" +
		"  \"model\": \"gpt\",\n" +
		"  \"mcp\": {\n" +
		"    \"servers\": {\n" +
		"      \"other\": {\"type\": \"stdio\"}\n" +
		"    }\n" +
		"  }\n" +
		"}\n",
	)
	entry := "{\"type\": \"stdio\"}"
	out, action, ok := config.edit_upsert_member(src, {"mcp", "servers"}, "aubade", entry, context.temp_allocator)
	testing.expect(t, ok, "edit must succeed")
	testing.expect_value(t, action, config.Edit_Action.Inserted)
	expected :=
		"{\n" +
		"  // main settings\n" +
		"  \"model\": \"gpt\",\n" +
		"  \"mcp\": {\n" +
		"    \"servers\": {\n" +
		"      \"other\": {\"type\": \"stdio\"},\n" +
		"      \"aubade\": {\"type\": \"stdio\"}\n" +
		"    }\n" +
		"  }\n" +
		"}\n"
	testing.expect_value(t, string(out), expected)

	// Idempotent: re-running finds an equal member and leaves the bytes alone.
	out2, action2, ok2 := config.edit_upsert_member(out, {"mcp", "servers"}, "aubade", entry, context.temp_allocator)
	testing.expect(t, ok2, "second edit must succeed")
	testing.expect_value(t, action2, config.Edit_Action.Unchanged)
	testing.expect_value(t, string(out2), expected)
}

@(test)
jsonc_edit_ensure_creates_nested_objects :: proc(t: ^testing.T) {
	out, obj_off, changed, ok := config.edit_ensure_object(jsonc_of("{}"), {"mcp", "servers"}, context.temp_allocator)
	testing.expect(t, ok, "ensure must succeed")
	testing.expect(t, changed, "ensure must create the path")
	expected :=
		"{\n" +
		"    \"mcp\": {\n" +
		"        \"servers\": {}\n" +
		"    }\n" +
		"}"
	testing.expect_value(t, string(out), expected)
	testing.expect(t, obj_off > 0, "final object offset must be returned")

	// The returned offset points at the innermost '{'.
	info, iok := config.object_info(out, obj_off, context.temp_allocator)
	testing.expect(t, iok)
	testing.expect_value(t, len(info.members), 0)
}

@(test)
jsonc_edit_insert_into_compact_root :: proc(t: ^testing.T) {
	out, action, ok := config.edit_upsert_member(jsonc_of("{}"), {}, "mcp", "{}", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, action, config.Edit_Action.Inserted)
	testing.expect(t, string(out) == "{\n    \"mcp\": {}\n}")
}

@(test)
jsonc_edit_insert_into_compact_members :: proc(t: ^testing.T) {
	out, action, ok := config.edit_upsert_member(jsonc_of("{\"a\":1}"), {}, "b", "2", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, action, config.Edit_Action.Inserted)
	testing.expect(t, string(out) == "{\"a\":1,\n    \"b\": 2\n}")
}

@(test)
jsonc_edit_trailing_comma_source_tolerated :: proc(t: ^testing.T) {
	src := jsonc_of("{\n  \"a\": 1,\n}\n")
	out, action, ok := config.edit_upsert_member(src, {}, "b", "2", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, action, config.Edit_Action.Inserted)
	// The source's trailing comma is reused as the separator for the new
	// member — the output stays plain-JSON clean.
	testing.expect(t, string(out) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
}

@(test)
jsonc_edit_block_comment_and_strings :: proc(t: ^testing.T) {
	// '}' inside a string and a block comment must not confuse the scanner.
	src := jsonc_of("{ /* } */ \"cmd\": \"a//b\\\"c}d\", \"mcp\": {} }")
	out, _, ok := config.edit_upsert_member(src, {"mcp"}, "aubade", "{}", context.temp_allocator)
	testing.expect(t, ok)
	root, iok := config.object_info(out, config.skip_blank(out, 0), context.temp_allocator)
	testing.expect(t, iok)
	testing.expect_value(t, len(root.members), 2)
	testing.expect_value(t, root.members[0].name, "cmd")
	cmd := string(out[root.members[0].value_start:root.members[0].value_end])
	testing.expect_value(t, cmd, "\"a//b\\\"c}d\"")
	// The aubade member landed inside the mcp object.
	testing.expect_value(t, root.members[1].name, "mcp")
	mcp_info, mok := config.object_info(out, root.members[1].value_start, context.temp_allocator)
	testing.expect(t, mok)
	testing.expect_value(t, len(mcp_info.members), 1)
	testing.expect_value(t, mcp_info.members[0].name, "aubade")
}

@(test)
jsonc_edit_detect_indent_variants :: proc(t: ^testing.T) {
	testing.expect(t, config.detect_indent(jsonc_of("{\n  \"a\": 1}")) == "  ")
	testing.expect(t, config.detect_indent(jsonc_of("{\n\t\"a\": 1}")) == "\t")
	testing.expect(t, config.detect_indent(jsonc_of("{}")) == "    ")
	// A blank line before the first member is not an indent sample.
	testing.expect(t, config.detect_indent(jsonc_of("{\n\n  \"a\": 1}")) == "  ")
}

@(test)
jsonc_edit_rejects_malformed :: proc(t: ^testing.T) {
	// Unterminated object: match_bracket fails, ensure reports !ok.
	_, _, _, ok := config.edit_ensure_object(jsonc_of("{\"a\": "), {"a"}, context.temp_allocator)
	testing.expect(t, !ok)
	// Non-object path element.
	_, _, ok2 := config.edit_upsert_member(jsonc_of("{\"a\": 1}"), {"a"}, "b", "2", context.temp_allocator)
	testing.expect(t, !ok2)
	// Root is not an object.
	_, _, ok3 := config.edit_upsert_member(jsonc_of("[1, 2]"), {}, "b", "2", context.temp_allocator)
	testing.expect(t, !ok3)
}

@(test)
jsonc_edit_render_helpers :: proc(t: ^testing.T) {
	arr := config.render_inline_array({"mcp", "--context=zcode"}, context.temp_allocator)
	testing.expect_value(t, arr, "[\"mcp\", \"--context=zcode\"]")

	obj := config.render_multiline_object(
		{"\"type\": \"stdio\"", "\"command\": \"/bin/x\""},
		"        ", "      ", "\n", context.temp_allocator,
	)
	testing.expect_value(
		t, obj,
		"{\n        \"type\": \"stdio\",\n        \"command\": \"/bin/x\"\n      }",
	)

	// A CRLF separator renders through the whole block.
	obj_crlf := config.render_multiline_object(
		{"\"type\": \"stdio\"", "\"command\": \"/bin/x\""},
		"        ", "      ", "\r\n", context.temp_allocator,
	)
	testing.expect_value(
		t, obj_crlf,
		"{\r\n        \"type\": \"stdio\",\r\n        \"command\": \"/bin/x\"\r\n      }",
	)
}

@(test)
jsonc_edit_crlf_file_gets_crlf_member :: proc(t: ^testing.T) {
	// Inserts adopt the file's dominant newline: a CRLF config gains
	// CRLF members, never mixed endings (Windows editors save CRLF).
	src := jsonc_of("{\r\n  \"mcp\": {\r\n  }\r\n}")
	out, action, ok := config.edit_upsert_member(src, {"mcp"}, "aubade", "{}", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, action, config.Edit_Action.Inserted)
	expected :=
		"{\r\n" +
		"  \"mcp\": {\r\n" +
		"    \"aubade\": {}\r\n" +
		"  }\r\n" +
		"}"
	testing.expect_value(t, string(out), expected)
	// No bare LF anywhere: every newline is part of a CRLF pair.
	for i := 0; i < len(out); i += 1 {
		if out[i] == '\n' {
			testing.expectf(t, i > 0 && out[i - 1] == '\r', "bare LF at %d in %q", i, string(out))
		}
	}
}

@(test)
jsonc_edit_two_space_file_gets_two_space_member :: proc(t: ^testing.T) {
	src := jsonc_of("{\n  \"mcp\": {\n    \"servers\": {\n    }\n  }\n}")
	out, action, ok := config.edit_upsert_member(src, {"mcp", "servers"}, "aubade", "{}", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, action, config.Edit_Action.Inserted)
	// The unit is detected from the file: the member lands at three units
	// and the closing braces keep their original lines.
	expected :=
		"{\n" +
		"  \"mcp\": {\n" +
		"    \"servers\": {\n" +
		"      \"aubade\": {}\n" +
		"    }\n" +
		"  }\n" +
		"}"
	testing.expect_value(t, string(out), expected)
}

@(test)
jsonc_edit_upsert_replaces_stale_member :: proc(t: ^testing.T) {
	src := jsonc_of(
		"{\n" +
		"  \"theme\": \"dark\",\n" +
		"  \"mcp\": {\n" +
		"    \"aubade\": {\n" +
		"      \"type\": \"local\",\n" +
		"      \"command\": [\"/nowhere/aubade\", \"mcp\"]\n" +
		"    }\n" +
		"  }\n" +
		"}\n",
	)
	entry := "{\n      \"type\": \"local\",\n      \"command\": [\"/nowhere/aubade\", \"mcp\", \"--project-from-cwd\"]\n    }"
	out, action, ok := config.edit_upsert_member(src, {"mcp"}, "aubade", entry, context.temp_allocator)
	testing.expect(t, ok, "upsert must succeed")
	testing.expect(t, action == .Replaced, "stale member must be replaced")
	testing.expect(t, strings.contains(string(out), "--project-from-cwd"), "replacement must carry the new value")
	testing.expect(t, strings.contains(string(out), "\"theme\": \"dark\""), "sibling members survive the splice")
	value, perr := config.jsonc_parse(out, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "result must stay valid JSON")
}

@(test)
jsonc_edit_upsert_inserts_when_absent :: proc(t: ^testing.T) {
	src := jsonc_of("{\n  \"mcp\": {\n  }\n}")
	entry := "{\"type\": \"local\"}"
	out, action, ok := config.edit_upsert_member(src, {"mcp"}, "aubade", entry, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, action == .Inserted, "absent member must be inserted")
	testing.expect(t, strings.contains(string(out), "\"aubade\""))
}

@(test)
jsonc_edit_upsert_unchanged_on_semantic_equality :: proc(t: ^testing.T) {
	// The same registration rendered with different spacing and member
	// order: semantically equal, so the file must stay byte-identical.
	src := jsonc_of("{\n  \"mcp\": {\n    \"aubade\": {\"command\": [\"b\", \"mcp\", \"--project-from-cwd\"], \"type\": \"local\"}\n  }\n}")
	entry := "{\n      \"type\": \"local\",\n      \"command\": [\"b\", \"mcp\", \"--project-from-cwd\"]\n    }"
	out, action, ok := config.edit_upsert_member(src, {"mcp"}, "aubade", entry, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, action == .Unchanged, "equal member must stay untouched")
	testing.expect_value(t, string(out), string(src))
}

@(test)
jsonc_edit_remove_middle_last_and_only_members :: proc(t: ^testing.T) {
	src := jsonc_of(
		"{\n" +
		"  // the model\n" +
		"  \"model\": \"gpt\",\n" +
		"  \"theme\": \"dark\",\n" +
		"  \"verbose\": true\n" +
		"}\n",
	)
	// middle member: its whole line (indent + trailing newline) collapses
	out, removed, ok := config.edit_remove_member(src, {}, "theme", context.temp_allocator)
	testing.expect(t, ok, "remove must succeed")
	testing.expect(t, removed, "present member must be removed")
	expected :=
		"{\n" +
		"  // the model\n" +
		"  \"model\": \"gpt\",\n" +
		"  \"verbose\": true\n" +
		"}\n"
	testing.expect_value(t, string(out), expected)

	// last member: the preceding comma goes with it, the closing brace
	// keeps its own line
	out2, removed2, ok2 := config.edit_remove_member(out, {}, "verbose", context.temp_allocator)
	testing.expect(t, ok2 && removed2)
	expected2 :=
		"{\n" +
		"  // the model\n" +
		"  \"model\": \"gpt\"\n" +
		"}\n"
	testing.expect_value(t, string(out2), expected2)

	// only member: the object empties cleanly (the file's trailing
	// newline after the closing brace survives)
	out3, removed3, ok3 := config.edit_remove_member(out2, {}, "model", context.temp_allocator)
	testing.expect(t, ok3 && removed3)
	testing.expect_value(t, string(out3), "{\n}\n")
}

@(test)
jsonc_edit_remove_keeps_comments_and_siblings :: proc(t: ^testing.T) {
	src := jsonc_of(
		"{\n" +
		"  // languages\n" +
		"  \"language_servers\": [{\"name\": \"odin\"}],\n" +
		"  // options per language\n" +
		"  \"language_server_options\": {\n" +
		"    \"odin\": {\"collections\": []},\n" +
		"    \"go\": {\"verbose\": true}\n" +
		"  }\n" +
		"}\n",
	)
	// nested member removal through a path
	out, removed, ok := config.edit_remove_member(src, {"language_server_options"}, "odin", context.temp_allocator)
	testing.expect(t, ok && removed)
	expected :=
		"{\n" +
		"  // languages\n" +
		"  \"language_servers\": [{\"name\": \"odin\"}],\n" +
		"  // options per language\n" +
		"  \"language_server_options\": {\n" +
		"    \"go\": {\"verbose\": true}\n" +
		"  }\n" +
		"}\n"
	testing.expect_value(t, string(out), expected)
	value, perr := config.jsonc_parse(out, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "result must stay valid JSON")
}

@(test)
jsonc_edit_remove_noops_and_failures :: proc(t: ^testing.T) {
	src := jsonc_of("{\n  \"a\": 1\n}")
	// absent name: unchanged, still ok
	out, removed, ok := config.edit_remove_member(src, {}, "missing", context.temp_allocator)
	testing.expect(t, ok, "absent member is a no-op, not a failure")
	testing.expect(t, !removed)
	testing.expect_value(t, string(out), string(src))
	// absent path object: unchanged, still ok (a removal never creates)
	out2, removed2, ok2 := config.edit_remove_member(src, {"nope"}, "a", context.temp_allocator)
	testing.expect(t, ok2 && !removed2)
	testing.expect_value(t, string(out2), string(src))
	// non-object path member: failure without touching anything
	nested := jsonc_of("{\n  \"list\": [1]\n}")
	out3, removed3, ok3 := config.edit_remove_member(nested, {"list"}, "x", context.temp_allocator)
	testing.expect(t, !ok3 && !removed3)
	testing.expect_value(t, string(out3), string(nested))
	// a trailing comment on the value's line goes with the member
	commented := jsonc_of("{\n  \"a\": 1, // trailing\n  \"b\": 2\n}")
	out4, removed4, ok4 := config.edit_remove_member(commented, {}, "a", context.temp_allocator)
	testing.expect(t, ok4 && removed4)
	testing.expect(t, !strings.contains(string(out4), "// trailing"), "the member's own comment must go with it")
	testing.expect(t, strings.contains(string(out4), "\"b\": 2"), "the sibling must survive")
	value, perr := config.jsonc_parse(out4, context.temp_allocator)
	testing.expect(t, perr == nil && value != nil, "result must stay valid JSON")
}

@(test)
jsonc_edit_remove_inline_members :: proc(t: ^testing.T) {
	src := jsonc_of("{\"a\": 1, \"b\": 2}")
	out, removed, ok := config.edit_remove_member(src, {}, "a", context.temp_allocator)
	testing.expect(t, ok && removed)
	testing.expect_value(t, string(out), "{ \"b\": 2}")
	out2, removed2, ok2 := config.edit_remove_member(src, {}, "b", context.temp_allocator)
	testing.expect(t, ok2 && removed2)
	testing.expect_value(t, string(out2), "{\"a\": 1}")
}

// Tests for the symbol_find_dead_code path: real daemon pair, real
// grammars, synthetic project files. The core contract under test is
// directionality — anything textual (call, comment, prose, unsaved
// buffer) keeps a name alive, and only names with zero occurrences
// outside their own declaration spans are reported.
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:jsonutil"
import "src:util"

// dead_run scans through the pair's daemon and parses the answer JSON
// back (temp allocator); on a tool error it returns the error text.
dead_run :: proc(t: ^testing.T, pair: ^Daemon_Pair, args_json: string, a: mem.Allocator) -> (v: json.Value, err_text: string) {
	out, is_err := tool_run(t, pair, "symbol_find_dead_code", args_json, a)
	if is_err {
		return nil, out
	}
	return parse_obj(out), ""
}

// dead_names extracts the candidate names in report order.
dead_names :: proc(v: json.Value, a: mem.Allocator) -> []string {
	names := make([dynamic]string, 0, 8, a)
	candidates_v, ok := jsonutil.obj_get(v, "candidates")
	if !ok {
		return names[:]
	}
	candidates, _ := jsonutil.as_array(candidates_v)
	for c in candidates {
		name_v, _ := jsonutil.obj_get(c, "name")
		append(&names, jsonutil.value_str(name_v))
	}
	return names[:]
}

dead_has :: proc(names: []string, name: string) -> bool {
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}

// dead_field_i64 reads one integer field of the candidate with the given
// name (line, or -1 when absent).
dead_field_i64 :: proc(v: json.Value, name: string, field: string) -> i64 {
	candidates_v, ok := jsonutil.obj_get(v, "candidates")
	if !ok {
		return -1
	}
	candidates, _ := jsonutil.as_array(candidates_v)
	for c in candidates {
		name_v, _ := jsonutil.obj_get(c, "name")
		if jsonutil.value_str(name_v) != name {
			continue
		}
		field_v, found := jsonutil.obj_get(c, field)
		if !found {
			return -1
		}
		#partial switch x in field_v {
		case json.Integer:
			return i64(x)
		case:
			return -1
		}
	}
	return -1
}

dead_stat_i64 :: proc(v: json.Value, field: string) -> i64 {
	stats_v, ok := jsonutil.obj_get(v, "stats")
	if !ok {
		return -1
	}
	field_v, found := jsonutil.obj_get(stats_v, field)
	if !found {
		return -1
	}
	#partial switch x in field_v {
	case json.Integer:
		return i64(x)
	case:
		return -1
	}
	return -1
}

dead_stat_bool :: proc(v: json.Value, field: string) -> bool {
	stats_v, ok := jsonutil.obj_get(v, "stats")
	if !ok {
		return false
	}
	field_v, found := jsonutil.obj_get(stats_v, field)
	if !found {
		return false
	}
	#partial switch x in field_v {
	case json.Boolean:
		return bool(x)
	case:
		return false
	}
	return false
}

dead_field_str :: proc(v: json.Value, name: string, field: string) -> string {
	candidates_v, ok := jsonutil.obj_get(v, "candidates")
	if !ok {
		return ""
	}
	candidates, _ := jsonutil.as_array(candidates_v)
	for c in candidates {
		name_v, _ := jsonutil.obj_get(c, "name")
		if jsonutil.value_str(name_v) != name {
			continue
		}
		field_v, found := jsonutil.obj_get(c, field)
		if !found {
			return ""
		}
		return jsonutil.value_str(field_v)
	}
	return ""
}

@(test)
dead_scan_bom_and_crlf :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// A BOM-prefixed, CRLF-line-ended file: the disk read must present
	// the same view the editor's buffer would (BOM stripped, \r\n pairs
	// folded), so spans, rows, and tokens all align.
	svc_symbol_write_file(t, pair.tmp, "crlf.go", "\xEF\xBB\xBF" +
		"package crlf\r\n" +
		"\r\n" +
		"func crlf_unused() int { return 1 }\r\n" +
		"\r\n" +
		"func crlf_used() int { return 2 }\r\n")
	svc_symbol_write_file(t, pair.tmp, "caller.go", "package caller\n\nfunc Call() int { return crlf_used() }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names := dead_names(v, a)
	testing.expectf(t, dead_has(names, "crlf_unused"), "BOM+CRLF unused name missing: %v", names)
	testing.expectf(t, !dead_has(names, "crlf_used"), "BOM+CRLF used name reported: %v", names)
	// Rows count logical lines: package(0), blank(1), crlf_unused(2).
	testing.expect(t, dead_field_i64(v, "crlf_unused", "line") == 2)
}

@(test)
dead_scan_core_semantics :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "main.go", "package main\n" +
		"\n" +
		"func main() { kept_by_call() }\n" +
		"\n" +
		"func kept_by_call() int { return 1 }\n" +
		"\n" +
		"func lonely_one() int { return 2 }\n" +
		"\n" +
		"func documented_only() int { return 3 }\n" +
		"\n" +
		"func comment_kept() int { return 5 }\n" +
		"\n" +
		"func string_kept() int { return 6 }\n" +
		"\n" +
		"type Widget struct{}\n" +
		"\n" +
		"func (w Widget) Orphan_method() int { return 4 }\n")
	svc_symbol_write_file(t, pair.tmp, "notes.md", "documented_only stays alive because this prose mentions documented_only.\n")
	svc_symbol_write_file(t, pair.tmp, "extra.go", "package extra\n" +
		"\n" +
		"// comment_kept stays documented in this comment.\n" +
		"var anchor = \"string_kept appears in this literal\"\n" +
		"\n" +
		"func extra_kept() int { return 0 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names := dead_names(v, a)
	// Zero occurrences: reported.
	testing.expectf(t, dead_has(names, "lonely_one"), "lonely_one missing from %v", names)
	testing.expectf(t, dead_has(names, "Orphan_method"), "Orphan_method missing from %v", names)
	// A call keeps alive.
	testing.expectf(t, !dead_has(names, "kept_by_call"), "called name reported: %v", names)
	// Prose (non-source file), a source comment, and a string literal all
	// count as uses.
	testing.expectf(t, !dead_has(names, "documented_only"), "prose-mentioned name reported: %v", names)
	testing.expectf(t, !dead_has(names, "comment_kept"), "comment-mentioned name reported: %v", names)
	testing.expectf(t, !dead_has(names, "string_kept"), "string-mentioned name reported: %v", names)
	// Convention entry point.
	testing.expectf(t, !dead_has(names, "main"), "entry-point name reported: %v", names)

	// 0-based line: lonely_one sits on row 6 of main.go.
	testing.expect(t, dead_field_i64(v, "lonely_one", "line") == 6)
	// The method's name path carries the receiver type.
	testing.expect_value(t, dead_field_str(v, "Orphan_method", "name_path"), "Widget/Orphan_method")

	// Stats are whole-population and untruncated at this size.
	testing.expect(t, dead_stat_i64(v, "files_scanned") >= 3)
	testing.expect(t, dead_stat_i64(v, "definitions") >= 8)
	testing.expect(t, !dead_stat_bool(v, "truncated"))
	testing.expect(t, !dead_stat_bool(v, "walk_truncated"))
}

@(test)
dead_scan_attribute_and_entry_prefixes :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "guard.odin", "package guard\n" +
		"\n" +
		"@(test)\n" +
		"guarded_probe :: proc() {}\n" +
		"\n" +
		"plain_probe :: proc() {}\n")
	svc_symbol_write_file(t, pair.tmp, "prefix.go", "package prefix\n" +
		"\n" +
		"func test_something() int { return 1 }\n" +
		"\n" +
		"func zig_only() int { return 2 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Defaults: the attribute-guarded Odin proc and the test_ prefix are
	// excluded; the unguarded, unprefixed names are candidates.
	v, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names := dead_names(v, a)
	testing.expectf(t, !dead_has(names, "guarded_probe"), "attribute-guarded name reported: %v", names)
	testing.expectf(t, dead_has(names, "plain_probe"), "plain_probe missing from %v", names)
	testing.expectf(t, !dead_has(names, "test_something"), "entry-prefixed name reported: %v", names)
	testing.expectf(t, dead_has(names, "zig_only"), "zig_only missing from %v", names)

	// entry_prefixes replaces the defaults wholesale.
	v2, err_text2 := dead_run(t, pair, `{"entry_prefixes": ["zig_"]}`, a)
	testing.expectf(t, err_text2 == "", "tool error: %s", err_text2)
	if err_text2 != "" {
		return
	}
	names2 := dead_names(v2, a)
	testing.expectf(t, dead_has(names2, "test_something"), "replaced-away prefix name missing: %v", names2)
	testing.expectf(t, !dead_has(names2, "zig_only"), "replacement prefix name reported: %v", names2)
}

@(test)
dead_scan_path_prefix_report_only :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// Uses cross the prefix boundary in both directions: root.go calls
	// sub_helper (a sub/ definition), sub/caller.go calls root_helper
	// (a root definition).
	svc_symbol_write_file(t, pair.tmp, "root.go", "package root\n" +
		"\n" +
		"func root_unused() int { return 1 }\n" +
		"\n" +
		"func root_helper() int { return 8 }\n" +
		"\n" +
		"func RootCall() int { return sub_helper() }\n")
	svc_symbol_write_file(t, pair.tmp, "sub/caller.go", "package sub\n\nfunc SubCall() int { return root_helper() }\n")
	svc_symbol_write_file(t, pair.tmp, "sub/helper.go", "package sub\n\nfunc sub_helper() int { return 7 }\n")
	svc_symbol_write_file(t, pair.tmp, "sub/unused.go", "package sub\n\nfunc sub_unused() int { return 9 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Unfiltered: both unused names reported, both cross-direction uses
	// counted.
	v, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names := dead_names(v, a)
	testing.expectf(t, dead_has(names, "root_unused"), "root_unused missing from %v", names)
	testing.expectf(t, dead_has(names, "sub_unused"), "sub_unused missing from %v", names)
	testing.expectf(t, !dead_has(names, "sub_helper"), "cross-direction use not counted: %v", names)
	testing.expectf(t, !dead_has(names, "root_helper"), "cross-direction use not counted: %v", names)

	// The prefix filters the report only: candidates outside sub/ drop
	// out, and sub_helper stays alive even though its only use lives
	// outside the prefix — the use pass is whole-project under a prefix.
	v2, err_text2 := dead_run(t, pair, `{"path_prefix": "sub"}`, a)
	testing.expectf(t, err_text2 == "", "tool error: %s", err_text2)
	if err_text2 != "" {
		return
	}
	names2 := dead_names(v2, a)
	testing.expectf(t, dead_has(names2, "sub_unused"), "sub_unused missing under prefix: %v", names2)
	testing.expectf(t, !dead_has(names2, "root_unused"), "out-of-prefix candidate reported: %v", names2)
	testing.expectf(t, !dead_has(names2, "sub_helper"), "prefix-scoped use pass reported a used name: %v", names2)
	testing.expectf(t, !dead_has(names2, "root_helper"), "out-of-prefix used name reported: %v", names2)
}

@(test)
dead_scan_same_name_mutual_alive :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "one.go", "package one\n\nfunc dup_twin() int { return 1 }\n")
	svc_symbol_write_file(t, pair.tmp, "two.go", "package two\n\nfunc dup_twin() int { return 2 }\n\nfunc calls_twin() int { return dup_twin() }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// By design (precision over recall): same-name definitions keep each
	// other alive — one textual use of the name counts for every
	// definition carrying it.
	v, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names := dead_names(v, a)
	testing.expectf(t, !dead_has(names, "dup_twin"), "same-name definition reported: %v", names)
	// calls_twin itself is uncalled and IS reported — the mutual-alive
	// rule covers the shared name only, not the caller.
	testing.expectf(t, dead_has(names, "calls_twin"), "uncalled caller missing from %v", names)
}

@(test)
dead_scan_unicode_names :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "uni.go", "package uni\n" +
		"\n" +
		"func Ωlonely() int { return 1 }\n" +
		"\n" +
		"func Ωkept() int { return 2 }\n")
	svc_symbol_write_file(t, pair.tmp, "doc.txt", "Ωkept is used here.\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names := dead_names(v, a)
	testing.expectf(t, dead_has(names, "Ωlonely"), "unicode unused name missing: %v", names)
	testing.expectf(t, !dead_has(names, "Ωkept"), "unicode used name reported: %v", names)
}

@(test)
dead_scan_limit_and_stats :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "l1.go", "package l1\n\nfunc l1_unused_a() int { return 1 }\n\nfunc l1_unused_b() int { return 2 }\n")
	svc_symbol_write_file(t, pair.tmp, "l2.go", "package l2\n\nfunc l2_unused_c() int { return 3 }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := dead_run(t, pair, `{"limit": 1}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	// The list truncates; the stats stay whole-population.
	testing.expect(t, dead_stat_i64(v, "candidates_total") == 3)
	testing.expect(t, dead_stat_bool(v, "truncated"))
	candidates_v, ok := jsonutil.obj_get(v, "candidates")
	testing.expect(t, ok)
	if ok {
		candidates, _ := jsonutil.as_array(candidates_v)
		testing.expect(t, len(candidates) == 1)
	}
	// Sorted by path then line: the first file's first unused name.
	names := dead_names(v, a)
	testing.expect(t, len(names) == 1 && names[0] == "l1_unused_a")
}

@(test)
dead_scan_invalid_params :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Range validation fires at the call site.
	_, err_text := dead_run(t, pair, `{"limit": 0}`, a)
	testing.expectf(t, err_text != "" && strings.contains(err_text, "limit must be between 1 and 1000"), "limit 0 accepted: %s", err_text)
	_, err_text = dead_run(t, pair, `{"limit": 1001}`, a)
	testing.expectf(t, err_text != "" && strings.contains(err_text, "limit must be between 1 and 1000"), "limit 1001 accepted: %s", err_text)

	// Wire-level validation surfaces with the daemon's code woven in.
	_, err_text = dead_run(t, pair, `{"entry_prefixes": [""]}`, a)
	testing.expectf(t, err_text != "" && strings.contains(err_text, "entry_prefixes"), "empty entry prefix accepted: %s", err_text)
	_, err_text = dead_run(t, pair, `{"path_prefix": "/etc"}`, a)
	testing.expectf(t, err_text != "" && strings.contains(err_text, "project-relative"), "absolute path_prefix accepted: %s", err_text)
	_, err_text = dead_run(t, pair, `{"path_prefix": "../x"}`, a)
	testing.expectf(t, err_text != "" && strings.contains(err_text, ".."), "escaping path_prefix accepted: %s", err_text)
}

@(test)
dead_scan_repeat_call_identical :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// The scan resolves trees through the L2 hot cache: the second call
	// borrows cached trees instead of parsing. Its answer must be
	// byte-for-byte the same verdicts as the first call's.
	svc_symbol_write_file(t, pair.tmp, "one.go", "package one\n\nfunc one_unused() int { return 1 }\n\nfunc one_kept() int { return 2 }\n")
	svc_symbol_write_file(t, pair.tmp, "two.go", "package two\n\nfunc two_unused() int { return one_kept() }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v1, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "first tool error: %s", err_text)
	if err_text != "" {
		return
	}
	v2, err_text2 := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text2 == "", "second tool error: %s", err_text2)
	if err_text2 != "" {
		return
	}
	names1 := dead_names(v1, a)
	names2 := dead_names(v2, a)
	testing.expectf(t, dead_has(names1, "one_unused"), "one_unused missing: %v", names1)
	testing.expectf(t, dead_has(names1, "two_unused"), "two_unused missing: %v", names1)
	testing.expect(t, len(names1) == len(names2))
	for i in 0..<len(names1) {
		testing.expect_value(t, names2[i], names1[i])
	}
}

// dead_scan_parallel_many_files drives the scan past the scan pool's
// parallel threshold (SCAN_POOL_MIN_FILES): the definition and use passes
// run on spawned workers, and the merge must still assemble the walk-order
// answer. The chain wraps — file f00 uses a name defined in f01, and f29
// uses one defined in f00 — the forward-reference shape the two-pass
// order exists to keep correct.
@(test)
dead_scan_parallel_many_files :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	COUNT :: 30
	for i in 0..<COUNT {
		next := (i + 1) % COUNT
		// dead_N is itself the user of alive_next: one unused definition
		// and one used one per file (a `var _ =` reference would define
		// `_`, itself unused and rightly reported).
		content := strings.concatenate({
			"package p\n\nfunc dead_",
			util.int_to_dec(i, context.temp_allocator),
			"() int { return alive_",
			util.int_to_dec(next, context.temp_allocator),
			"() }\n\nfunc alive_",
			util.int_to_dec(i, context.temp_allocator),
			"() int { return 2 }\n",
		}, context.temp_allocator)
		name := strings.concatenate({"f", util.int_to_dec(i, context.temp_allocator), ".go"}, context.temp_allocator)
		svc_symbol_write_file(t, pair.tmp, name, content)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v1, err_text := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text == "", "first tool error: %s", err_text)
	if err_text != "" {
		return
	}
	names1 := dead_names(v1, a)
	testing.expectf(t, len(names1) == COUNT, "expected %d candidates, got %v", COUNT, names1)
	for i in 0..<COUNT {
		dead_name := strings.concatenate({"dead_", util.int_to_dec(i, context.temp_allocator)}, context.temp_allocator)
		alive_name := strings.concatenate({"alive_", util.int_to_dec(i, context.temp_allocator)}, context.temp_allocator)
		testing.expectf(t, dead_has(names1, dead_name), "%s missing: %v", dead_name, names1)
		testing.expectf(t, !dead_has(names1, alive_name), "%s reported: %v", alive_name, names1)
	}
	testing.expect_value(t, dead_stat_i64(v1, "files_parsed"), COUNT)
	testing.expect(t, dead_stat_i64(v1, "files_scanned") >= COUNT)

	// Repeat: the second call runs through the L2 hot cache on the same
	// workers — identical verdicts.
	v2, err_text2 := dead_run(t, pair, "{}", a)
	testing.expectf(t, err_text2 == "", "second tool error: %s", err_text2)
	if err_text2 != "" {
		return
	}
	names2 := dead_names(v2, a)
	testing.expect(t, len(names1) == len(names2))
	for i in 0..<len(names1) {
		testing.expect_value(t, names2[i], names1[i])
	}
}

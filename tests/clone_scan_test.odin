// Tests for the ast_find_duplicates path: real daemon pair, real
// grammars, synthetic project files. The core contract under test is
// exactness — identical structure reports as "exact" regardless of
// comments and formatting, consistently-renamed copy-paste reports as
// "renamed", a one-operator change or a non-injective rename reports
// nothing, and the same call always returns the same bytes.
//
// Fixture shape note: the per-file tails are structurally DIFFERENT (a
// one-liner return versus a guarded multi-statement body). Identical-shape
// tails would make whole files renamed clones of each other — a true
// finding, but one whose maximal-clone span swallows the fragment under
// test.
package tests

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "src:jsonutil"
import "src:util"

CLONE_WORKER_GO :: "func worker(queue chan int, budget int) int {\n" +
	"\ttotal := 0\n" +
	"\tfor i := 0; i < budget; i++ {\n" +
	"\t\tif i%2 == 0 {\n" +
	"\t\t\ttotal += i\n" +
	"\t\t\tqueue <- i\n" +
	"\t\t}\n" +
	"\t}\n" +
	"\treturn total\n" +
	"}\n"

// CLONE_MILL_GO is CLONE_WORKER_GO under a consistent bijective rename
// (worker->miller, queue->tasks, budget->limit, total->sum, i->j) with one
// literal value changed (2 -> 3): a Type-2 clone, never a Type-1 one.
CLONE_MILL_GO :: "func miller(tasks chan int, limit int) int {\n" +
	"\tsum := 0\n" +
	"\tfor j := 0; j < limit; j++ {\n" +
	"\t\tif j%3 == 0 {\n" +
	"\t\t\tsum += j\n" +
	"\t\t\ttasks <- j\n" +
	"\t\t}\n" +
	"\t}\n" +
	"\treturn sum\n" +
	"}\n"

// CLONE_TALLY_A and CLONE_TALLY_B differ by exactly one operator (+/-):
// every subtree of at least 10 named nodes contains the assignment, so
// nothing may report.
CLONE_TALLY_A :: "func tally(values []int, bias int) int {\n" +
	"\tsum := 0\n" +
	"\tfor _, v := range values {\n" +
	"\t\tsum = alpha + beta + bias\n" +
	"\t}\n" +
	"\treturn sum\n" +
	"}\n"

// CLONE_TALLY_COLLAPSED is CLONE_TALLY_A with beta collapsed into alpha —
// a non-injective merge, not a consistent renaming. As with the operator
// flip, every >=10-node subtree contains the assignment.
CLONE_TALLY_COLLAPSED :: "func tally(values []int, bias int) int {\n" +
	"\tsum := 0\n" +
	"\tfor _, v := range values {\n" +
	"\t\tsum = alpha + alpha + bias\n" +
	"\t}\n" +
	"\treturn sum\n" +
	"}\n"

// CLONE_TALLY_FLIPPED is CLONE_TALLY_A with one operator flipped
// (+ becomes -): the anonymous token feeds the hash, and every
// >=10-node subtree contains the assignment, so nothing may report.
CLONE_TALLY_FLIPPED :: "func tally(values []int, bias int) int {\n" +
	"\tsum := 0\n" +
	"\tfor _, v := range values {\n" +
	"\t\tsum = alpha - beta + bias\n" +
	"\t}\n" +
	"\treturn sum\n" +
	"}\n"

// CLONE_NOISY_GO is CLONE_WORKER_GO with comments sprinkled in and blank
// lines between statements — still a Type-1 clone.
CLONE_NOISY_GO :: "func worker(queue chan int, budget int) int { // walks the budget\n" +
	"\n" +
	"\ttotal := 0\n" +
	"\n" +
	"\t// every entry, even ones only\n" +
	"\tfor i := 0; i < budget; i++ {\n" +
	"\t\tif i%2 == 0 {\n" +
	"\t\t\t// keep\n" +
	"\t\t\ttotal += i\n" +
	"\t\t\tqueue <- i\n" +
	"\t\t}\n" +
	"\t}\n" +
	"\treturn total\n" +
	"}\n"

// CLONE_HELPER_GO is a second, structurally distinct duplicated body for
// the limit/stats test (smaller than the worker, so the worker group
// sorts first).
CLONE_HELPER_GO :: "func helper(data []int, factor int) int {\n" +
	"\tacc := 0\n" +
	"\tfor _, v := range data {\n" +
	"\t\tif v > factor {\n" +
	"\t\t\tacc += v\n" +
	"\t\t}\n" +
	"\t}\n" +
	"\treturn acc\n" +
	"}\n"

// CLONE_SMALL_GO sits far below the default floor of 50 named nodes.
CLONE_SMALL_GO :: "func tiny(seed int) int {\n" +
	"\tvalue := seed * 2\n" +
	"\treturn value + 1\n" +
	"}\n"

// CLONE_GRIND_ODIN is the Odin-side duplicate for the language-separation
// pin.
CLONE_GRIND_ODIN :: "package main\n" +
	"\n" +
	"grind :: proc() -> int {\n" +
	"\ttotal := 0\n" +
	"\tfor i in 0..<10 {\n" +
	"\t\tif i % 2 == 0 {\n" +
	"\t\t\ttotal += i\n" +
	"\t\t}\n" +
	"\t}\n" +
	"\treturn total\n" +
	"}\n"

// CLONE_BOM_PY is the duplicated body for the shebang-BOM regression: it
// lives in an extensionless file whose grammar resolves through the
// first-line read alone, so a UTF-8 BOM in front of the `#!` must be
// stripped before the interpreter check or the file stays invisible.
CLONE_BOM_PY :: "def tally(values, bias):\n" +
	"    total = 0\n" +
	"    for v in values:\n" +
	"        if v > bias:\n" +
	"            total = total + v\n" +
	"    return total\n"

// Structurally distinct per-file tails (see the fixture shape note).
CLONE_TAIL_A :: "func uniqueA() int { return 1 }\n"
CLONE_TAIL_B :: "func uniqueB(seed int) int {\n" +
	"\tif seed > 1 {\n" +
	"\t\treturn seed\n" +
	"\t}\n" +
	"\treturn 0\n" +
	"}\n"
CLONE_TAIL_C :: "func uniqueC(seed int) int {\n" +
	"\tif seed > 1 {\n" +
	"\t\treturn seed\n" +
	"\t}\n" +
	"\treturn 0\n" +
	"}\n"
CLONE_TAIL_D :: "func uniqueD() int { return 4 }\n"

// clone_run scans through the pair's daemon and parses the answer JSON
// back (temp allocator); on a tool error it returns the error text.
clone_run :: proc(t: ^testing.T, pair: ^Daemon_Pair, args_json: string, a: mem.Allocator) -> (v: json.Value, err_text: string) {
	out, is_err := tool_run(t, pair, "ast_find_duplicates", args_json, a)
	if is_err {
		return nil, out
	}
	return parse_obj(out), ""
}

clone_group_count :: proc(v: json.Value) -> int {
	groups_v, ok := jsonutil.obj_get(v, "groups")
	if !ok {
		return -1
	}
	groups, _ := jsonutil.as_array(groups_v)
	return len(groups)
}

clone_json_int :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer:
		return i64(x)
	case:
		return -1
	}
}

// clone_group_sum renders one group as "kind|path|path..." — the
// assertion handle for what grouped where.
clone_group_sum :: proc(v: json.Value, i: int, a: mem.Allocator) -> string {
	groups_v, ok := jsonutil.obj_get(v, "groups")
	if !ok {
		return ""
	}
	groups, _ := jsonutil.as_array(groups_v)
	if i < 0 || i >= len(groups) {
		return ""
	}
	kind_v, _ := jsonutil.obj_get(groups[i], "kind")
	pieces := make([dynamic]string, 0, 6, a)
	append(&pieces, jsonutil.value_str(kind_v))
	occ_v, _ := jsonutil.obj_get(groups[i], "occurrences")
	if occ, aok := jsonutil.as_array(occ_v); aok {
		for o in occ {
			p, _ := jsonutil.obj_get(o, "path")
			append(&pieces, "|")
			append(&pieces, jsonutil.value_str(p))
		}
	}
	return strings.concatenate(pieces[:], a)
}

// clone_group_first_line pins the first occurrence's start row.
clone_group_first_line :: proc(v: json.Value, i: int) -> i64 {
	groups_v, ok := jsonutil.obj_get(v, "groups")
	if !ok {
		return -1
	}
	groups, _ := jsonutil.as_array(groups_v)
	if i < 0 || i >= len(groups) {
		return -1
	}
	occ_v, _ := jsonutil.obj_get(groups[i], "occurrences")
	occ, aok := jsonutil.as_array(occ_v)
	if !aok || len(occ) == 0 {
		return -1
	}
	s, _ := jsonutil.obj_get(occ[0], "start_line")
	return clone_json_int(s)
}

// clone_mentions reports whether any group's occurrences include both of
// the two paths — the "these two files share a duplicate" predicate.
clone_mentions :: proc(v: json.Value, pa, pb: string) -> bool {
	groups_v, ok := jsonutil.obj_get(v, "groups")
	if !ok {
		return false
	}
	groups, _ := jsonutil.as_array(groups_v)
	for g in groups {
		occ_v, _ := jsonutil.obj_get(g, "occurrences")
		occ, aok := jsonutil.as_array(occ_v)
		if !aok {
			continue
		}
		has_a, has_b := false, false
		for o in occ {
			p, _ := jsonutil.obj_get(o, "path")
			path := jsonutil.value_str(p)
			if path == pa {
				has_a = true
			}
			if path == pb {
				has_b = true
			}
		}
		if has_a && has_b {
			return true
		}
	}
	return false
}

clone_stat :: proc(v: json.Value, field: string) -> i64 {
	stats_v, ok := jsonutil.obj_get(v, "stats")
	if !ok {
		return -1
	}
	f, _ := jsonutil.obj_get(stats_v, field)
	return clone_json_int(f)
}

clone_stat_bool :: proc(v: json.Value, field: string) -> bool {
	stats_v, ok := jsonutil.obj_get(v, "stats")
	if !ok {
		return false
	}
	f, found := jsonutil.obj_get(stats_v, field)
	if !found {
		return false
	}
	#partial switch x in f {
	case json.Boolean:
		return bool(x)
	case:
		return false
	}
}

@(test)
clone_scan_exact_cross_file :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	// Exactly one group: the worker function. Every shared inner block
	// (the for statement, the if body) nests inside the worker spans, so
	// maximal-clone suppression must have absorbed them.
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "exact|a.go|b.go")
	// 0-based rows: package(0), blank(1), worker starts on row 2.
	testing.expect(t, clone_group_first_line(v, 0) == 2)
	// Stats are whole-population and untruncated at this size.
	testing.expect(t, clone_stat(v, "files_scanned") >= 2)
	testing.expect(t, clone_stat(v, "files_parsed") >= 2)
	testing.expect(t, !clone_stat_bool(v, "truncated"))
	testing.expect(t, !clone_stat_bool(v, "walk_truncated"))
}

@(test)
clone_scan_renamed_consistent :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "c.go", "package main\n\n"+CLONE_MILL_GO+"\n"+CLONE_TAIL_C)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	// The renamed copy groups as kind "renamed" — and never as "exact"
	// (the identifier leaves differ).
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "renamed|a.go|c.go")
}

@(test)
clone_scan_renamed_non_injective :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// beta collapsed into alpha: two distinct identifiers merged into one
	// is not a consistent bijective renaming, so nothing reports.
	svc_symbol_write_file(t, pair.tmp, "p.go", "package main\n\n"+CLONE_TALLY_A+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "q.go", "package main\n\n"+CLONE_TALLY_COLLAPSED+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expectf(t, !clone_mentions(v, "p.go", "q.go"), "non-injective rename reported: %s", clone_group_sum(v, 0, a))
}

@(test)
clone_scan_comments_and_formatting :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// Same worker with comments sprinkled in and blank lines between
	// statements: still a Type-1 clone.
	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_NOISY_GO+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "exact|a.go|b.go")
}

@(test)
clone_scan_operator_change :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// One operator flipped (+ becomes -): the anonymous token feeds the
	// hash, and every >=10-node subtree contains the assignment, so the
	// bodies are not clones.
	svc_symbol_write_file(t, pair.tmp, "p.go", "package main\n\n"+CLONE_TALLY_A+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "q.go", "package main\n\n"+CLONE_TALLY_FLIPPED+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expectf(t, !clone_mentions(v, "p.go", "q.go"), "one-operator change reported as a clone")
}

@(test)
clone_scan_same_file :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// The same function twice in one file: a same-file duplicate is the
	// classic DRY finding.
	svc_symbol_write_file(t, pair.tmp, "pair.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "exact|pair.go|pair.go")
}

@(test)
clone_scan_min_nodes_floor :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// A small duplicated function sits far below the default floor of 50
	// named nodes: nothing reports.
	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_SMALL_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_SMALL_GO+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 50}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v), 0)
}

@(test)
clone_scan_deterministic_answer :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Same call twice: the raw answer text must be byte-identical —
	// map iteration order and walk order may never reach the report.
	out1, err1 := tool_run(t, pair, "ast_find_duplicates", `{"min_nodes": 10}`, a)
	out2, err2 := tool_run(t, pair, "ast_find_duplicates", `{"min_nodes": 10}`, a)
	testing.expectf(t, !err1 && !err2, "tool error: %s / %s", out1, out2)
	testing.expect_value(t, out1, out2)
}

@(test)
clone_scan_limit_and_stats :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// Two distinct duplicated bodies; limit=1 keeps the larger (the
	// worker) and marks the report truncated while stats stay
	// whole-population.
	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_HELPER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_HELPER_GO+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10, "limit": 1}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "exact|a.go|b.go")
	testing.expect(t, clone_stat(v, "groups_total") >= 2)
	testing.expect(t, clone_stat_bool(v, "truncated"))
}

@(test)
clone_scan_language_separation :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_B)
	svc_symbol_write_file(t, pair.tmp, "x.odin", CLONE_GRIND_ODIN+"\nalpha :: proc() {}\n")
	svc_symbol_write_file(t, pair.tmp, "y.odin", CLONE_GRIND_ODIN+"\nbeta :: proc(v: int) int { return v }\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	// Two groups — one per grammar. Buckets key on (language, hash), so
	// the Go pair and the Odin pair never merge.
	testing.expect_value(t, clone_group_count(v), 2)
	testing.expectf(t, clone_mentions(v, "x.odin", "y.odin"), "odin duplicate missing")
	testing.expectf(t, clone_mentions(v, "a.go", "b.go"), "go duplicate missing")
}

@(test)
clone_scan_path_prefix_report_only :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// The same body duplicated at the root and under sub/: path_prefix
	// narrows the report to the subtree's occurrences only.
	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_B)
	svc_symbol_write_file(t, pair.tmp, "sub/c.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_C)
	svc_symbol_write_file(t, pair.tmp, "sub/d.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_D)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10, "path_prefix": "sub"}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "exact|sub/c.go|sub/d.go")
}

@(test)
clone_scan_bom_shebang_script :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// An extensionless script carrying a UTF-8 BOM: its grammar resolves
	// only if the shebang read comes back BOM-stripped, and its two
	// identical bodies still report as an exact clone.
	svc_symbol_write_file(t, pair.tmp, "runner", "\xEF\xBB\xBF#!/usr/bin/env python3\n"+CLONE_BOM_PY+"\n"+CLONE_BOM_PY)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v), 1)
	testing.expect_value(t, clone_group_sum(v, 0, a), "exact|runner|runner")
}

@(test)
clone_scan_invalid_params :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	bad := []string{
		`{"path_prefix": "/abs"}`,
		`{"path_prefix": "../up"}`,
		`{"min_nodes": 5}`,
		`{"min_nodes": 100001}`,
		`{"limit": 0}`,
		`{"limit": 501}`,
		`{"min_nodes": "ten"}`,
	}
	for args in bad {
		out, is_err := tool_run(t, pair, "ast_find_duplicates", args, a)
		testing.expectf(t, is_err, "expected an error for %s, got: %s", args, out)
	}
}

@(test)
clone_scan_repeat_call_identical :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	// Repeat calls borrow cached trees from the L2 hot cache instead of
	// re-parsing; the report must come out identical.
	svc_symbol_write_file(t, pair.tmp, "a.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_A)
	svc_symbol_write_file(t, pair.tmp, "b.go", "package main\n\n"+CLONE_WORKER_GO+"\n"+CLONE_TAIL_B)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v1, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "first tool error: %s", err_text)
	if err_text != "" {
		return
	}
	v2, err_text2 := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text2 == "", "second tool error: %s", err_text2)
	if err_text2 != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v1), 1)
	testing.expect_value(t, clone_group_count(v2), 1)
	testing.expect_value(t, clone_group_sum(v2, 0, a), clone_group_sum(v1, 0, a))
}

// clone_scan_parallel_many_files drives the scan past the scan pool's
// parallel threshold (SCAN_POOL_MIN_FILES): the hash walk runs on spawned
// workers and the merge replays records and buckets in walk order. The
// worker duplicate spans files f10 and f20 — every other file is unique —
// so the answer must be exactly the one exact group.
@(test)
clone_scan_parallel_many_files :: proc(t: ^testing.T) {
	pair := test_daemon(t, false)
	if pair == nil {
		return
	}
	defer pair_shutdown(pair)

	COUNT :: 30
	for i in 0..<COUNT {
		suffix := strings.concatenate({"unique", util.int_to_dec(i, context.temp_allocator)}, context.temp_allocator)
		// Each filler body is structurally distinct (its statement count
		// is its index): same-shape fillers would form one renamed group
		// spanning every file — see the fixture note at the top of this
		// file.
		lines := make([dynamic]string, 0, 8, context.temp_allocator)
		append(&lines, "func ")
		append(&lines, suffix)
		append(&lines, "(seed int) int {\n\ttotal := seed\n")
		for _ in 0..<i {
			append(&lines, "\ttotal += 1\n")
		}
		append(&lines, "\treturn total\n}\n")
		filler := strings.concatenate(lines[:], context.temp_allocator)
		delete(lines)
		content := strings.concatenate({"package main\n\n", filler}, context.temp_allocator)
		if i == 10 || i == 20 {
			content = strings.concatenate({"package main\n\n", CLONE_WORKER_GO, filler}, context.temp_allocator)
		}
		name := strings.concatenate({"f", util.int_to_dec(i, context.temp_allocator), ".go"}, context.temp_allocator)
		svc_symbol_write_file(t, pair.tmp, name, content)
	}

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	v1, err_text := clone_run(t, pair, `{"min_nodes": 10}`, a)
	testing.expectf(t, err_text == "", "tool error: %s", err_text)
	if err_text != "" {
		return
	}
	testing.expect_value(t, clone_group_count(v1), 1)
	// Record order within a group is (path, start_byte) — deterministic
	// whatever worker produced the records.
	testing.expect_value(t, clone_group_sum(v1, 0, a), "exact|f10.go|f20.go")
	testing.expect(t, clone_stat(v1, "files_scanned") >= COUNT)
}

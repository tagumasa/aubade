// The symbol_find matching-rule contract end to end: exact by default
// (case-insensitive), `*` glob discovery, name-path chains verified
// against the indexed parent chain at any depth, the anchored form, and
// the rejection shapes. Drives the real daemon handler over the freshness
// fixture's minimal daemon (store db + editor + project root — no
// language servers, so the workspace/symbol top-up stays out of the
// picture; its filter has unit tests in symbol_match_test).
package tests

import "core:mem"
import "core:strings"
import "core:testing"
import "src:daemon"
import "src:jsonutil"
import "src:platform"
import "src:store"

semantics_seed :: proc(t: ^testing.T, f: ^Freshness_Fixture, path, hash: string, rows: []store.Symbol_Name_Row) {
	payload := [2]u8{1, 2}
	err := store.write_symbol_index(f.d.db, path, hash, "go", rows, payload[:], 1000)
	testing.expectf(t, err == nil, "seed %s: %v", path, err)
}

// semantics_find runs the handler for one pattern and reduces the answer
// to (match count, first match's path).
semantics_find :: proc(t: ^testing.T, f: ^Freshness_Fixture, pattern: string, a: mem.Allocator) -> (count: int, first_path: string, err: platform.Err) {
	ctx := freshness_ctx(f, a)
	body := strings.concatenate({`{"name": "`, pattern, `"}`}, a)
	result, ferr := daemon.handle_symbol_find(&ctx, freshness_params(body, a))
	if ferr != nil {
		return 0, "", ferr
	}
	matches, ok := jsonutil.obj_get(result, "matches")
	if !ok {
		return 0, "", nil
	}
	count = json_array_len(matches)
	if count > 0 {
		first_path, _ = json_str_field(json_array_at(matches, 0), "path")
	}
	return count, first_path, nil
}

@(test)
symbol_find_exact_match_by_default :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	freshness_write_file(t, f, "a.go")
	semantics_seed(t, f, "a.go", "h1", []store.Symbol_Name_Row{
		{name = "mono_ns", kind = "Proc", line = 1, parent = ""},
		{name = "mono_clock", kind = "Proc", line = 9, parent = ""},
		{name = "symbol_range_from_contents", kind = "Proc", line = 20, parent = ""},
	})

	n, path, err := semantics_find(t, f, "mono_ns", a)
	testing.expectf(t, err == nil, "find mono_ns: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)
	testing.expect_value(t, path, "a.go")

	n, _, err = semantics_find(t, f, "MONO_NS", a)
	testing.expectf(t, err == nil, "find MONO_NS: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)

	// The fuzzy behavior that motivated the rule is gone: a prefix or a
	// subsequence of unrelated names matches nothing.
	n, _, err = semantics_find(t, f, "mono_n", a)
	testing.expectf(t, err == nil, "find mono_n: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 0)
}

@(test)
symbol_find_glob_discovery :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	freshness_write_file(t, f, "a.go")
	semantics_seed(t, f, "a.go", "h1", []store.Symbol_Name_Row{
		{name = "mono_ns", kind = "Proc", line = 1, parent = ""},
		{name = "mono_clock", kind = "Proc", line = 9, parent = ""},
		{name = "symbol_range_from_contents", kind = "Proc", line = 20, parent = ""},
	})

	n, _, err := semantics_find(t, f, "mono_*", a)
	testing.expectf(t, err == nil, "find mono_*: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 2)

	n, _, err = semantics_find(t, f, "*_ns", a)
	testing.expectf(t, err == nil, "find *_ns: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)

	n, _, err = semantics_find(t, f, "*", a)
	testing.expectf(t, err == nil, "find *: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 3)

	n, _, err = semantics_find(t, f, "zzz_*", a)
	testing.expectf(t, err == nil, "find zzz_*: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 0)
}

@(test)
symbol_find_name_path_chain :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// chain.go: A at the top level; other.go: the same names under X;
	// deep.go: A nested one level under Outer. The same-name rows across
	// files force the parent-chain walk to decide, not the seed query.
	freshness_write_file(t, f, "chain.go")
	semantics_seed(t, f, "chain.go", "h1", []store.Symbol_Name_Row{
		{name = "A", kind = "Struct", line = 1, parent = ""},
		{name = "B", kind = "Struct", line = 2, parent = "A"},
		{name = "c", kind = "Proc", line = 3, parent = "B"},
	})
	freshness_write_file(t, f, "other.go")
	semantics_seed(t, f, "other.go", "h1", []store.Symbol_Name_Row{
		{name = "X", kind = "Struct", line = 1, parent = ""},
		{name = "B", kind = "Struct", line = 2, parent = "X"},
		{name = "c", kind = "Proc", line = 3, parent = "B"},
	})
	freshness_write_file(t, f, "deep.go")
	semantics_seed(t, f, "deep.go", "h1", []store.Symbol_Name_Row{
		{name = "Outer", kind = "Struct", line = 1, parent = ""},
		{name = "A", kind = "Struct", line = 2, parent = "Outer"},
		{name = "B", kind = "Struct", line = 3, parent = "A"},
		{name = "c", kind = "Proc", line = 4, parent = "B"},
	})

	// Relative chains are suffix matches: A/B/c hits both chain.go and
	// deep.go (Outer sits above A there), B/c hits all three.
	n, _, err := semantics_find(t, f, "A/B/c", a)
	testing.expectf(t, err == nil, "find A/B/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 2)

	n, _, err = semantics_find(t, f, "B/c", a)
	testing.expectf(t, err == nil, "find B/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 3)

	// A parent that does not sit above the chain prunes it.
	n, _, err = semantics_find(t, f, "X/B/c", a)
	testing.expectf(t, err == nil, "find X/B/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)

	n, _, err = semantics_find(t, f, "Q/c", a)
	testing.expectf(t, err == nil, "find Q/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 0)

	// Anchored chains must reach the top level: deep.go's A has Outer
	// above it, so /A/B/c keeps only chain.go.
	path := ""
	n, path, err = semantics_find(t, f, "/A/B/c", a)
	testing.expectf(t, err == nil, "find /A/B/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)
	testing.expect_value(t, path, "chain.go")

	n, path, err = semantics_find(t, f, "/X/B/c", a)
	testing.expectf(t, err == nil, "find /X/B/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)
	testing.expect_value(t, path, "other.go")

	// Anchored single names exclude nested same names the same way.
	n, _, err = semantics_find(t, f, "/A", a)
	testing.expectf(t, err == nil, "find /A: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 1)
}

@(test)
symbol_find_rejects_malformed_patterns :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	freshness_write_file(t, f, "a.go")
	semantics_seed(t, f, "a.go", "h1", []store.Symbol_Name_Row{
		{name = "bar", kind = "Proc", line = 1, parent = "Foo"},
	})

	_, _, err := semantics_find(t, f, "Foo//bar", a)
	testing.expectf(t, err != nil, "empty segment must be rejected")
	if err == nil {
		return
	}
	_, _, err = semantics_find(t, f, "/", a)
	testing.expectf(t, err != nil, "bare separator must be rejected")
	if err == nil {
		return
	}
	_, _, err = semantics_find(t, f, "bar[1]", a)
	testing.expectf(t, err != nil, "overload suffix must be rejected")
	if err == nil {
		return
	}

	// One component over the depth cap: 33 segments.
	over_buf := make([dynamic]u8, 0, 96, a)
	for i in 0..<33 {
		append(&over_buf, u8('a'))
		if i < 32 {
			append(&over_buf, u8('/'))
		}
	}
	_, _, err = semantics_find(t, f, transmute(string)(over_buf[:]), a)
	testing.expectf(t, err != nil, "over-deep pattern must be rejected")
}

@(test)
symbol_names_glob_escapes_like_literals :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	semantics_seed(t, f, "p.go", "h1", []store.Symbol_Name_Row{
		{name = "a%b", kind = "Proc", line = 1, parent = ""},
		{name = "a_b", kind = "Proc", line = 2, parent = ""},
		{name = "axb", kind = "Proc", line = 3, parent = ""},
	})

	// `%` and `_` stay literal in glob patterns; only `*` widens.
	rows, err := store.symbol_names_lookup_glob(f.d.db, "a%*", context.allocator)
	testing.expectf(t, err == nil, "glob a%*: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].name, "a%b")
	}
	store.symbol_names_rows_destroy(rows, context.allocator)

	rows, err = store.symbol_names_lookup_glob(f.d.db, "a_*", context.allocator)
	testing.expectf(t, err == nil, "glob a_*: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].name, "a_b")
	}
	store.symbol_names_rows_destroy(rows, context.allocator)

	rows, err = store.symbol_names_lookup_glob(f.d.db, "*b", context.allocator)
	testing.expectf(t, err == nil, "glob *b: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, len(rows), 3)
	store.symbol_names_rows_destroy(rows, context.allocator)
}

@(test)
symbol_names_distinct_parents_levels :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	semantics_seed(t, f, "chain.go", "h1", []store.Symbol_Name_Row{
		{name = "A", kind = "Struct", line = 1, parent = ""},
		{name = "X", kind = "Struct", line = 2, parent = ""},
		{name = "B", kind = "Struct", line = 3, parent = "A"},
		{name = "B", kind = "Struct", line = 4, parent = "X"},
		{name = "c", kind = "Proc", line = 5, parent = "B"},
	})

	// Two same-name rows at different nesting levels union into the
	// parent set; a top-level row contributes the '' marker.
	parents, err := store.symbol_names_distinct_parents(f.d.db, "chain.go", "B", context.allocator)
	testing.expectf(t, err == nil, "parents of B: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, len(parents), 2)
	has_a := false
	has_x := false
	for p in parents {
		has_a = has_a || p == "A"
		has_x = has_x || p == "X"
		delete(p, context.allocator)
	}
	delete(parents, context.allocator)
	testing.expectf(t, has_a && has_x, "parents of B must be {A, X}")

	parents, err = store.symbol_names_distinct_parents(f.d.db, "chain.go", "A", context.allocator)
	testing.expectf(t, err == nil, "parents of A: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, len(parents), 1)
	rooted := len(parents) == 1 && parents[0] == ""
	for p in parents {
		delete(p, context.allocator)
	}
	delete(parents, context.allocator)
	testing.expectf(t, rooted, "top-level A must carry the '' parent marker")
}

@(test)
symbol_find_chain_same_name_multiple_parents :: proc(t: ^testing.T) {
	f := freshness_fixture(t)
	defer freshness_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// one.go carries TWO symbols named c — one directly under P, one
	// under Q (itself under P). Both seed rows share the (path, name)
	// pair, so the per-request parents memo serves them one query whose
	// parent set is the union {P, Q}; the walk must still see both.
	freshness_write_file(t, f, "one.go")
	semantics_seed(t, f, "one.go", "h1", []store.Symbol_Name_Row{
		{name = "P", kind = "Struct", line = 1, parent = ""},
		{name = "c", kind = "Proc", line = 2, parent = "P"},
		{name = "Q", kind = "Struct", line = 3, parent = "P"},
		{name = "c", kind = "Proc", line = 4, parent = "Q"},
	})

	// Relative chains are suffix matches over the UNION parent set the
	// index records for (path, name): P/c hits both c rows (the nested
	// one through P/Q/c), and Q/c also hits both — the two same-name rows
	// share one parents query whose set is {P, Q}, so either parent
	// verifies either row. The memo must preserve exactly this.
	n, _, err := semantics_find(t, f, "P/c", a)
	testing.expectf(t, err == nil, "find P/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 2)

	n, _, err = semantics_find(t, f, "Q/c", a)
	testing.expectf(t, err == nil, "find Q/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 2)

	n, _, err = semantics_find(t, f, "Z/c", a)
	testing.expectf(t, err == nil, "find Z/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 0)

	// Anchored: P sits at the top level, Q does not (P sits above it).
	n, _, err = semantics_find(t, f, "/P/c", a)
	testing.expectf(t, err == nil, "find /P/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 2)

	n, _, err = semantics_find(t, f, "/Q/c", a)
	testing.expectf(t, err == nil, "find /Q/c: %v", err)
	if err != nil {
		return
	}
	testing.expect_value(t, n, 0)
}

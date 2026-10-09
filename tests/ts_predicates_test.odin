// Tests for the query predicate engine's nvim-family additions:
// #lua-match? (PCRE2 evaluation of nvim's lua-match?), #has-parent? /
// #not-has-parent? (the capture's immediate parent type), and
// #has-ancestor? / #not-has-ancestor? (the ancestor chain). The shipped
// queries that use them must compile — before the support they failed the
// whole-query compile with "unsupported predicate" and every highlights
// request for the grammar declined — and the evaluation contract is
// pinned with a hand-written query over the odin grammar.
package tests

import "core:mem"
import "core:testing"
import "src:ts"

// The grammars whose shipped highlights queries use the nvim-family
// predicates: odin (lua-match?, not-has-parent?), zig/kotlin (lua-match?),
// objc/julia (has-ancestor?). Each build must succeed — a compile failure
// here is the whole-query rejection the highlights face reports as an
// internal error on every request.
@(test)
ts_predicates_nvim_shipped_queries_compile :: proc(t: ^testing.T) {
	langs := []string{"odin", "zig", "kotlin", "objc", "julia"}
	for lang in langs {
		h, err := ts.build_highlights(lang, context.allocator)
		testing.expectf(t, err == "", "build_highlights(%s): %s", lang, err)
		if err == "" {
			ts.highlights_destroy(h)
		}
	}
}

@(test)
ts_predicates_nvim_evaluation :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	source := "package predicates_nvim\n\ncaller :: proc() {\n\tFoo(Bar.Baz)\n}\n"
	// Foo sits directly under the call expression; Baz's immediate parent
	// is the member expression inside the call; caller is outside the call.
	query_src := `
((identifier) @lua_hit (#lua-match? @lua_hit "^Foo$"))
((identifier) @lua_miss (#lua-match? @lua_miss "^Zed$"))
((identifier) @parent_hit (#has-parent? @parent_hit call_expression))
((identifier) @parent_miss (#not-has-parent? @parent_miss call_expression))
((identifier) @ancestor_hit (#has-ancestor? @ancestor_hit call_expression))
((identifier) @ancestor_miss (#not-has-ancestor? @ancestor_miss call_expression))
`

	idx, have := ts.registry_lookup("odin")
	testing.expect_value(t, have, true)
	if !have {
		return
	}
	lang, available := ts.registry_language(idx)
	testing.expect_value(t, available, true)
	if !available {
		return
	}

	q, is_empty, qerr := ts.compile_grammar_query(lang, query_src, "predicate-test", "odin")
	testing.expectf(t, qerr == "" && !is_empty, "query compile: %s", qerr)
	if qerr != "" || is_empty {
		return
	}
	ps, perr := ts.compile_predicates(q, a)
	testing.expectf(t, perr == "", "predicates compile: %s", perr)
	if perr != "" {
		ts.query_delete(q)
		return
	}

	h := new(ts.Highlights, a)
	h^ = {
		query         = q,
		preds         = ps,
		source_limit  = ts.HIGHLIGHTS_MAX_SOURCE_BYTES,
		capture_limit = ts.HIGHLIGHTS_MAX_CAPTURES,
		allocator     = a,
	}
	defer ts.highlights_destroy(h)

	pr, parse_err := ts.parse(source, "odin")
	testing.expectf(t, parse_err == "", "parse failed: %s", parse_err)
	if parse_err != "" {
		return
	}
	defer ts.parse_release(&pr)

	run := ts.highlights_run(h, pr.tree, source, a)

	lua_hit      := tspred_texts(run, "lua_hit", source, a)
	lua_miss     := tspred_texts(run, "lua_miss", source, a)
	parent_hit   := tspred_texts(run, "parent_hit", source, a)
	parent_miss  := tspred_texts(run, "parent_miss", source, a)
	anc_hit      := tspred_texts(run, "ancestor_hit", source, a)
	anc_miss     := tspred_texts(run, "ancestor_miss", source, a)

	testing.expect(t, tspred_has(lua_hit, "Foo"), "lua-match? must hit Foo")
	testing.expect(t, !tspred_has(lua_hit, "Bar"), "lua-match? must hit Foo only")
	testing.expect_value(t, len(lua_miss), 0)

	testing.expect(t, tspred_has(parent_hit, "Foo"), "Foo's immediate parent is the call")
	testing.expect(t, !tspred_has(parent_hit, "Baz"), "Baz's immediate parent is the member expression, not the call")
	testing.expect(t, !tspred_has(parent_hit, "caller"), "caller's parent is the declaration")
	testing.expect(t, tspred_has(parent_miss, "Baz"), "not-has-parent? keeps Baz")
	testing.expect(t, tspred_has(parent_miss, "caller"), "not-has-parent? keeps caller")
	testing.expect(t, !tspred_has(parent_miss, "Foo"), "not-has-parent? drops Foo")

	testing.expect(t, tspred_has(anc_hit, "Foo") && tspred_has(anc_hit, "Bar") && tspred_has(anc_hit, "Baz"),
		"has-ancestor? must reach Foo, Bar, and Baz through the call")
	testing.expect(t, !tspred_has(anc_hit, "caller"), "caller stands outside the call")
	testing.expect(t, tspred_has(anc_miss, "caller"), "not-has-ancestor? keeps caller")
	testing.expect(t, !tspred_has(anc_miss, "Baz"), "not-has-ancestor? drops Baz")
}

// tspred_texts collects the source text of one capture name's hits.
tspred_texts :: proc(run: ts.Highlights_Run, name, source: string, a: mem.Allocator) -> []string {
	out := make([dynamic]string, 0, 8, a)
	for c in run.captures {
		if c.name != name || c.start_byte < 0 || c.end_byte > len(source) || c.start_byte > c.end_byte {
			continue
		}
		append(&out, source[c.start_byte:c.end_byte])
	}
	return out[:]
}

tspred_has :: proc(texts: []string, want: string) -> bool {
	for x in texts {
		if x == want {
			return true
		}
	}
	return false
}

// Tests for the tags-query inference engine: grammars shipping no
// tags.scm resolve a query from the hand-verified overrides (bash,
// clojure's predicate-driven rows) while languages with no matching
// definition shapes stay observably declined (markdown).
package tests

import "core:strings"
import "core:testing"
import "src:ts"

Outline_Row_Infer :: struct {
	kind: string,
	name: string,
}

collect_infer_rows :: proc(symbols: []ts.Outline_Symbol, out: ^[dynamic]Outline_Row_Infer) {
	for i in 0..<len(symbols) {
		append(out, Outline_Row_Infer{kind = symbols[i].kind, name = symbols[i].name})
		collect_infer_rows(symbols[i].children, out)
	}
}

infer_rows :: proc(t: ^testing.T, code, lang: string) -> []Outline_Row_Infer {
	res, err := ts.outline_file(code, lang, context.allocator)
	testing.expectf(t, err == "", "outline %s: %s", lang, err)
	defer ts.outline_results_destroy(res.symbols)

	testing.expect(t, !ts.report_declined(&res.report))
	rows := make([dynamic]Outline_Row_Infer, 0, 8, context.temp_allocator)
	collect_infer_rows(res.symbols, &rows)
	return rows[:]
}

infer_expect :: proc(rows: []Outline_Row_Infer, name, kind: string) -> bool {
	for i in 0..<len(rows) {
		if rows[i].name == name {
			return rows[i].kind == kind
		}
	}
	return false
}

@(test)
tags_infer_bash_override :: proc(t: ^testing.T) {
	// bash ships no tags.scm; the inference override names its
	// function definitions through the "name" field.
	rows := infer_rows(t, "function greet {\n  echo hi\n}\n", "bash")
	testing.expect(t, infer_expect(rows, "greet", "function"))
}

@(test)
tags_infer_lua_method_shape :: proc(t: ^testing.T) {
	// The dotted method form picks the LAST identifier (the method
	// name, not the table) via the trailing anchor.
	rows := infer_rows(t, "local function f() end\nfunction M.g(x) end\n", "lua")
	testing.expect(t, infer_expect(rows, "f", "function"))
	testing.expect(t, infer_expect(rows, "g", "function"))
}

@(test)
tags_infer_markdown_stays_declined :: proc(t: ^testing.T) {
	// markdown has no definition-shaped nodes: the generic patterns all
	// gate out and the language stays observably uncovered rather than
	// silently empty.
	table := ts.GRAMMARS
	idx, ok := ts.registry_lookup("markdown")
	testing.expect(t, ok)
	if !ok {
		return
	}
	lang := ts.Language(table[idx].language())
	testing.expect(t, strings.trim_space(ts.tags_query_infer("markdown", lang)) == "")

	res, err := ts.outline_file("# Title\n", "markdown", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)
	testing.expect(t, ts.report_declined(&res.report))
	testing.expect_value(t, res.report.decline_reason, ts.Outline_Decline.Query_Empty)
}

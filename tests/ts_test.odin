// Tests for src/ts: registry name/alias resolution, Go-language parsing
// with S-expression projection, and query execution with capture text,
// formatting, and the syntax-error path.
package tests

import "core:strings"
import "core:testing"
import "src:ts"

@(test)
ts_registry_resolves_names_and_aliases :: proc(t: ^testing.T) {
	table := ts.GRAMMARS
	i, ok := ts.registry_lookup("go")
	testing.expect(t, ok && table[i].name == "go")
	testing.expect(t, table[i].tags_query != "")

	i, ok = ts.registry_lookup("GOLANG")
	testing.expect(t, ok && table[i].name == "go")

	i, ok = ts.registry_lookup("py")
	testing.expect(t, ok && table[i].name == "python")

	i, ok = ts.registry_lookup("ts")
	testing.expect(t, ok && table[i].name == "typescript")

	// c_sharp carries the legacy "csharp" spelling as an alias.
	i, ok = ts.registry_lookup("csharp")
	testing.expect(t, ok && table[i].name == "c_sharp")

	i, ok = ts.registry_lookup("tsx")
	testing.expect(t, ok && table[i].name == "tsx")

	// abap is a real language with no registry grammar.
	_, ok = ts.registry_lookup("abap")
	testing.expect(t, !ok)
	testing.expect(t, !ts.registry_supported("abap"))
	testing.expect(t, ts.registry_supported("rust"))
}

@(test)
ts_parse_go_and_sexp :: proc(t: ^testing.T) {
	res, err := ts.parse("package main\n\nfunc hello() {}\n", "go")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	root := ts.parse_root(&res)
	testing.expect(t, !ts.node_is_null(root))

	s := ts.to_s_expr(root, res.source, 0)
	testing.expect(t, strings.contains(s, "(source_file"))
	testing.expect(t, strings.contains(s, "(function_declaration"))
	testing.expect(t, strings.contains(s, "\"hello\""))

	// Unsupported languages are refused before any C call.
	_, err = ts.parse("x", "abap")
	testing.expect(t, strings.contains(err, "unsupported language: abap"))
}

@(test)
ts_query_go_functions :: proc(t: ^testing.T) {
	code := "package main\n\nfunc alpha() {}\n\nfunc beta() {}\n"
	q := "(function_declaration name: (identifier) @name) @fn"
	results, err, err_msg := ts.query(code, "go", q, context.allocator)
	testing.expectf(t, err == .None, "query: %v %s", err, err_msg)
	defer ts.query_results_destroy(results)

	if len(results) != 2 {
		testing.expectf(t, false, "query must return both functions")
		return
	}
	testing.expect_value(t, results[0].pattern_index, 0)
	if len(results[0].captures) != 2 {
		testing.expectf(t, false, "each match must carry both captures")
		return
	}
	testing.expect_value(t, len(results[0].captures), 2)
	// Capture order follows gotreesitter v0.50.1 (probed): the outer
	// @fn node comes first, the inner @name capture second.
	testing.expect_value(t, results[0].captures[0].name, "fn")
	testing.expect(t, results[0].captures[0].text == "func alpha() {}")
	testing.expect_value(t, results[0].captures[1].name, "name")
	testing.expect_value(t, results[0].captures[1].text, "alpha")
	testing.expect_value(t, results[1].captures[1].text, "beta")

	// Byte spans point into the source.
	testing.expect(t, strings.has_prefix(code[results[0].captures[1].start_byte:results[0].captures[1].end_byte], "alpha"))
}

@(test)
ts_query_formatting :: proc(t: ^testing.T) {
	code := "package main\n\nfunc alpha() {}\n"
	results, err, err_msg := ts.query(code, "go", "(function_declaration name: (identifier) @name)", context.allocator)
	testing.expectf(t, err == .None, "query: %v %s", err, err_msg)
	defer ts.query_results_destroy(results)

	full := ts.format_query_results(results, 0)
	testing.expect(t, strings.contains(full, "Match 1 (pattern 0):"))
	testing.expect(t, strings.contains(full, "@name: \"alpha\""))

	// Tight budget trips the truncation marker.
	cut := ts.format_query_results(results, 12)
	testing.expect(t, strings.contains(cut, "... (truncated)"))
}

@(test)
ts_query_syntax_error :: proc(t: ^testing.T) {
	_, err, _ := ts.query("package main\n", "go", "(((", context.allocator)
	testing.expect(t, err == .Syntax, "expected the query syntax failure kind")
}

// expect_first_capture reports the first capture's text of a match without
// aborting the test on an empty result (a bounds panic would mask the
// assertions that follow).
expect_first_capture :: proc(t: ^testing.T, results: []ts.Match_Result, match_idx: int, text: string) {
	if match_idx >= len(results) {
		testing.expectf(t, false, "missing match %d", match_idx)
		return
	}
	if len(results[match_idx].captures) == 0 {
		testing.expectf(t, false, "match %d has no captures", match_idx)
		return
	}
	testing.expect_value(t, results[match_idx].captures[0].text, text)
}

@(test)
ts_query_text_predicates :: proc(t: ^testing.T) {
	code := "package main\n\nfunc alpha() {}\n\nfunc beta() {}\n"

	// #eq? keeps only the matching capture.
	results, err, err_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#eq? @name \"alpha\"))",
		context.allocator,
	)
	testing.expectf(t, err == .None, "query: %v %s", err, err_msg)
	defer ts.query_results_destroy(results)
	testing.expect_value(t, len(results), 1)
	expect_first_capture(t, results, 0, "alpha")

	// #not-eq? drops it.
	results2, err2, err2_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#not-eq? @name \"alpha\"))",
		context.allocator,
	)
	testing.expectf(t, err2 == .None, "query: %v %s", err2, err2_msg)
	defer ts.query_results_destroy(results2)
	testing.expect_value(t, len(results2), 1)
	expect_first_capture(t, results2, 0, "beta")
}

@(test)
ts_query_match_predicates :: proc(t: ^testing.T) {
	code := "package main\n\nfunc alpha() {}\n\nfunc beta() {}\n"

	// Anchored pattern picks one function.
	results, err, err_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#match? @name \"^al\"))",
		context.allocator,
	)
	testing.expectf(t, err == .None, "query: %v %s", err, err_msg)
	defer ts.query_results_destroy(results)
	testing.expect_value(t, len(results), 1)
	expect_first_capture(t, results, 0, "alpha")

	// #match? searches anywhere in the capture text (unanchored).
	results2, err2, err2_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#match? @name \"lph\"))",
		context.allocator,
	)
	testing.expectf(t, err2 == .None, "query: %v %s", err2, err2_msg)
	defer ts.query_results_destroy(results2)
	testing.expect_value(t, len(results2), 1)
	expect_first_capture(t, results2, 0, "alpha")

	// #not-match? keeps what the pattern rejects.
	results3, err3, err3_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#not-match? @name \"^al\"))",
		context.allocator,
	)
	testing.expectf(t, err3 == .None, "query: %v %s", err3, err3_msg)
	defer ts.query_results_destroy(results3)
	testing.expect_value(t, len(results3), 1)
	expect_first_capture(t, results3, 0, "beta")
}

@(test)
ts_query_any_and_inert_predicates :: proc(t: ^testing.T) {
	code := "package main\n\nfunc alpha() {}\n\nfunc beta() {}\n"

	// #any-of? keeps the listed values only.
	results, err, err_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#any-of? @name \"alpha\" \"gamma\"))",
		context.allocator,
	)
	testing.expectf(t, err == .None, "query: %v %s", err, err_msg)
	defer ts.query_results_destroy(results)
	testing.expect_value(t, len(results), 1)
	expect_first_capture(t, results, 0, "alpha")

	// #not-any-of? drops the listed values.
	results2, err2, err2_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#not-any-of? @name \"alpha\"))",
		context.allocator,
	)
	testing.expectf(t, err2 == .None, "query: %v %s", err2, err2_msg)
	defer ts.query_results_destroy(results2)
	testing.expect_value(t, len(results2), 1)
	expect_first_capture(t, results2, 0, "beta")

	// #eq? comparing a capture against itself always holds, and the
	// metadata directive #is-not? never filters.
	results3, err3, err3_msg := ts.query(
		code, "go",
		"(function_declaration name: (identifier) @name (#eq? @name @name) (#is-not? local))",
		context.allocator,
	)
	testing.expectf(t, err3 == .None, "query: %v %s", err3, err3_msg)
	defer ts.query_results_destroy(results3)
	testing.expect_value(t, len(results3), 2)
	expect_first_capture(t, results3, 0, "alpha")
	expect_first_capture(t, results3, 1, "beta")
}

@(test)
ts_query_unsupported_predicate_fails :: proc(t: ^testing.T) {
	_, err, err_msg := ts.query(
		"package main\n", "go",
		"(function_declaration name: (identifier) @name (#frobnicate? @name))",
		context.allocator,
	)
	testing.expectf(t, err != .None, "expected a predicate failure, got: %v %s", err, err_msg)
	testing.expect(t, err == .Syntax && strings.contains(err_msg, "unsupported predicate"), err_msg)
}

@(test)
ts_registry_resolves_extensions :: proc(t: ^testing.T) {
	i, ok := ts.registry_lookup_by_extension("main.go")
	table := ts.GRAMMARS
	testing.expect(t, ok && table[i].name == "go")

	i, ok = ts.registry_lookup_by_extension("src/Component.TSX")
	testing.expect(t, ok && table[i].name == "tsx")

	i, ok = ts.registry_lookup_by_extension("deep/dir/server.odin")
	testing.expect(t, ok && table[i].name == "odin")

	i, ok = ts.registry_lookup_by_extension("scripts/tool.lua")
	testing.expect(t, ok && table[i].name == "lua")

	// Plain text stays unclaimed (the linguist fallback's vimdoc claim on
	// .txt is suppressed).
	_, ok = ts.registry_lookup_by_extension("notes.txt")
	testing.expect(t, !ok)

	_, ok = ts.registry_lookup_by_extension("noext")
	testing.expect(t, !ok)
}

@(test)
ts_registry_detects_filenames_and_shebangs :: proc(t: ^testing.T) {
	table := ts.GRAMMARS

	// Exact-filename tier (checked before extensions).
	i, ok := ts.registry_lookup_by_filename("Makefile")
	testing.expect(t, ok && table[i].name == "make")
	i, ok = ts.registry_lookup_by_filename("build/Dockerfile")
	testing.expect(t, ok && table[i].name == "dockerfile")
	i, ok = ts.registry_lookup_by_filename(".bashrc")
	testing.expect(t, ok && table[i].name == "bash")
	// The cased variants are explicit rows of their own: lowercase
	// "makefile" is a separate claim, not a case fold.
	i, ok = ts.registry_lookup_by_filename("makefile")
	testing.expect(t, ok && table[i].name == "make")

	// Multi-suffix scan tries the longest suffix first: the single-suffix
	// scan would see ".php" / ".in" instead.
	i, ok = ts.registry_lookup_by_extension("index.blade.php")
	testing.expect(t, ok && table[i].name == "blade")
	i, ok = ts.registry_lookup_by_extension("wrap/tool.sh.in")
	testing.expect(t, ok && table[i].name == "bash")

	// The ladder: filename tier first, extension scan second.
	i, ok = ts.registry_detect("dir/Makefile")
	testing.expect(t, ok && table[i].name == "make")
	i, ok = ts.registry_detect("dir/tool.lua")
	testing.expect(t, ok && table[i].name == "lua")
	_, ok = ts.registry_detect("dir/noext")
	testing.expect(t, !ok)

	// Shebang tier: env form, direct path form, flags and VAR=value
	// assignments skipped.
	i, ok = ts.registry_lookup_by_shebang("#!/usr/bin/env python3")
	testing.expect(t, ok && table[i].name == "python")
	i, ok = ts.registry_lookup_by_shebang("#!/bin/sh")
	testing.expect(t, ok && table[i].name == "bash")
	i, ok = ts.registry_lookup_by_shebang("#!/usr/bin/env -S awk -f")
	testing.expect(t, ok && table[i].name == "awk")
	i, ok = ts.registry_lookup_by_shebang("#!/usr/bin/env FOO=bar deno")
	testing.expect(t, ok && table[i].name == "typescript")
	_, ok = ts.registry_lookup_by_shebang("not a shebang")
	testing.expect(t, !ok)

	// Full content ladder: the extensionless script resolves via its
	// interpreter line; an extension hit never reads the shebang.
	i, ok = ts.registry_detect_content("run", "#!/usr/bin/env python3\nprint('hi')\n")
	testing.expect(t, ok && table[i].name == "python")
	i, ok = ts.registry_detect_content("run.sh", "#!/usr/bin/env python3\n")
	testing.expect(t, ok && table[i].name == "bash")
	_, ok = ts.registry_detect_content("noext", "no interpreter here\n")
	testing.expect(t, !ok)

	// perl is back in the registry (vendored generated parser): both the
	// extension and the interpreter claim resolve.
	i, ok = ts.registry_lookup_by_extension("script.pl")
	testing.expect(t, ok && table[i].name == "perl")
	i, ok = ts.registry_lookup_by_shebang("#!/usr/bin/perl")
	testing.expect(t, ok && table[i].name == "perl")
}

@(test)
ts_parses_perl :: proc(t: ^testing.T) {
	res, err := ts.parse("sub greet {\n  my ($name) = @_;\n  print \"hi $name\";\n}\n", "perl")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	root := ts.parse_root(&res)
	testing.expect(t, !ts.node_is_null(root))
	s := ts.to_s_expr(root, res.source, 0)
	testing.expect(t, strings.contains(s, "(source_file"))
}

@(test)
ts_parse_root_of_released_result :: proc(t: ^testing.T) {
	res, err := ts.parse("package main\n", "go")
	testing.expectf(t, err == "", "parse: %s", err)
	ts.parse_release(&res)
	root := ts.parse_root(&res)
	testing.expect(t, ts.node_is_null(root), "released result must root at null")
}

@(test)
ts_registry_extension_map_matches_ladder :: proc(t: ^testing.T) {
	// The prebuilt extension map (the crawl's per-file tier) must resolve
	// every filename exactly like the linear ladder it replaces — same
	// tier order, same first-wins precedence.
	m := ts.registry_extension_map(context.temp_allocator)
	// Owned-key map: free the cloned keys before the table.
	defer {
		for k, _ in m {
			delete(k, context.temp_allocator)
		}
		delete(m)
	}
	table := ts.GRAMMARS
	for i in 0..<len(table) {
		for e in table[i].extensions {
			forms := []string{
				strings.concatenate({"f", e}, context.temp_allocator),
				strings.concatenate({"x.blade", e}, context.temp_allocator),
				strings.concatenate({"a.b.c", e}, context.temp_allocator),
			}
			for name in forms {
				mi, mok := ts.registry_detect_with_map(m, name, context.temp_allocator)
				li, lok := ts.registry_detect(name)
				testing.expectf(
					t, mok == lok && (!mok || mi == li),
					"map/ladder disagree on %q: (%d, %v) vs (%d, %v)", name, mi, mok, li, lok,
				)
			}
		}
	}
	_, ok := ts.registry_detect_with_map(m, "no-extension", context.temp_allocator)
	testing.expect(t, !ok, "extensionless names must not resolve via extensions")
}

@(test)
ts_registry_filename_search_resolves_every_claim :: proc(t: ^testing.T) {
	// The binary search over the generated (byte-sorted) table must find
	// every claim the linear scan found, mapping to the same grammar.
	claims := ts.LINGUIST_FILENAMES
	for c in claims {
		i, ok := ts.registry_lookup_by_filename(c.key)
		testing.expectf(t, ok, "claim %q no longer resolves", c.key)
		if !ok {
			continue
		}
		gi, gok := ts.registry_lookup(c.grammar)
		testing.expectf(t, gok && gi == i, "claim %q resolved to %d, expected %d (%q)", c.key, i, gi, c.grammar)
	}
	_, ok := ts.registry_lookup_by_filename("zzz-no-such-filename")
	testing.expect(t, !ok)
}

// Tests for src/symbol: the name-path matcher table, the shared pipeline
// (method re-nesting over a real tree-sitter outline, parents, overload
// indices, locations, bodies), kind refinement, and body extraction edges.
package tests

import "core:strings"
import "core:testing"
import "src:lsp"
import "src:symbol"
import "src:ts"

@(test)
symbol_name_path_matcher :: proc(t: ^testing.T) {
	// Simple name matches any symbol with that name (innermost first).
	m, err := symbol.name_path_matcher_new("my_method", false, context.allocator)
	testing.expectf(t, err == "", "matcher: %s", err)
	defer symbol.name_path_matcher_destroy(m)
	testing.expect(t, symbol.matcher_matches_reversed(m, {
		{"my_method", -1},
		{"MyClass", -1},
	}))
	testing.expect(t, !symbol.matcher_matches_reversed(m, {
		{"other", -1},
		{"MyClass", -1},
	}))

	// Relative path matches a suffix of the name path.
	m2, err2 := symbol.name_path_matcher_new("MyClass/my_method", false, context.allocator)
	testing.expectf(t, err2 == "", "matcher: %s", err2)
	defer symbol.name_path_matcher_destroy(m2)
	testing.expect(t, symbol.matcher_matches_reversed(m2, {
		{"my_method", -1},
		{"MyClass", -1},
	}))
	testing.expect(t, symbol.matcher_matches_reversed(m2, {
		{"my_method", -1},
		{"MyClass", -1},
		{"outer", -1},
	}))
	testing.expect(t, !symbol.matcher_matches_reversed(m2, {
		{"my_method", -1},
		{"OtherClass", -1},
	}))

	// Absolute path requires an exact full match.
	m3, err3 := symbol.name_path_matcher_new("/MyClass/my_method", false, context.allocator)
	testing.expectf(t, err3 == "", "matcher: %s", err3)
	defer symbol.name_path_matcher_destroy(m3)
	testing.expect(t, symbol.matcher_matches_reversed(m3, {
		{"my_method", -1},
		{"MyClass", -1},
	}))
	testing.expect(t, !symbol.matcher_matches_reversed(m3, {
		{"my_method", -1},
		{"MyClass", -1},
		{"outer", -1},
	}))

	// Overload index disambiguates same-named siblings.
	m4, err4 := symbol.name_path_matcher_new("my_method[1]", false, context.allocator)
	testing.expectf(t, err4 == "", "matcher: %s", err4)
	defer symbol.name_path_matcher_destroy(m4)
	testing.expect(t, symbol.matcher_matches_reversed(m4, {{"my_method", 1}}))
	testing.expect(t, !symbol.matcher_matches_reversed(m4, {{"my_method", 0}}))
	testing.expect(t, !symbol.matcher_matches_reversed(m4, {{"my_method", -1}}))

	// A digit string long enough to wrap the index accumulation must not
	// alias a real overload: 2^64 + 1 used to parse back as index 1 and
	// resolve the wrong symbol. Nine digits still parse as written.
	m6, err6 := symbol.name_path_matcher_new("my_method[18446744073709551617]", false, context.allocator)
	testing.expectf(t, err6 == "", "matcher: %s", err6)
	defer symbol.name_path_matcher_destroy(m6)
	testing.expect(t, !symbol.matcher_matches_reversed(m6, {{"my_method", 1}}))
	m7, err7 := symbol.name_path_matcher_new("my_method[123456789]", false, context.allocator)
	testing.expectf(t, err7 == "", "matcher: %s", err7)
	defer symbol.name_path_matcher_destroy(m7)
	testing.expect(t, symbol.matcher_matches_reversed(m7, {{"my_method", 123456789}}))

	// Substring matching applies to the innermost component only.
	m5, err5 := symbol.name_path_matcher_new("MyClass/meth", true, context.allocator)
	testing.expectf(t, err5 == "", "matcher: %s", err5)
	defer symbol.name_path_matcher_destroy(m5)
	testing.expect(t, symbol.matcher_matches_reversed(m5, {
		{"my_method", -1},
		{"MyClass", -1},
	}))
	testing.expect(t, !symbol.matcher_matches_reversed(m5, {
		{"my_method", -1},
		{"other_container", -1},
	}))

	// Empty patterns and empty segments are rejected.
	_, e1 := symbol.name_path_matcher_new("", false, context.allocator)
	testing.expect(t, e1 != "")
	_, e2 := symbol.name_path_matcher_new("a//b", false, context.allocator)
	testing.expect(t, e2 != "")
}

// build_go_symbols runs the tree-sitter outline of a Go sample through the
// conversion and the shared pipeline, returning the finalized roots.
build_go_symbols :: proc(t: ^testing.T, code: string) -> (roots: []^symbol.Symbol) {
	outlined, err := ts.outline_file(code, "go", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(outlined.symbols)

	conv := symbol.position_converter_new(code, context.allocator)
	defer symbol.position_converter_destroy(conv)

	factory := symbol.body_factory_from_contents(code, context.allocator)
	defer symbol.body_factory_destroy(factory)

	converted := symbol.convert_outline_forest(outlined.symbols, conv, code, "go", context.allocator)
	return symbol.finalize_symbol_tree(converted, {
		allocator = context.allocator,
		abs_path = "/proj/src/server.go",
		rel_path = "src/server.go",
		body_factory = factory,
	})
}

// find_symbol_named returns the first root (or nested child of roots) with
// the given name, or nil.
find_symbol_named :: proc(roots: []^symbol.Symbol, name: string) -> ^symbol.Symbol {
	for i in 0..<len(roots) {
		if roots[i].name == name {
			return roots[i]
		}
		for j in 0..<len(roots[i].children) {
			if roots[i].children[j].name == name {
				return roots[i].children[j]
			}
		}
	}
	return nil
}

@(test)
symbol_pipeline_re_nests_methods :: proc(t: ^testing.T) {
	code := "package main\n" +
		"\n" +
		"type Server struct {\n" +
		"    Name string\n" +
		"}\n" +
		"\n" +
		"func (s *Server) Start() error {\n" +
		"    return nil\n" +
		"}\n" +
		"\n" +
		"type Reader interface {\n" +
		"    Read() error\n" +
		"}\n"

	roots := build_go_symbols(t, code)
	defer symbol.symbol_forest_destroy(roots, context.allocator)

	// The struct keeps its field and gains the method; the interface stays
	// a sibling root with its method nested by containment.
	server := find_symbol_named(roots, "Server")
	testing.expectf(t, server != nil, "missing Server root")
	if server != nil {
		testing.expect_value(t, server.kind, symbol.Symbol_Kind.Struct)
		testing.expect_value(t, len(server.children), 2)
		if len(server.children) == 2 {
			field := server.children[0]
			method := server.children[1]
			testing.expect_value(t, field.kind, symbol.Symbol_Kind.Field)
			testing.expect_value(t, field.name, "Name")
			testing.expect_value(t, method.kind, symbol.Symbol_Kind.Method)
			testing.expect_value(t, method.name, "Start")
			// Parent links walk upward; the name path is Type/Method.
			testing.expect(t, method.parent == server)
			path := symbol.symbol_full_name_path(method, context.temp_allocator)
			testing.expect_value(t, path, "Server/Start")
			// Bodies were extracted from the file contents.
			testing.expect(t, method.has_body)
			testing.expect(t, strings.contains(method.body, "return nil"))
		}
	}

	reader := find_symbol_named(roots, "Reader")
	testing.expectf(t, reader != nil, "missing Reader root")
	if reader != nil {
		// interface detection refined the kind away from Struct.
		testing.expect_value(t, reader.kind, symbol.Symbol_Kind.Interface)
		testing.expect_value(t, len(reader.children), 1)
		if len(reader.children) == 1 {
			testing.expect_value(t, reader.children[0].name, "Read")
			testing.expect_value(t, reader.children[0].kind, symbol.Symbol_Kind.Method)
		}
	}

	// Start is no longer a top-level root (it was re-nested).
	for i in 0..<len(roots) {
		testing.expectf(t, roots[i].name != "Start", "Start should have been re-nested, root %d", i)
	}

	// Locations were anchored to the file.
	if server != nil {
		testing.expect(t, server.location != nil)
		if server.location != nil {
			testing.expect_value(t, server.location.rel_path, "src/server.go")
			testing.expect(t, strings.has_prefix(server.location.uri, "file:///proj/src/server.go"))
		}
	}

	// Symbol count covers the whole forest (Server, Name, Start, Reader,
	// Read).
	testing.expect_value(t, symbol.count_symbols(roots), 5)
}

@(test)
symbol_pipeline_overload_indices :: proc(t: ^testing.T) {
	// Python allows same-named redefinitions; the pipeline numbers them so
	// name paths disambiguate.
	code := "def helper():\n" +
		"    pass\n" +
		"\n" +
		"def helper(x):\n" +
		"    return x\n" +
		"\n" +
		"def other():\n" +
		"    pass\n"

	outlined, err := ts.outline_file(code, "python", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(outlined.symbols)

	conv := symbol.position_converter_new(code, context.allocator)
	defer symbol.position_converter_destroy(conv)

	converted := symbol.convert_outline_forest(outlined.symbols, conv, code, "python", context.allocator)
	roots := symbol.finalize_symbol_tree(converted, {allocator = context.allocator})
	defer symbol.symbol_forest_destroy(roots, context.allocator)

	testing.expect_value(t, len(roots), 3)
	if len(roots) == 3 {
		testing.expect_value(t, roots[0].overload_idx, 0)
		testing.expect_value(t, roots[1].overload_idx, 1)
		testing.expect_value(t, roots[2].overload_idx, -1)

		// "helper[1]" matches exactly the second definition.
		m, merr := symbol.name_path_matcher_new("helper[1]", false, context.allocator)
		testing.expectf(t, merr == "", "matcher: %s", merr)
		defer symbol.name_path_matcher_destroy(m)
		testing.expect(t, symbol.matcher_matches_reversed(
			m,
			symbol.symbol_name_path_components(roots[1]),
		))
		testing.expect(t, !symbol.matcher_matches_reversed(
			m,
			symbol.symbol_name_path_components(roots[0]),
		))
	}
}

@(test)
symbol_body_text_edges :: proc(t: ^testing.T) {
	f := symbol.body_factory_from_contents("one\ntwo\nthree\n", context.allocator)
	defer symbol.body_factory_destroy(f)

	// Single-line slice.
	testing.expect_value(t, symbol.body_text(f.lines[:], 0, 1, 0, 3), "ne")
	// Multi-line slice joins with newlines and trims the end column.
	testing.expect_value(t, symbol.body_text(f.lines[:], 0, 1, 2, 3), "ne\ntwo\nthr")
	// End column past the line length yields the whole line.
	testing.expect_value(t, symbol.body_text(f.lines[:], 1, 0, 1, 9), "two")
	// End line past the last line is an invalid range and yields nothing
	// (the old line asserted this while its comment claimed the column
	// clamp above — the clamp itself was never exercised).
	testing.expect_value(t, symbol.body_text(f.lines[:], 1, 0, 9, 0), "")
	// Start past the end line yields nothing.
	testing.expect_value(t, symbol.body_text(f.lines[:], 4, 0, 5, 0), "")

	// file_uri percent-encodes spaces.
	uri := symbol.file_uri("/proj/my file.go", context.allocator)
	defer delete(uri)
	testing.expect_value(t, uri, "file:///proj/my%20file.go")
}

// body_text columns are UTF-16 code units (the position convention end to
// end): on lines with non-ASCII content the byte offset differs from the
// column, so the conversion must happen before any slice.
@(test)
symbol_body_text_utf16_columns :: proc(t: ^testing.T) {
	// Line 0 is "// 注 body": "// " is 3 UTF-16 units, 注 one, the space
	// one — the body starts at column 5, which is byte 7.
	f := symbol.body_factory_from_contents("// 注 body\nnext\n", context.allocator)
	defer symbol.body_factory_destroy(f)

	testing.expect_value(t, symbol.body_text(f.lines[:], 0, 5, 0, 9), "body")
	testing.expect_value(t, symbol.body_text(f.lines[:], 0, 5, 1, 2), "body\nne")
	// A column past the line clamps (the whole line is 9 units).
	testing.expect_value(t, symbol.body_text(f.lines[:], 0, 50, 0, 60), "")

	// Astral plane: 🙂 is 2 UTF-16 units but 4 bytes; the body starts at
	// column 3, byte 5.
	f2 := symbol.body_factory_from_contents("🙂 body\n", context.allocator)
	defer symbol.body_factory_destroy(f2)
	testing.expect_value(t, symbol.body_text(f2.lines[:], 0, 3, 0, 7), "body")
}

// file_uri percent-encodes everything outside the unreserved set, so the
// URI survives any RFC-compliant decoder and the round trip is the
// identity — including paths whose bytes already look like escapes.
@(test)
symbol_file_uri_roundtrip :: proc(t: ^testing.T) {
	// A literal % must be escaped, or every decoder reads %20 as a space.
	uri := symbol.file_uri("/tmp/a%20b.go", context.allocator)
	defer delete(uri)
	testing.expect_value(t, uri, "file:///tmp/a%2520b.go")

	// Windows drive form: forward slashes, three-slash authority; the
	// drive colon is percent-encoded (the strict RFC 8089 spelling every
	// decoder reads back).
	win := symbol.file_uri("C:\\proj\\a b.go", context.allocator)
	defer delete(win)
	testing.expect_value(t, win, "file:///C%3A/proj/a%20b.go")

	// UNC round trip (Windows only — the authority form has no meaning
	// for a POSIX encoder or decoder): the server lands in the authority,
	// two slashes after the scheme, not three.
	when ODIN_OS == .Windows {
		unc := symbol.file_uri("\\\\server\\share\\a b.go", context.allocator)
		defer delete(unc)
		testing.expect_value(t, unc, "file://server/share/a%20b.go")
		// Distinct names from the corpus loop's `back` below: a `when`
		// block does not open a scope, so on Windows both declarations
		// would share the procedure scope and shadow.
		unc_path, unc_ok := lsp.uri_to_path(unc, context.allocator)
		testing.expect_value(t, unc_ok, true)
		if unc_ok {
			testing.expect_value(t, unc_path, "//server/share/a b.go")
			delete(unc_path)
		}
	}

	corpus := []string{
		"/tmp/a b.go",
		"/tmp/a%20b.go",
		"/tmp/a#b.go",
		"/tmp/a?b.go",
		"/tmp/日本語/モジュール.go",
		"/tmp/it's \"quoted\".go",
		"/tmp/a~b-_c9.go",
	}
	for path in corpus {
		u := symbol.file_uri(path, context.allocator)
		testing.expectf(t, !strings.contains_any(u, " #?"), "raw delimiters in %s", u)
		back, ok := lsp.uri_to_path(u, context.allocator)
		testing.expectf(t, ok, "decode failed for %s", u)
		if ok {
			testing.expectf(t, back == path, "round trip %s -> %s -> %s", path, u, back)
			delete(back, context.allocator)
		}
		delete(u, context.allocator)
	}
}

@(test)
symbol_destroy_deep_chain :: proc(t: ^testing.T) {
	a := context.allocator
	// A chain deep enough to overflow any recursive destroy (the walks run
	// iteratively for exactly this reason).
	depth := 100_000
	root := symbol.symbol_new(a)
	cur := root
	for _ in 1..<depth {
		next := symbol.symbol_new(a)
		cur.children = make([dynamic]^symbol.Symbol, 0, 1, a)
		append(&cur.children, next)
		cur = next
	}
	symbol.symbol_node_destroy(root, a)
}

// The tree walkers truncate at MAX_TREE_DEPTH instead of recursing to the
// chain's end — source nesting is the depth driver, and generated files
// nest arbitrarily deep.
@(test)
symbol_tree_walkers_depth_capped :: proc(t: ^testing.T) {
	a := context.allocator
	root := symbol.symbol_new(a)
	cur := root
	for _ in 0..<symbol.MAX_TREE_DEPTH + 500 {
		next := symbol.symbol_new(a)
		// Clone: symbol_node_destroy frees the name through `a`, and a
		// bare literal would be a static-data bad free.
		next.name = strings.clone("deep", a)
		cur.children = make([dynamic]^symbol.Symbol, 0, 1, a)
		append(&cur.children, next)
		cur = next
	}
	symbol.assign_symbol_parents(root.children[:], nil)
	symbol.ensure_symbol_locations(root.children[:], "/proj/deep.go", "deep.go", a)

	// Locations were filled exactly to the cap: the first node of the walk
	// plus MAX_TREE_DEPTH levels (deeper nodes stay untouched, not crashed
	// on).
	walk := root.children[0]
	counted := 0
	for walk != nil && walk.location != nil {
		counted += 1
		if len(walk.children) == 0 {
			break
		}
		walk = walk.children[0]
	}
	testing.expect_value(t, counted, symbol.MAX_TREE_DEPTH + 1)

	symbol.symbol_node_destroy(root, a)
}

// The body fill honors the same depth cap as the builders: every symbol in
// a buildable tree gets its body, none silently dropped past an unrelated
// walk guard.
@(test)
symbol_populate_bodies_deep_chain :: proc(t: ^testing.T) {
	a := context.allocator
	depth := symbol.MAX_RECURSION_DEPTH + 50
	testing.expect(t, depth < symbol.MAX_TREE_DEPTH, "fixture must stay inside the builder cap")

	root := symbol.symbol_new(a)
	root_rng := new(symbol.Range, a)
	root_rng^ = {start = {line = 0, character = 0}, end = {line = 0, character = 3}}
	root.range = root_rng
	cur := root
	for _ in 1..<depth {
		next := symbol.symbol_new(a)
		rng := new(symbol.Range, a)
		rng^ = {start = {line = 0, character = 0}, end = {line = 0, character = 3}}
		next.range = rng
		cur.children = make([dynamic]^symbol.Symbol, 0, 1, a)
		append(&cur.children, next)
		cur = next
	}
	roots := make([]^symbol.Symbol, 1, a)
	roots[0] = root

	f := symbol.body_factory_from_contents("abc\n", a)
	defer symbol.body_factory_destroy(f)
	symbol.populate_symbol_bodies(roots, f, 0, a)

	with_body := 0
	walk := root
	for walk != nil {
		if walk.has_body {
			with_body += 1
		}
		if len(walk.children) == 0 {
			break
		}
		walk = walk.children[0]
	}
	testing.expectf(t, with_body == depth, "%d of %d symbols got bodies", with_body, depth)

	symbol.symbol_node_destroy(root, a)
	delete(roots, a)
}

@(test)
ensure_symbol_locations_owns_selection_range :: proc(t: ^testing.T) {
	a := context.allocator
	roots := make([]^symbol.Symbol, 1, a)
	sym := symbol.symbol_new(a)
	sym.name = strings.clone("f", a)
	roots[0] = sym

	// rng stays nil, so the selection range must come from the location as
	// an owning copy — &location.range would be freed as a bogus allocation.
	symbol.ensure_symbol_locations(roots, "/proj/x.go", "x.go", a)
	testing.expect(t, sym.selection_range != nil, "selection range not filled")
	testing.expect(t, sym.selection_range != &sym.location.range, "selection range aliases the interior location field")

	// The tracking allocator flags interior/double frees here.
	symbol.symbol_forest_destroy(roots, a)
}

// Tests for the outline projection: the Go override with owner resolution
// and containment nesting, the pinned name-conflict drop, the TypeScript
// override, library-default outlines for the shipped tags queries, decline
// and error paths, and the definition-kind inventory.
package tests

import "core:strings"
import "core:testing"
import "src:ts"

Outline_Row :: struct {
	kind:       string,
	key:        string, // "Owner/Name" for owned symbols, else the path
	owner:      string,
	node_type:  string,
}

// collect_outline flattens a forest into rows keyed by owner or path.
collect_outline :: proc(symbols: []ts.Outline_Symbol, prefix: string, out: ^[dynamic]Outline_Row) {
	for i in 0..<len(symbols) {
		s := &symbols[i]
		key := s.name
		if s.owner != "" {
			key = strings.concatenate({s.owner, "/", s.name}, context.temp_allocator)
		} else if prefix != "" {
			key = strings.concatenate({prefix, "/", s.name}, context.temp_allocator)
		}
		append(out, Outline_Row{kind = s.kind, key = key, owner = s.owner, node_type = s.node_type})
		collect_outline(s.children, key, out)
	}
}

// outline_kind_of finds the kind for a path key without indexing into
// possibly-empty rows.
outline_kind_of :: proc(rows: []Outline_Row, key: string) -> (kind: string, found: bool) {
	for i in 0..<len(rows) {
		if rows[i].key == key {
			return rows[i].kind, true
		}
	}
	return "", false
}

outline_expect_kind :: proc(t: ^testing.T, rows: []Outline_Row, key: string, want: string) {
	kind, found := outline_kind_of(rows, key)
	testing.expectf(t, found, "missing symbol %s", key)
	if found {
		testing.expect_value(t, kind, want)
	}
}

@(test)
ts_outline_go :: proc(t: ^testing.T) {
	code := "package main\n" +
		"\n" +
		"type Foo struct{ A int }\n" +
		"\n" +
		"func (f *Foo) Bar() {}\n" +
		"\n" +
		"func (f Foo) Baz() {}\n" +
		"\n" +
		"type List[T any] struct{}\n" +
		"\n" +
		"func (l *List[T]) Push(v T) {}\n" +
		"\n" +
		"type Reader interface{ Read() }\n" +
		"\n" +
		"const MaxSize = 10\n" +
		"\n" +
		"var verbose = false\n" +
		"\n" +
		"func main() {}\n"

	res, err := ts.outline_file(code, "go", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)

	testing.expect(t, !ts.report_declined(&res.report))

	rows := make([dynamic]Outline_Row, 0, 16, context.temp_allocator)
	collect_outline(res.symbols, "", &rows)

	outline_expect_kind(t, rows[:], "Foo", "type")
	outline_expect_kind(t, rows[:], "Foo/Bar", "method")
	outline_expect_kind(t, rows[:], "Foo/Baz", "method")
	outline_expect_kind(t, rows[:], "List", "type")
	outline_expect_kind(t, rows[:], "List/Push", "method")
	outline_expect_kind(t, rows[:], "Reader", "type")
	outline_expect_kind(t, rows[:], "Reader/Read", "method")
	outline_expect_kind(t, rows[:], "Foo/A", "field")
	outline_expect_kind(t, rows[:], "MaxSize", "constant")
	outline_expect_kind(t, rows[:], "verbose", "variable")
	outline_expect_kind(t, rows[:], "main", "function")

	// Pointer, value, and generic receivers all resolve the owner.
	for i in 0..<len(rows) {
		if rows[i].key == "Foo/Bar" || rows[i].key == "Foo/Baz" {
			testing.expect_value(t, rows[i].owner, "Foo")
		}
		if rows[i].key == "List/Push" {
			testing.expect_value(t, rows[i].owner, "List")
		}
	}

	// The receipt accounts for every candidate.
	testing.expect_value(t, res.report.omitted_no_name +
		res.report.omitted_duplicate +
		res.report.omitted_name_conflict +
		res.report.omitted_conflict +
		res.report.omitted_overlap +
		res.report.omitted_invalid_name_range +
		res.report.omitted_multiple_definitions, 0)
}

@(test)
ts_outline_go_multi_name_var :: proc(t: ^testing.T) {
	// Known limitation, pinned deliberately: a single-line multi-name
	// declaration binds "@name" twice on one var_spec span and the outliner
	// drops the group as a name conflict rather than guessing.
	res, err := ts.outline_file("package p\n\nvar a, b = 1, 2\n", "go", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)

	rows := make([dynamic]Outline_Row, 0, 4, context.temp_allocator)
	collect_outline(res.symbols, "", &rows)
	testing.expect_value(t, len(rows), 0)
	testing.expect(t, res.report.omitted_name_conflict > 0)
}

@(test)
ts_outline_typescript :: proc(t: ^testing.T) {
	code := "export interface Reader { read(): void }\n" +
		"export class File {\n" +
		"  private fd: number = 0;\n" +
		"  read(): void {}\n" +
		"}\n" +
		"export type Handle = { id: number };\n" +
		"export const Max = 10;\n" +
		"let counter = 0;\n" +
		"var legacy = 1;\n" +
		"export function load(): void {}\n"

	res, err := ts.outline_file(code, "typescript", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)

	testing.expect(t, !res.report.tree_has_error)
	testing.expect_value(t, ts.report_omitted(&res.report), 0)

	rows := make([dynamic]Outline_Row, 0, 16, context.temp_allocator)
	collect_outline(res.symbols, "", &rows)
	outline_expect_kind(t, rows[:], "Reader", "interface")
	outline_expect_kind(t, rows[:], "File", "class")
	outline_expect_kind(t, rows[:], "File/fd", "field")
	outline_expect_kind(t, rows[:], "File/read", "method")
	outline_expect_kind(t, rows[:], "Handle", "type")
	outline_expect_kind(t, rows[:], "Max", "variable")
	outline_expect_kind(t, rows[:], "counter", "variable")
	outline_expect_kind(t, rows[:], "legacy", "variable")
	outline_expect_kind(t, rows[:], "load", "function")
}

@(test)
ts_outline_python :: proc(t: ^testing.T) {
	code := "class Greeter:\n" +
		"    def __init__(self, name):\n" +
		"        self.name = name\n" +
		"\n" +
		"    def greet(self):\n" +
		"        return self.name\n" +
		"\n" +
		"def helper(x):\n" +
		"    return x\n"

	res, err := ts.outline_file(code, "python", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)

	testing.expect_value(t, len(res.symbols), 2)
	if len(res.symbols) == 2 {
		testing.expect_value(t, res.symbols[0].kind, "class")
		testing.expect_value(t, res.symbols[0].name, "Greeter")
		testing.expect_value(t, len(res.symbols[0].children), 2)
		if len(res.symbols[0].children) == 2 {
			testing.expect_value(t, res.symbols[0].children[0].name, "__init__")
			testing.expect_value(t, res.symbols[0].children[1].name, "greet")
		}
		testing.expect_value(t, res.symbols[1].kind, "function")
		testing.expect_value(t, res.symbols[1].name, "helper")
	}
}

@(test)
ts_outline_rust :: proc(t: ^testing.T) {
	// Against the shipped rust tags query, struct/enum/union/alias capture
	// as "class" and traits as "interface". A function with a body inside
	// an impl matches both the declaration_list method pattern and the
	// standalone function pattern on the same span, so the outliner drops
	// the group as a kind conflict (counted in the receipt); a trait's
	// bodyless method is a function_signature_item the query has no pattern
	// for, so it never becomes a candidate at all.
	code := "pub struct Server { pub name: String }\n" +
		"impl Server {\n" +
		"    pub fn new(name: String) -> Self { Self { name } }\n" +
		"}\n" +
		"pub trait Send { fn send(&self); }\n"

	res, err := ts.outline_file(code, "rust", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)

	testing.expect_value(t, len(res.symbols), 2)
	if len(res.symbols) == 2 {
		testing.expect_value(t, res.symbols[0].kind, "class")
		testing.expect_value(t, res.symbols[0].name, "Server")
		testing.expect_value(t, res.symbols[1].kind, "interface")
		testing.expect_value(t, res.symbols[1].name, "Send")
	}
	testing.expect_value(t, res.report.omitted_conflict, 2)

	// The accounting identity: every candidate is a symbol or omitted.
	testing.expect_value(
		t,
		ts.report_candidates(&res.report),
		res.report.symbols + ts.report_omitted(&res.report),
	)
}

@(test)
ts_outline_declines_and_errors :: proc(t: ^testing.T) {
	// Markdown ships no tags query: observably uncovered, not silently
	// empty. (The reference infers a markdown query; inference lands with
	// the grammar-set expansion.)
	res, err := ts.outline_file("# Title\n", "markdown", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	testing.expect(t, ts.report_declined(&res.report))
	testing.expect_value(t, res.report.decline_reason, ts.Outline_Decline.Query_Empty)

	// Unknown languages are refused before any C call.
	_, err = ts.outline_file("x", "abap", context.allocator)
	testing.expect(t, strings.contains(err, "unsupported language: abap"))

	// A damaged tree still projects; the receipt flags it.
	broken, berr := ts.outline_file("package main\nfunc ( {\n", "go", context.allocator)
	testing.expectf(t, berr == "", "outline: %s", berr)
	defer ts.outline_results_destroy(broken.symbols)
	testing.expect(t, broken.report.tree_has_error)
}

@(test)
ts_outline_go_definition_kinds :: proc(t: ^testing.T) {
	o, err := ts.build_outliner("go", context.allocator)
	testing.expectf(t, err == "", "build: %s", err)
	defer ts.outliner_destroy(o)

	kinds := ts.outliner_definition_kinds(o, context.allocator)
	defer if kinds != nil {
		for i in 0..<len(kinds) {
			delete(kinds[i])
		}
		delete(kinds)
	}
	testing.expect_value(t, len(kinds), 6)
	if len(kinds) == 6 {
		testing.expect_value(t, kinds[0], "constant")
		testing.expect_value(t, kinds[1], "field")
		testing.expect_value(t, kinds[2], "function")
		testing.expect_value(t, kinds[3], "method")
		testing.expect_value(t, kinds[4], "type")
		testing.expect_value(t, kinds[5], "variable")
	}
}

@(test)
ts_outline_source_supported :: proc(t: ^testing.T) {
	testing.expect(t, ts.outline_source_supported("go", context.allocator))
	testing.expect(t, ts.outline_source_supported("typescript", context.allocator))
	testing.expect(t, ts.outline_source_supported("python", context.allocator))
	testing.expect(t, !ts.outline_source_supported("markdown", context.allocator))
	testing.expect(t, !ts.outline_source_supported("definitely-not-a-language", context.allocator))
}

@(test)
ts_outline_odin :: proc(t: ^testing.T) {
	// The odin grammar ships no tags query; the hand-maintained override
	// with anchored first-child patterns keeps parameter and field
	// identifiers from binding @name twice.
	code := "package main\n" +
		"\n" +
		"Server :: struct {\n" +
		"    name: string,\n" +
		"}\n" +
		"\n" +
		"Color :: enum { Red, Green }\n" +
		"\n" +
		"Flags :: bit_set[Color]\n" +
		"\n" +
		"MAX_SIZE :: 1024\n" +
		"\n" +
		"greeting := \"hello\"" + "\n" +
		"\n" +
		"main :: proc() {\n" +
		"    fmt.Println(greeting)\n" +
		"}\n" +
		"\n" +
		"describe :: proc(s: Server, verbose: bool) -> string {\n" +
		"    return s.name\n" +
		"}\n"

	res, err := ts.outline_file(code, "odin", context.allocator)
	testing.expectf(t, err == "", "outline: %s", err)
	defer ts.outline_results_destroy(res.symbols)

	testing.expect(t, !res.report.tree_has_error)
	testing.expect_value(t, ts.report_omitted(&res.report), 0)

	rows := make([dynamic]Outline_Row, 0, 8, context.temp_allocator)
	collect_outline(res.symbols, "", &rows)
	outline_expect_kind(t, rows[:], "Server", "type")
	outline_expect_kind(t, rows[:], "Color", "enum")
	outline_expect_kind(t, rows[:], "Flags", "constant")
	outline_expect_kind(t, rows[:], "MAX_SIZE", "constant")
	outline_expect_kind(t, rows[:], "greeting", "variable")
	outline_expect_kind(t, rows[:], "main", "function")
	outline_expect_kind(t, rows[:], "describe", "function")
}

@(test)
outline_results_destroy_deep_chain :: proc(t: ^testing.T) {
	a := context.allocator
	depth := 100_000
	root_slice := make([]ts.Outline_Symbol, 1, a)
	cur := &root_slice[0]
	for _ in 1..<depth {
		child := make([]ts.Outline_Symbol, 1, a)
		cur.children = child
		cur = &child[0]
	}
	ts.outline_results_destroy(root_slice, a)
}

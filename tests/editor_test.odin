// Tests for src/editor: snapshot buffers, the edit-file flow with rollback
// (line ops, content replacement, save with line endings), comment
// scanning, brace/indentation validation, the content hash, and the
// injected file-IO port (the real one against temp files, plus a pure
// in-memory fake covering the closed failure vocabulary).
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "src:config"
import "src:editor"
import "src:platform"
import "src:safety"
import "src:symbol"
import "src:svc"
import "src:ts"
import "src:util"

Editor_Fixture :: struct {
	dir: string,
	e:   ^editor.Editor,
}

editor_fixture :: proc(t: ^testing.T, line_ending: config.Line_Ending) -> Editor_Fixture {
	dir, err := os.make_directory_temp("", "aubade-editor-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, line_ending, "", svc.editor_file_io_port(), context.allocator)
	return {dir = dir, e = e}
}

editor_fixture_destroy :: proc(f: Editor_Fixture) {
	editor.editor_destroy(f.e)
	free(f.e, context.allocator)
	_ = os.remove_all(f.dir)
	delete(f.dir)
}

write_fixture_file :: proc(f: Editor_Fixture, name: string, content: string) {
	path, _ := filepath.join([]string{f.dir, name}, context.temp_allocator)
	fp, err := os.open(path, {.Write, .Create, .Trunc}, {
		.Read_User, .Write_User, .Read_Group, .Read_Other,
	})
	if err != nil {
		return
	}
	os.write(fp, transmute([]u8)content)
	os.close(fp)
}

read_fixture_file :: proc(f: Editor_Fixture, name: string) -> string {
	path, _ := filepath.join([]string{f.dir, name}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		return ""
	}
	defer delete(data)
	return strings.clone(string(data), context.allocator)
}

@(test)
editor_line_ops_and_rollback :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "sample.txt", "alpha\nbeta\ngamma\n")

	// Insert at a line.
	eerr, emsg := editor.editor_insert_at_line(f.e, "sample.txt", 1, "inserted\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	after := read_fixture_file(f, "sample.txt")
	defer delete(after)
	testing.expect_value(t, after, "alpha\ninserted\nbeta\ngamma\n")

	// Replace a line range atomically.
	eerr, emsg = editor.editor_replace_lines(f.e, "sample.txt", 1, 2, "replaced\n")
	testing.expectf(t, eerr == .None, "replace: %s", emsg)
	after2 := read_fixture_file(f, "sample.txt")
	defer delete(after2)
	testing.expect_value(t, after2, "alpha\nreplaced\ngamma\n")

	// Delete lines.
	eerr, emsg = editor.editor_delete_lines(f.e, "sample.txt", 0, 0)
	testing.expectf(t, eerr == .None, "delete: %s", emsg)
	after3 := read_fixture_file(f, "sample.txt")
	defer delete(after3)
	testing.expect_value(t, after3, "replaced\ngamma\n")

	// A failing edit leaves the disk untouched (rollback to snapshot).
	before_fail := read_fixture_file(f, "sample.txt")
	eerr, emsg = editor.editor_insert_at_line(f.e, "sample.txt", 99, "nope\n")
	testing.expect(t, eerr == .Position, "out-of-range insert must fail")
	after_fail := read_fixture_file(f, "sample.txt")
	testing.expect_value(t, after_fail, before_fail)
	delete(before_fail)
	delete(after_fail)

	// In-memory edits are visible to reads and hidden from a fresh editor.
	eerr, emsg = editor.editor_insert_at_line(f.e, "sample.txt", 0, "header\n")
	testing.expectf(t, eerr == .None, "insert2: %s", emsg)
	contents, rerr, rmsg := editor.editor_read_file(f.e, "sample.txt")
	testing.expectf(t, rerr == .None, "read: %s", rmsg)
	delete(contents)
	// (Saved immediately, so the disk carries it too.)
	disk := read_fixture_file(f, "sample.txt")
	testing.expect(t, strings.has_prefix(disk, "header\n"))
	delete(disk)

	// Dropping the buffer re-reads from disk next time.
	editor.editor_drop_buffer(f.e, "sample.txt")
	fresh, rerr2, rmsg2 := editor.editor_read_file(f.e, "sample.txt")
	testing.expectf(t, rerr2 == .None, "read2: %s", rmsg2)
	testing.expect(t, strings.has_prefix(fresh, "header\n"))
	delete(fresh)
}

@(test)
editor_replace_content_modes :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "code.txt", "x := 1\ny := 2\nx := 3\n")

	// Literal: a needle matching once replaces; matching twice without
	// allow_multiple is refused.
	eerr, emsg := editor.editor_replace_content(f.e, "code.txt", "1", "one", "literal", false)
	testing.expectf(t, eerr == .None, "literal: %s", emsg)
	after := read_fixture_file(f, "code.txt")
	defer delete(after)
	testing.expect_value(t, after, "x := one\ny := 2\nx := 3\n")

	eerr, _ = editor.editor_replace_content(f.e, "code.txt", "x", "zed", "literal", false)
	testing.expect(t, eerr == .Invalid, "ambiguous literal replacement must be refused")

	// Regex, all occurrences.
	eerr, emsg = editor.editor_replace_content(f.e, "code.txt", "x|y", "v", "regex", true)
	testing.expectf(t, eerr == .None, "regex: %s", emsg)
	after2 := read_fixture_file(f, "code.txt")
	defer delete(after2)
	testing.expect_value(t, after2, "v := one\nv := 2\nv := 3\n")

	// Unknown mode is rejected before touching the file.
	eerr, _ = editor.editor_replace_content(f.e, "code.txt", "a", "b", "glob", false)
	testing.expect(t, eerr == .Invalid)
}

@(test)
editor_crlf_line_endings :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Crlf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "win.txt", "one\r\ntwo\r\n")

	eerr, emsg := editor.editor_insert_at_line(f.e, "win.txt", 1, "mid\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	disk := read_fixture_file(f, "win.txt")
	defer delete(disk)
	// The save applies CRLF; the in-memory buffer stays LF-normalised.
	testing.expect_value(t, disk, "one\r\nmid\r\ntwo\r\n")

	contents, rerr, rmsg := editor.editor_read_file(f.e, "win.txt")
	testing.expectf(t, rerr == .None, "read: %s", rmsg)
	testing.expect_value(t, contents, "one\nmid\ntwo\n")
	delete(contents)
}

@(test)
editor_comment_scan :: proc(t: ^testing.T) {
	// Line comments above a python def.
	code := "# first line\n# second line\n\ndef helper():\n    pass\n"
	pattern, _ := editor.comment_pattern_for_language("python")
	start := editor.find_comment_start(code, 3, pattern)
	testing.expect_value(t, start, 0)

	// The previous definition's body stops the scan, but the comment
	// directly above this definition still belongs to it.
	code2 := "def other():\n    pass\n\n# about helper\ndef helper():\n    pass\n"
	start2 := editor.find_comment_start(code2, 4, pattern)
	testing.expect_value(t, start2, 3)

	// A definition keyword line directly above the comment claims it.
	code2b := "def other():\n# about helper\ndef helper():\n    pass\n"
	start2b := editor.find_comment_start(code2b, 2, pattern)
	testing.expect_value(t, start2b, 2)

	// No comment above: the definition line itself.
	code3 := "def helper():\n    pass\n"
	start3 := editor.find_comment_start(code3, 0, pattern)
	testing.expect_value(t, start3, 0)

	// C-family block comments span upward to their opener.
	c_code := "/* header\n   more */\nint main() {}\n"
	c_pattern, _ := editor.comment_pattern_for_language("c")
	start4 := editor.find_comment_start(c_code, 2, c_pattern)
	testing.expect_value(t, start4, 0)

	// The extended families resolve their real markers (the unlisted
	// fallback would scan for the wrong syntax).
	hs_pattern, hs_listed := editor.comment_pattern_for_language("haskell")
	testing.expect(t, hs_listed && hs_pattern.line_comment == "--")
	testing.expect(t, hs_pattern.block_start == "{-") // brace: ==, not expect_value
	hs_code := "-- about f\nf :: Int\nf = 1\n"
	start5 := editor.find_comment_start(hs_code, 1, hs_pattern)
	testing.expect_value(t, start5, 0)

	el_pattern, _ := editor.comment_pattern_for_language("elixir")
	testing.expect_value(t, el_pattern.line_comment, "#")
	cl_pattern, _ := editor.comment_pattern_for_language("commonlisp")
	testing.expect_value(t, cl_pattern.line_comment, ";")
	ft_pattern, _ := editor.comment_pattern_for_language("fortran")
	testing.expect_value(t, ft_pattern.line_comment, "!")
	sql_pattern, _ := editor.comment_pattern_for_language("sql")
	testing.expect_value(t, sql_pattern.line_comment, "--")
	testing.expect_value(t, sql_pattern.block_start, "/*")
}

Comment_Test_Row :: struct {
	name: string,
	pat:  editor.Comment_Pattern,
}

// editor_comment_table_covers_grammar_registry cross-checks the comment
// pattern table against every language in the grammar registry. The
// expected values were extracted from the pinned grammars' own comment
// rules (grammar.js or the external scanner for scanner-defined
// comments), so the C-family rows are verified decisions rather than the
// unlisted fallback: css carries a js_comment rule, starlark extends the
// python grammar, the tolerant json grammar parses // comments. A
// language added to the registry without a row here fails the test —
// the point is that nobody can silently inherit C-family comment syntax
// for a language that uses something else (or nothing).
@(test)
editor_comment_table_covers_grammar_registry :: proc(t: ^testing.T) {
	rows := []Comment_Test_Row{
		{"apex", {"//", "/*", "*/"}},
		{"arduino", {"//", "/*", "*/"}},
		{"bicep", {"//", "/*", "*/"}},
		{"c", {"//", "/*", "*/"}},
		{"c_sharp", {"//", "/*", "*/"}},
		{"cairo", {"//", "/*", "*/"}},
		{"chatito", {"//", "/*", "*/"}},
		{"circom", {"//", "/*", "*/"}},
		{"cpon", {"//", "/*", "*/"}},
		{"cpp", {"//", "/*", "*/"}},
		{"css", {"//", "/*", "*/"}},
		{"cuda", {"//", "/*", "*/"}},
		{"cue", {"//", "/*", "*/"}},
		{"d", {"//", "/*", "*/"}},
		{"dart", {"//", "/*", "*/"}},
		{"devicetree", {"//", "/*", "*/"}},
		{"dot", {"//", "/*", "*/"}},
		{"doxygen", {"//", "/*", "*/"}},
		{"enforce", {"//", "/*", "*/"}},
		{"faust", {"//", "/*", "*/"}},
		{"fidl", {"//", "/*", "*/"}},
		{"foam", {"//", "/*", "*/"}},
		{"gleam", {"//", "/*", "*/"}},
		{"glsl", {"//", "/*", "*/"}},
		{"go", {"//", "/*", "*/"}},
		{"gomod", {"//", "/*", "*/"}},
		{"groovy", {"//", "/*", "*/"}},
		{"hack", {"//", "/*", "*/"}},
		{"hare", {"//", "/*", "*/"}},
		{"haxe", {"//", "/*", "*/"}},
		{"hlsl", {"//", "/*", "*/"}},
		{"java", {"//", "/*", "*/"}},
		{"javascript", {"//", "/*", "*/"}},
		{"jsdoc", {"//", "/*", "*/"}},
		{"json", {"//", "/*", "*/"}},
		{"json5", {"//", "/*", "*/"}},
		{"jsonnet", {"//", "/*", "*/"}},
		{"kdl", {"//", "/*", "*/"}},
		{"kotlin", {"//", "/*", "*/"}},
		{"less", {"//", "/*", "*/"}},
		{"linkerscript", {"//", "/*", "*/"}},
		{"move", {"//", "/*", "*/"}},
		{"objc", {"//", "/*", "*/"}},
		{"odin", {"//", "/*", "*/"}},
		{"php", {"//", "/*", "*/"}},
		{"pkl", {"//", "/*", "*/"}},
		{"prisma", {"//", "/*", "*/"}},
		{"proto", {"//", "/*", "*/"}},
		{"pug", {"//", "/*", "*/"}},
		{"ql", {"//", "/*", "*/"}},
		{"rescript", {"//", "/*", "*/"}},
		{"rust", {"//", "/*", "*/"}},
		{"scala", {"//", "/*", "*/"}},
		{"scss", {"//", "/*", "*/"}},
		{"smithy", {"//", "/*", "*/"}},
		{"solidity", {"//", "/*", "*/"}},
		{"squirrel", {"//", "/*", "*/"}},
		{"swift", {"//", "/*", "*/"}},
		{"tablegen", {"//", "/*", "*/"}},
		{"templ", {"//", "/*", "*/"}},
		{"thrift", {"//", "/*", "*/"}},
		{"tsx", {"//", "/*", "*/"}},
		{"typescript", {"//", "/*", "*/"}},
		{"typst", {"//", "/*", "*/"}},
		{"v", {"//", "/*", "*/"}},
		{"verilog", {"//", "/*", "*/"}},
		{"wgsl", {"//", "/*", "*/"}},
		{"zig", {"//", "/*", "*/"}},

		{"python", {"#", "", ""}},
		{"awk", {"#", "", ""}},
		{"bash", {"#", "", ""}},
		{"bitbake", {"#", "", ""}},
		{"capnp", {"#", "", ""}},
		{"cmake", {"#", "", ""}},
		{"crystal", {"#", "", ""}},
		{"cylc", {"#", "", ""}},
		{"desktop", {"#", "", ""}},
		{"diff", {"#", "", ""}},
		{"dockerfile", {"#", "", ""}},
		{"earthfile", {"#", "", ""}},
		{"editorconfig", {"#", "", ""}},
		{"elixir", {"#", "", ""}},
		{"fish", {"#", "", ""}},
		{"gdscript", {"#", "", ""}},
		{"git_config", {"#", "", ""}},
		{"git_rebase", {"#", "", ""}},
		{"gitattributes", {"#", "", ""}},
		{"gitignore", {"#", "", ""}},
		{"gn", {"#", "", ""}},
		{"graphql", {"#", "", ""}},
		{"hcl", {"#", "", ""}},
		{"heex", {"#", "", ""}},
		{"http", {"#", "", ""}},
		{"hurl", {"#", "", ""}},
		{"hyprlang", {"#", "", ""}},
		{"ini", {"#", "", ""}},
		{"just", {"#", "", ""}},
		{"kconfig", {"#", "", ""}},
		{"make", {"#", "", ""}},
		{"meson", {"#", "", ""}},
		{"mojo", {"#", "", ""}},
		{"nginx", {"#", "", ""}},
		{"nickel", {"#", "", ""}},
		{"ninja", {"#", "", ""}},
		{"nix", {"#", "", ""}},
		{"nushell", {"#", "", ""}},
		{"org", {"#", "", ""}},
		{"perl", {"#", "", ""}},
		{"powershell", {"#", "", ""}},
		{"promql", {"#", "", ""}},
		{"properties", {"#", "", ""}},
		{"puppet", {"#", "", ""}},
		{"r", {"#", "", ""}},
		{"rego", {"#", "", ""}},
		{"requirements", {"#", "", ""}},
		{"robot", {"#", "", ""}},
		{"sparql", {"#", "", ""}},
		{"ssh_config", {"#", "", ""}},
		{"starlark", {"#", "", ""}},
		{"tcl", {"#", "", ""}},
		{"textproto", {"#", "", ""}},
		{"toml", {"#", "", ""}},
		{"turtle", {"#", "", ""}},
		{"yaml", {"#", "", ""}},

		{"ruby", {"#", "=begin", "=end"}},
		{"lua", {"--", "--[[", "]]"}},
		{"luau", {"--", "--[[", "]]"}},
		{"teal", {"--", "--[[", "]]"}},
		{"haskell", {"--", "{-", "-}"}},
		{"elm", {"--", "{-", "-}"}},
		{"purescript", {"--", "{-", "-}"}},
		{"dhall", {"--", "{-", "-}"}},
		{"ada", {"--", "", ""}},
		{"agda", {"--", "", ""}},
		{"sql", {"--", "/*", "*/"}},
		{"erlang", {"%", "", ""}},
		{"matlab", {"%", "", ""}},
		{"prolog", {"%", "", ""}},
		{"asm", {";", "", ""}},
		{"bass", {";", "", ""}},
		{"beancount", {";", "", ""}},
		{"commonlisp", {";", "", ""}},
		{"elisp", {";", "", ""}},
		{"fennel", {";", "", ""}},
		{"firrtl", {";", "", ""}},
		{"godot_resource", {";", "", ""}},
		{"ledger", {";", "", ""}},
		{"llvm", {";", "", ""}},
		{"racket", {";", "", ""}},
		{"scheme", {";", "", ""}},
		{"yuck", {";", "", ""}},
		{"fortran", {"!", "", ""}},
		{"cobol", {"*>", "", ""}},
		{"forth", {"\\", "", ""}},
		{"mermaid", {"%%", "", ""}},
		{"julia", {"#", "#=", "=#"}},
		{"nim", {"#", "#[", "]#"}},
		{"pascal", {"//", "{", "}"}},
		{"fsharp", {"//", "(*", "*)"}},
		{"tlaplus", {"\\*", "(*", "*)"}},
		{"ocaml", {"", "(*", "*)"}},
		{"wolfram", {"", "(*", "*)"}},
		{"uxntal", {"", "(", ")"}},
		{"wat", {";;", "(;", ";)"}},
		{"angular", {"", "<!--", "-->"}},
		{"astro", {"", "<!--", "-->"}},
		{"dtd", {"", "<!--", "-->"}},
		{"html", {"", "<!--", "-->"}},
		{"markdown", {"", "<!--", "-->"}},
		{"markdown_inline", {"", "<!--", "-->"}},
		{"svelte", {"", "<!--", "-->"}},
		{"vue", {"", "<!--", "-->"}},
		{"xml", {"", "<!--", "-->"}},
		{"jinja2", {"", "{#", "#}"}},
		{"blade", {"", "{{--", "--}}"}},
		{"embedded_template", {"", "<%#", "%>"}},
		{"liquid", {"", "{% comment %}", "{% endcomment %}"}},

		{"bibtex", {}},
		{"comment", {}},
		{"csv", {}},
		{"djot", {}},
		{"norg", {}},
		{"pem", {}},
		{"regex", {}},
		{"rst", {}},
		{"todotxt", {}},
		{"vimdoc", {}},
	}

	expect := make(map[string]editor.Comment_Pattern, len(rows))
	defer delete(expect)
	for r in rows {
		expect[r.name] = r.pat
	}

	// Every registry language must carry a decided pattern (registry
	// table materialized locally for indexing).
	table := ts.GRAMMARS
	for i in 0..<len(table) {
		name := table[i].name
		want, ok := expect[name]
		testing.expectf(t, ok, "language %q has no comment-pattern row — decide its comment syntax (extract from the pinned grammar) and add both a LANGUAGE_PROPS row and a row", name)
		if !ok {
			continue
		}
		got, listed := editor.comment_pattern_for_language(name)
		// Rows whose decided pattern IS the C-family pattern may sit on
		// the unlisted fallback; every other row must be listed.
		wants_c_family := want.line_comment == "//" && want.block_start == "/*" && want.block_end == "*/"
		if !wants_c_family {
			testing.expectf(t, listed, "language %q has a table row but falls to the unlisted C-family default — add it to LANGUAGE_PROPS", name)
		}
		testing.expectf(t, got.line_comment == want.line_comment, "line comment mismatch for %q: got %q want %q", name, got.line_comment, want.line_comment)
		testing.expectf(t, got.block_start == want.block_start, "block start mismatch for %q: got %q want %q", name, got.block_start, want.block_start)
		testing.expectf(t, got.block_end == want.block_end, "block end mismatch for %q: got %q want %q", name, got.block_end, want.block_end)
	}

	// Every row must name a registered language (guards typos and rows
	// left behind by a grammar removal).
	registered := make(map[string]bool, len(table))
	defer delete(registered)
	for i in 0..<len(table) {
		registered[table[i].name] = true
	}
	for r in rows {
		testing.expectf(t, registered[r.name], "comment-pattern row %q names no registered grammar", r.name)
	}

	// The empty line-comment marker must stay inert: block-only families
	// (html) never treat ordinary text as a comment line, and the no-
	// comment families report the definition line itself.
	html_pat, _ := editor.comment_pattern_for_language("html")
	testing.expectf(t, editor.find_comment_start("<!DOCTYPE html>\n<div></div>\n", 1, html_pat) == 1, "html scan must not treat plain markup as a comment")
	testing.expectf(t, editor.find_comment_start("<!-- note -->\n<div></div>\n", 1, html_pat) == 0, "html block comment above must be found")
	firrtl_pat, _ := editor.comment_pattern_for_language("firrtl")
	testing.expectf(t, editor.find_comment_start("; about m\nmodule Foo\n", 1, firrtl_pat) == 0, "firrtl semicolon comment above must be found")
	none_pat, _ := editor.comment_pattern_for_language("csv")
	testing.expectf(t, editor.find_comment_start("a,b,c\nd,e,f\n", 1, none_pat) == 1, "no-comment formats report the definition line")
}

@(test)
editor_brace_and_indent_validation :: proc(t: ^testing.T) {
	berr, _ := editor.validate_brace_balance("fn f() { if x { } }", "odin")
	testing.expect(t, berr == .None)
	berr, _ = editor.validate_brace_balance("fn f() { } }", "odin")
	testing.expect(t, berr == .Invalid)
	berr, _ = editor.validate_brace_balance("fn f() {", "odin")
	testing.expect(t, berr == .Invalid)
	// String literals don't count; a quote after a digit is a numeric
	// suffix, so braces after it still count.
	berr, _ = editor.validate_brace_balance(`put("{")`, "odin")
	testing.expect(t, berr == .None)
	berr, _ = editor.validate_brace_balance("v := 1' {}", "odin")
	testing.expect(t, berr == .None)
	berr, _ = editor.validate_brace_balance("x := 1' {", "odin")
	testing.expect(t, berr == .Invalid)

	ierr, imsg := editor.validate_indentation("def a():\n    return 1\n")
	testing.expect(t, ierr == .None, "consistent indentation must pass")
	testing.expect_value(t, imsg, "")
	ierr, _ = editor.validate_indentation("def a():\n\treturn 1\n     x = 2\n")
	testing.expect(t, ierr == .Invalid)
}

// Quotes inside comments are prose, not literal delimiters: the move
// validator scans the extracted block (docstring included), and a comment
// apostrophe used to swallow real braces and reject balanced code.
@(test)
editor_brace_validation_skips_comments :: proc(t: ^testing.T) {
	// A lone apostrophe inside the body swallowed the closing brace.
	berr, _ := editor.validate_brace_balance("fn f() {\n\t// it's fine\n}\n", "odin")
	testing.expect(t, berr == .None)
	// Docstring-side and body-side apostrophes used to straddle the
	// opening brace and count the closer as extra.
	berr, _ = editor.validate_brace_balance("// isn't moved\nfn f() {\n\t// it's fine\n}\n", "odin")
	testing.expect(t, berr == .None)
	// Braces and quotes inside line comments and block comments are
	// comment text.
	berr, _ = editor.validate_brace_balance("fn f() { // } { \" don't\n}\n", "odin")
	testing.expect(t, berr == .None)
	berr, _ = editor.validate_brace_balance("fn f() { /* } { */ }\n", "odin")
	testing.expect(t, berr == .None)
	// Rune literals in code keep their literal semantics.
	berr, _ = editor.validate_brace_balance("fn f() {\n\tc := '\"'\n}\n", "odin")
	testing.expect(t, berr == .None)
	// A string containing the comment marker is not a comment: the brace
	// after it still counts.
	berr, _ = editor.validate_brace_balance("put(\"// \") {", "odin")
	testing.expect(t, berr == .Invalid)
	// Real imbalance is still caught with comments present.
	berr, _ = editor.validate_brace_balance("fn f() {\n\t// don't look here\n", "odin")
	testing.expect(t, berr == .Invalid)
	berr, _ = editor.validate_brace_balance("fn f() {\n\t/* unterminated\n", "odin")
	testing.expect(t, berr == .Invalid)
}

@(test)
editor_content_hash :: proc(t: ^testing.T) {
	h1 := editor.content_hash_hex("hello", context.allocator)
	defer delete(h1)
	h2 := editor.content_hash_hex("hello", context.allocator)
	defer delete(h2)
	h3 := editor.content_hash_hex("world", context.allocator)
	defer delete(h3)
	testing.expect_value(t, len(h1), 64)
	testing.expect(t, h1 == h2)
	testing.expect(t, h1 != h3)
	// sha256("hello") is a known vector.
	testing.expect_value(t, h1, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@(test)
editor_extract_lines :: proc(t: ^testing.T) {
	text, xerr, xmsg := editor.extract_lines("a\nb\nc\nd\n", 1, 2)
	testing.expectf(t, xerr == .None, "extract: %s", xmsg)
	testing.expect_value(t, text, "b\nc")

	_, xerr, _ = editor.extract_lines("a\n", 0, 5)
	testing.expect(t, xerr == .Position)
	_, xerr, _ = editor.extract_lines("a\n", 2, 1)
	testing.expect(t, xerr == .Position)
}

@(test)
editor_file_lock_prune_spares_held_handles :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	held := editor.file_lock(f.e, "held.txt")
	// Burn past the prune interval with acquire/lock/release pairs on
	// another path — every release is a prune opportunity.
	for _ in 0..<editor.FILE_LOCK_PRUNE_INTERVAL + 4 {
		h := editor.file_lock(f.e, "other.txt")
		sync.mutex_lock(&h.mu)
		sync.mutex_unlock(&h.mu)
		editor.file_release(f.e, "other.txt")
	}
	// The held handle survived every prune and is still usable.
	testing.expect(t, f.e.file_locks["held.txt"] == held, "held handle was pruned")
	sync.mutex_lock(&held.mu)
	sync.mutex_unlock(&held.mu)
	editor.file_release(f.e, "held.txt")
}

@(test)
editor_file_lock_prune_frees_released_handles :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	h := editor.file_lock(f.e, "gone.txt")
	sync.mutex_lock(&h.mu)
	sync.mutex_unlock(&h.mu)
	editor.file_release(f.e, "gone.txt")
	// Released but not yet pruned: the entry lingers until the interval.
	testing.expect(t, f.e.file_locks["gone.txt"] != nil, "entry vanished before prune")
	for _ in 0..<editor.FILE_LOCK_PRUNE_INTERVAL {
		editor.file_lock(f.e, "burn.txt")
		editor.file_release(f.e, "burn.txt")
	}
	testing.expect(t, f.e.file_locks["gone.txt"] == nil, "released entry survived prune")
}

// Path identity follows the filesystem's case sensitivity: spellings
// that differ only in case are one file (one lock handle, one buffer)
// on macOS/Windows and distinct files on Linux. The expectations derive
// from platform.case_insensitive_fs() so the one test pins the fold
// wiring on the whole CI matrix.
@(test)
editor_file_identity_follows_fs_case :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "case.txt", "one\n")

	// Lock identity: two spellings, one handle iff the fs folds case.
	h1 := editor.file_lock(f.e, "case.txt")
	editor.file_release(f.e, "case.txt")
	h2 := editor.file_lock(f.e, "CASE.TXT")
	editor.file_release(f.e, "CASE.TXT")
	testing.expectf(
		t,
		(h1 == h2) == platform.case_insensitive_fs(),
		"case-varied spellings must share one lock handle iff the fs folds case",
	)

	// Buffer identity: the buffer opened under "case.txt" must be
	// reachable by the folded spelling of "CASE.TXT" iff the fs folds
	// case (the buffers map keys on platform.path_fold). Reads never
	// populate the buffer cache — an edit is what opens the buffer.
	oerr, omsg := editor.editor_insert_at_line(f.e, "case.txt", 0, "top\n")
	testing.expectf(t, oerr == .None, "buffer open: %s", omsg)
	key := platform.path_fold("CASE.TXT", context.temp_allocator)
	sync.mutex_lock(&f.e.mu)
	_, folded_hit := f.e.buffers[key]
	sync.mutex_unlock(&f.e.mu)
	testing.expectf(
		t,
		folded_hit == platform.case_insensitive_fs(),
		"folded lookup must hit the open buffer iff the fs folds case",
	)

	// The comparison helper carries the same basis as the fold.
	testing.expect_value(
		t,
		platform.path_equal("dir/a.txt", "DIR/A.TXT"),
		platform.case_insensitive_fs(),
	)
}

// The production read port serves files across its 64 KiB chunk boundary:
// the chunked loop is also what keeps the size bound at read time (a file
// growing between stat and read surfaces Too_Large instead of an
// unbounded read).
@(test)
editor_production_read_serves_multichunk_files :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	big := make([dynamic]u8, 0, 200_032, context.allocator)
	defer delete(big)
	for i in 0..<200_032 {
		append(&big, u8('a' + (i % 26)))
	}
	write_fixture_file(f, "big.bin", string(big[:]))

	contents, rerr, rmsg := editor.editor_read_file(f.e, "big.bin")
	testing.expectf(t, rerr == .None, "read: %s", rmsg)
	defer delete(contents)
	testing.expect_value(t, len(contents), 200_032)
	testing.expect_value(t, contents[0], u8('a'))
	testing.expect_value(t, contents[200_031], u8('a' + (200_031 % 26)))
}

@(test)
editor_drop_buffer_reverts_to_disk :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "drop.txt", "one\ntwo\n")

	eerr, emsg := editor.editor_replace_lines(f.e, "drop.txt", 0, 0, "EDITED\n")
	testing.expectf(t, eerr == .None, "replace: %s", emsg)
	edited, rerr, rmsg := editor.editor_read_file(f.e, "drop.txt")
	testing.expectf(t, rerr == .None, "read: %s", rmsg)
	defer delete(edited)
	testing.expect_value(t, edited, "EDITED\ntwo\n")

	// An external change lands on disk behind the buffer's back; dropping
	// the buffer reverts reads to the on-disk content.
	write_fixture_file(f, "drop.txt", "restored\n")
	editor.editor_drop_buffer(f.e, "drop.txt")
	disk, _, _ := editor.editor_read_file(f.e, "drop.txt")
	defer delete(disk)
	testing.expect_value(t, disk, "restored\n")

	// Dropping a file with no open buffer is a no-op.
	editor.editor_drop_buffer(f.e, "drop.txt")
}

// A read of a buffered file adopts an external disk change: saves are
// synchronous so a held buffer is never dirty — a differing disk is a
// newer external state, and serving the old buffer would both hide it
// and revert it on the next save.
@(test)
editor_read_adopts_external_change :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "ext.txt", "one\ntwo\n")

	eerr, emsg := editor.editor_replace_lines(f.e, "ext.txt", 0, 0, "EDITED\n")
	testing.expectf(t, eerr == .None, "replace: %s", emsg)

	write_fixture_file(f, "ext.txt", "externally\nrewritten\n")
	got, rerr, rmsg := editor.editor_read_file(f.e, "ext.txt")
	testing.expectf(t, rerr == .None, "read: %s", rmsg)
	defer delete(got)
	testing.expect_value(t, got, "externally\nrewritten\n")
}

// The next edit transaction also builds on the external state: without
// the reuse-time adoption the edit would run on the stale buffer and the
// save would silently revert the external change.
@(test)
editor_edit_builds_on_external_change :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "ext2.txt", "one\ntwo\n")

	eerr, emsg := editor.editor_replace_lines(f.e, "ext2.txt", 0, 0, "EDITED\n")
	testing.expectf(t, eerr == .None, "replace1: %s", emsg)

	write_fixture_file(f, "ext2.txt", "alpha\nbeta\ngamma\ndelta\n")
	eerr, emsg = editor.editor_replace_lines(f.e, "ext2.txt", 1, 2, "NEW\n")
	testing.expectf(t, eerr == .None, "replace2: %s", emsg)

	disk := read_fixture_file(f, "ext2.txt")
	defer delete(disk)
	// beta+gamma replaced on the adopted external bytes (a stale-buffer
	// run has only two lines and refuses the inclusive 1..2 range).
	testing.expect_value(t, disk, "alpha\nNEW\ndelta\n")
}

// --- buffer listener -------------------------------------------------------

Rec_Event :: struct {
	kind: string, // "open" | "change" | "close"
	path: string,
	n:    int, // byte length of the contents at the event (close: 0)
}

Event_Rec :: struct {
	mu:     sync.Mutex,
	events: [dynamic]Rec_Event,
}

rec_open :: proc(user: rawptr, rel_path: string, contents: string) {
	rec := cast(^Event_Rec)user
	sync.mutex_lock(&rec.mu)
	append(&rec.events, Rec_Event{kind = "open", path = rel_path, n = len(contents)})
	sync.mutex_unlock(&rec.mu)
}

rec_change :: proc(user: rawptr, rel_path: string, contents: string) {
	rec := cast(^Event_Rec)user
	sync.mutex_lock(&rec.mu)
	append(&rec.events, Rec_Event{kind = "change", path = rel_path, n = len(contents)})
	sync.mutex_unlock(&rec.mu)
}

rec_close :: proc(user: rawptr, rel_path: string) {
	rec := cast(^Event_Rec)user
	sync.mutex_lock(&rec.mu)
	append(&rec.events, Rec_Event{kind = "close", path = rel_path})
	sync.mutex_unlock(&rec.mu)
}

@(test)
editor_buffer_listener_lifecycle :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "a.txt", "one\ntwo\n")

	rec := new(Event_Rec, context.allocator)
	rec.events = make([dynamic]Rec_Event, 0, 4, context.allocator)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(f.e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})

	eerr, emsg := editor.editor_insert_at_line(f.e, "a.txt", 1, "mid\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	// Buffer creation reports the pre-edit snapshot, then the durable
	// post-save contents.
	testing.expect_value(t, len(rec.events), 2)
	testing.expect_value(t, rec.events[0].kind, "open")
	testing.expect_value(t, rec.events[0].path, "a.txt")
	testing.expect_value(t, rec.events[0].n, len("one\ntwo\n"))
	testing.expect_value(t, rec.events[1].kind, "change")
	testing.expect_value(t, rec.events[1].n, len("one\nmid\ntwo\n"))

	// A second edit reuses the buffer: change only, no second open.
	eerr, emsg = editor.editor_insert_at_line(f.e, "a.txt", 0, "top\n")
	testing.expectf(t, eerr == .None, "insert 2: %s", emsg)
	testing.expect_value(t, len(rec.events), 3)
	testing.expect_value(t, rec.events[2].kind, "change")

	editor.editor_drop_buffer(f.e, "a.txt")
	testing.expect_value(t, len(rec.events), 4)
	testing.expect_value(t, rec.events[3].kind, "close")
	testing.expect_value(t, rec.events[3].path, "a.txt")
}

// Map keys must outlive their callers' scopes: the daemon hands rel_paths
// in on the request arena, so buffers key by the buffer's own clone and
// file locks carry an owned path (the map-entry lifetime rule).
@(test)
editor_keys_survive_the_request_arena :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "a.txt", "hello\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	rel := strings.clone("a.txt", mem.dynamic_arena_allocator(&arena))
	eerr, emsg := editor.editor_insert_at_line(f.e, rel, 0, "top\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	mem.dynamic_arena_destroy(&arena)

	// A second edit through a fresh string must find the same buffer: one
	// entry, keyed by bytes the editor owns.
	eerr, emsg = editor.editor_insert_at_line(f.e, "a.txt", 0, "again\n")
	testing.expectf(t, eerr == .None, "insert 2: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)

	// Lock churn through borrowed paths crosses the prune interval; owned
	// keys are cloned on create and freed on prune (leak output polices
	// the frees).
	for _ in 0..<editor.FILE_LOCK_PRUNE_INTERVAL + 1 {
		_ = editor.file_lock(f.e, "a.txt")
		editor.file_release(f.e, "a.txt")
	}
	testing.expect(t, len(f.e.file_locks) <= 1, "at most the live lock entry remains")
}

// --- the injected file-IO port ----------------------------------------------

// Fake_FS is a pure in-memory port: reads answer from the map, writes are
// recorded, and the toggles force the provider-side failure kinds.
Fake_FS :: struct {
	files:      map[string]string,
	fail_read:  bool,
	fail_write: bool,
	oversize:   bool,
}

fake_fs_read :: proc(user: rawptr, abs_path: string, max_bytes: i64, alloc: mem.Allocator) -> (data: []u8, err: editor.Editor_Err, msg: string) {
	fs := cast(^Fake_FS)user
	if fs.fail_read {
		return nil, .IO, "read failed"
	}
	s, ok := fs.files[abs_path]
	if !ok {
		return nil, .NotFound, "file not found"
	}
	if fs.oversize {
		return nil, .Too_Large, "file exceeds editor read limit"
	}
	data = make([]u8, len(s), alloc)
	copy(data, transmute([]u8)s)
	return data, .None, ""
}

fake_fs_write :: proc(user: rawptr, abs_path: string, data: []u8) -> (err: editor.Editor_Err, msg: string) {
	fs := cast(^Fake_FS)user
	if fs.fail_write {
		return .IO, "cannot open for writing"
	}
	if old, ok := fs.files[abs_path]; ok && old != "" {
		delete(old, context.allocator)
	}
	fs.files[abs_path] = strings.clone(string(data), context.allocator)
	return .None, ""
}

fake_fs_destroy :: proc(fs: ^Fake_FS) {
	for _, v in fs.files {
		if v != "" {
			delete(v, context.allocator)
		}
	}
	delete(fs.files)
}

// editor_fake_fs_port covers the closed vocabulary end to end with no disk
// at all: provider refusals surface their kinds, editor-side failures
// (positions) surface theirs, and a refused write rolls the edit back.
@(test)
editor_fake_fs_port_failure_kinds :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-editorfs-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	fs := new(Fake_FS, context.allocator)
	fs.files = make(map[string]string, 4, context.allocator)
	defer {
		fake_fs_destroy(fs)
		free(fs, context.allocator)
	}

	e := new(editor.Editor, context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}
	editor.editor_init(e, dir, .Lf, "", {user = fs, read = fake_fs_read, write = fake_fs_write}, context.allocator)

	// A missing file reads as NotFound with the provider's message.
	_, rerr, rmsg := editor.editor_read_file(e, "missing.txt")
	testing.expect(t, rerr == .NotFound, "missing file must read as NotFound")
	testing.expect_value(t, rmsg, "file not found")

	// The editor addresses the port with the path guard's resolved
	// spelling (macOS temp trees resolve /var -> /private/var), so the
	// fake map must be keyed the same way.
	pos_path, perr := safety.pathguard_validate_contained(dir, "pos.txt", context.temp_allocator)
	testing.expect_value(t, perr.reason, "")
	fs.files[pos_path] = strings.clone("one\n", context.allocator)

	// The position failure is the editor's own, not the port's.
	eerr, emsg := editor.editor_insert_at_line(e, "pos.txt", 99, "x\n")
	testing.expect(t, eerr == .Position, "out-of-range insert must read as Position")

	// Drop the buffer the failed edit opened: the buffer would otherwise
	// answer reads and writes without consulting the port.
	editor.editor_drop_buffer(e, "pos.txt")

	// Provider refusals: oversize and read failure.
	fs.oversize = true
	_, rerr, _ = editor.editor_read_file(e, "pos.txt")
	testing.expect(t, rerr == .Too_Large, "oversize must read as Too_Large")
	fs.oversize = false
	fs.fail_read = true
	_, rerr, _ = editor.editor_read_file(e, "pos.txt")
	testing.expect(t, rerr == .IO, "refused read must read as IO")
	fs.fail_read = false

	// A refused write fails the whole edit (with rollback) as IO, and the
	// recorded contents stay untouched.
	fs.fail_write = true
	eerr, emsg = editor.editor_insert_at_line(e, "pos.txt", 0, "top\n")
	testing.expect(t, eerr == .IO, "refused write must read as IO")
	testing.expect(t, strings.contains(emsg, "write failed: "), "write failure message %q", emsg)
	testing.expect_value(t, fs.files[pos_path], "one\n")
	fs.fail_write = false

	// A healthy round trip goes through the port's map.
	eerr, emsg = editor.editor_insert_at_line(e, "pos.txt", 1, "mid\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	testing.expect_value(t, fs.files[pos_path], "one\nmid\n")
}

// editor_file_read_cap_message pins the production read port's refusal
// text: the actual size and the limit must both be stated so the model
// can judge a sliced retry.
@(test)
editor_file_read_cap_message :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-edcap-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	if derr != nil {
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	path, _ := filepath.join([]string{dir, "big.txt"}, context.allocator)
	defer delete(path)
	fp, werr := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	testing.expectf(t, werr == nil, "open failed")
	if werr != nil {
		return
	}
	big := make([]u8, 100, context.temp_allocator)
	_, werr = os.write(fp, big)
	os.close(fp)
	testing.expectf(t, werr == nil, "write failed")
	if werr != nil {
		return
	}

	data, rerr, rmsg := svc.editor_file_read(nil, path, 50, context.allocator)
	testing.expect(t, rerr == .Too_Large, "oversize must read as Too_Large")
	testing.expect(t, data == nil, "refused read must return no data")
	testing.expect(t, strings.contains(rmsg, "100 bytes"), "message must state the size: %q", rmsg)
	testing.expect(t, strings.contains(rmsg, "50 bytes"), "message must state the limit: %q", rmsg)
}

// The read-time bound's equality edge: a file of exactly max_bytes
// passes (the chunked loop refuses only strictly past the limit), and
// one byte over is refused — the stat guard and the growth guard share
// one bound, with no slack between them.
@(test)
editor_file_read_exact_bound :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-edexact-", context.allocator)
	testing.expectf(t, derr == nil, "temp dir failed")
	if derr != nil {
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	path, _ := filepath.join([]string{dir, "exact.bin"}, context.allocator)
	defer delete(path)
	payload := make([]u8, 200_001, context.allocator) // crosses the 64 KiB chunk boundary
	defer delete(payload)
	for i in 0..<len(payload) {
		payload[i] = u8(i % 251)
	}
	testing.expectf(t, os.write_entire_file(path, payload, {.Read_User, .Write_User}) == nil, "write failed")

	data, rerr, _ := svc.editor_file_read(nil, path, 200_001, context.allocator)
	testing.expectf(t, rerr == .None, "exact-size read: err %v", rerr)
	testing.expect_value(t, len(data), 200_001)
	delete(data, context.allocator)

	over, oerr, _ := svc.editor_file_read(nil, path, 200_000, context.allocator)
	testing.expect(t, oerr == .Too_Large, "one byte over must read as Too_Large")
	testing.expect(t, over == nil, "refused read must return no data")
}

// editor_err_map_kinds pins the boundary conversion: every editor kind
// lands on its platform kind, message prefixed once. The produced errors
// ride a scratch arena (their messages are heap clones).
@(test)
editor_err_map_kinds :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	cases := []struct {
		e:    editor.Editor_Err,
		kind: platform.Err_Kind,
	}{
		{.NotFound, .NotFound},
		{.Outside_Root, .Denied},
		{.Too_Large, .Invalid},
		{.Position, .Invalid},
		{.Invalid, .Invalid},
		{.Invalid_Symbol, .Invalid},
		{.IO, .Internal},
		{.Internal, .Internal},
	}
	for c in cases {
		perr := svc.editor_err_map("op", c.e, "boom", a)
		kind: platform.Err_Kind
		msg := ""
		#partial switch w in perr {
		case platform.Wrapped:
			kind = w.kind
			msg = w.msg
		case platform.Err_Kind:
			kind = w
		}
		testing.expectf(t, kind == c.kind, "kind for %v: got %v", c.e, kind)
		testing.expect_value(t, msg, "op: boom")
	}
}

// The freshness probe's stability contract, at the editor seam: after a
// save, decoding the disk must equal the buffer — no spurious reload
// (an extra change event) and no silent drift. Each supported encoding
// gets its own regression here because each broke differently before the
// read/write paths were made symmetric.

editor_event_count :: proc(rec: ^Event_Rec, kind: string) -> int {
	sync.mutex_lock(&rec.mu)
	n := 0
	for ev in rec.events {
		if ev.kind == kind {
			n += 1
		}
	}
	sync.mutex_unlock(&rec.mu)
	return n
}

editor_probe_recorder :: proc(t: ^testing.T) -> ^Event_Rec {
	rec := new(Event_Rec, context.allocator)
	rec.events = make([dynamic]Rec_Event, 0, 4, context.allocator)
	return rec
}

@(test)
editor_crlf_probe_stable_with_lone_cr :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Crlf)
	defer editor_fixture_destroy(f)
	// A lone '\r' between a and b, a \r\n pair after b: the read folds
	// only the pair, the save re-emits both shapes.
	write_fixture_file(f, "x.txt", "a\rb\r\nc")

	rec := editor_probe_recorder(t)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(f.e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})

	eerr, emsg := editor.editor_insert_at_line(f.e, "x.txt", 1, "mid\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	testing.expect_value(t, editor_event_count(rec, "open"), 1)
	testing.expect_value(t, editor_event_count(rec, "change"), 1)

	// The saved disk keeps the lone \r AND expands the newlines; reading
	// it back decodes to exactly the buffer, so the probe stays quiet.
	disk := read_fixture_file(f, "x.txt")
	testing.expect_value(t, disk, "a\rb\r\nmid\r\nc")
	delete(disk, context.allocator)
	contents, rerr, _ := editor.editor_read_file(f.e, "x.txt")
	testing.expect(t, rerr == .None)
	defer delete(contents, f.e.allocator)
	testing.expect_value(t, contents, "a\rb\nmid\nc")
	testing.expectf(t, editor_event_count(rec, "change") == 1, "no reload after own save")

	// An inserted lone '\r' survives its own save/reload cycle too.
	eerr, emsg = editor.editor_insert_at_line(f.e, "x.txt", 0, "q\rr\n")
	testing.expectf(t, eerr == .None, "insert 2: %s", emsg)
	contents2, rerr2, _ := editor.editor_read_file(f.e, "x.txt")
	testing.expect(t, rerr2 == .None)
	defer delete(contents2, f.e.allocator)
	testing.expect_value(t, contents2, "q\rr\na\rb\nmid\nc")
	testing.expectf(t, editor_event_count(rec, "change") == 2, "one change per edit, none per read")
}

@(test)
editor_crlf_save_writes_inserted_pair_once :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Crlf)
	defer editor_fixture_destroy(f)
	// An inserted \r\n pair is one newline: the save must emit a single
	// CRLF for it. Translating only the '\n' byte wrote the pair's '\r'
	// through and then expanded, doubling it to \r\r\n on disk — and the
	// read side folded the corruption away, so only the disk ever showed
	// it.
	write_fixture_file(f, "x.txt", "a\rb\r\nc")

	rec := editor_probe_recorder(t)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(f.e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})

	eerr, emsg := editor.editor_insert_at_line(f.e, "x.txt", 1, "mid\r\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	testing.expect_value(t, editor_event_count(rec, "change"), 1)

	// Every newline on disk is exactly one CRLF; the lone '\r' between a
	// and b stays content.
	disk := read_fixture_file(f, "x.txt")
	testing.expect_value(t, disk, "a\rb\r\nmid\r\nc")
	delete(disk, context.allocator)

	// The buffer kept the inserted pair raw (the sep-2 view), while the
	// decoded disk folds it — so the next read reloads once and the
	// buffer settles on the LF spelling, the same reconciliation the LF
	// setting performs for pair-carrying inserts.
	contents, rerr, _ := editor.editor_read_file(f.e, "x.txt")
	testing.expect(t, rerr == .None)
	defer delete(contents, f.e.allocator)
	testing.expect_value(t, contents, "a\rb\nmid\nc")
	testing.expectf(t, editor_event_count(rec, "change") == 2, "one change per edit, one for the pair-folding reload")
}

@(test)
editor_latin1_probe_stable :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-l1probe-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "latin-1", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}
	f := Editor_Fixture{dir = dir, e = e}

	// Bytes 0xC3 0xA9 in a latin-1 file are the two characters Ã© — the
	// decode must not guess UTF-8 (that reinterpretation used to make
	// the first save rewrite the file and the buffer drift).
	write_fixture_file(f, "l.txt", "\xC3\xA9\n")

	rec := editor_probe_recorder(t)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})

	eerr, emsg := editor.editor_insert_at_line(e, "l.txt", 0, "top\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	disk := read_fixture_file(f, "l.txt")
	testing.expect_value(t, disk, "top\n\xC3\xA9\n")
	delete(disk, context.allocator)

	// The buffer decodes the two bytes as the two runes U+00C3 U+00A9
	// (the typed characters below), never as a UTF-8 pair.
	contents, rerr, _ := editor.editor_read_file(e, "l.txt")
	testing.expect(t, rerr == .None)
	defer delete(contents, e.allocator)
	testing.expect_value(t, contents, "top\nÃ©\n")
	testing.expectf(t, editor_event_count(rec, "change") == 1, "no reload after own save")
}

@(test)
editor_utf16_round_trip :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-u16probe-", context.allocator)
	if derr != nil {
		testing.expectf(t, false, "temp dir failed")
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "utf-16", svc.editor_file_io_port(), context.allocator)
	defer {
		editor.editor_destroy(e)
		free(e, context.allocator)
	}
	f := Editor_Fixture{dir = dir, e = e}

	// Seed the file as UTF-16 (LE with BOM): reads decode it, edits save
	// it back, and non-ASCII survives the round trip.
	seed := util.encode_utf16_bytes("package x\n\nfunc f() {}\n", false, context.temp_allocator)
	write_fixture_file(f, "u.go", string(seed))

	contents, rerr, _ := editor.editor_read_file(e, "u.go")
	testing.expect(t, rerr == .None)
	defer delete(contents, e.allocator)
	testing.expect_value(t, contents, "package x\n\nfunc f() {}\n")

	eerr, emsg := editor.editor_insert_at_line(e, "u.go", 1, "// コメント\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)

	raw := read_fixture_file(f, "u.go")
	defer delete(raw, context.allocator)
	testing.expect(t, len(raw) >= 2)
	testing.expect_value(t, rune(raw[0]), 0xFF)
	testing.expectf(t, rune(raw[1]) == 0xFE, "the save writes a BOM'd LE stream")
	decoded := util.decode_utf16_bytes(transmute([]byte)raw, context.temp_allocator)
	testing.expect_value(t, decoded, "package x\n// コメント\n\nfunc f() {}\n")

	// The probe is quiet over the codec: reading again reloads nothing.
	rec := editor_probe_recorder(t)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})
	again, rerr2, _ := editor.editor_read_file(e, "u.go")
	testing.expect(t, rerr2 == .None)
	defer delete(again, e.allocator)
	testing.expect_value(t, again, "package x\n// コメント\n\nfunc f() {}\n")
	testing.expectf(t, editor_event_count(rec, "change") == 0, "no reload after own save")
}

// The UTF-8 BOM is a file-level marker, not buffer text: reads strip it,
// every edit path (content replace, line-0 insert, line-1 replace/delete)
// works on clean text, and save restores the marker. Windows-authored files
// ("UTF-8 with BOM") must come back byte-identical in their signature.

@(test)
editor_utf8_bom_round_trip :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "b.go", "\xEF\xBB\xBFpackage x\n\nfunc f() {}\n")

	// The read strips the marker: the buffer — and every parse/index view
	// behind the same reader — never carries it as text.
	contents, rerr, _ := editor.editor_read_file(f.e, "b.go")
	testing.expect(t, rerr == .None)
	defer delete(contents, f.e.allocator)
	testing.expect_value(t, contents, "package x\n\nfunc f() {}\n")

	// A start-anchored regex matches line 1 (with the BOM parked in the
	// buffer it used to eat the ^).
	eerr, emsg := editor.editor_replace_content(f.e, "b.go", "^package x", "package z", "regex", false)
	testing.expectf(t, eerr == .None, "anchored regex: %s", emsg)

	// Inserting at line 0 lands after the marker, not ahead of it.
	eerr, emsg = editor.editor_insert_at_line(f.e, "b.go", 0, "header\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)

	// Replacing and deleting line 1 keep the marker: it belongs to the
	// file, not to the line.
	eerr, emsg = editor.editor_replace_lines(f.e, "b.go", 0, 0, "top\n")
	testing.expectf(t, eerr == .None, "replace lines: %s", emsg)
	eerr, emsg = editor.editor_delete_lines(f.e, "b.go", 0, 0)
	testing.expectf(t, eerr == .None, "delete lines: %s", emsg)

	disk := read_fixture_file(f, "b.go")
	defer delete(disk, context.allocator)
	testing.expect_value(t, disk, "\xEF\xBB\xBFpackage z\n\nfunc f() {}\n")
}

@(test)
editor_utf8_bom_probe_stable :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "b.txt", "\xEF\xBB\xBFalpha\nbeta\n")

	rec := editor_probe_recorder(t)
	defer {
		delete(rec.events)
		free(rec, context.allocator)
	}
	editor.editor_set_listener(f.e, {on_open = rec_open, on_change = rec_change, on_close = rec_close, user = rec})

	eerr, emsg := editor.editor_insert_at_line(f.e, "b.txt", 1, "mid\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	testing.expect_value(t, editor_event_count(rec, "open"), 1)
	testing.expect_value(t, editor_event_count(rec, "change"), 1)

	// The saved disk re-carries the BOM; decoding it again strips back to
	// exactly the buffer, so the probe stays quiet on re-reads.
	disk := read_fixture_file(f, "b.txt")
	testing.expect_value(t, disk, "\xEF\xBB\xBFalpha\nmid\nbeta\n")
	delete(disk, context.allocator)
	again, rerr2, _ := editor.editor_read_file(f.e, "b.txt")
	testing.expect(t, rerr2 == .None)
	defer delete(again, f.e.allocator)
	testing.expect_value(t, again, "alpha\nmid\nbeta\n")
	testing.expectf(t, editor_event_count(rec, "change") == 1, "no reload after own save")
}

@(test)
editor_no_bom_stays_bomless :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "plain.txt", "one\ntwo\n")

	eerr, emsg := editor.editor_insert_at_line(f.e, "plain.txt", 0, "zero\n")
	testing.expectf(t, eerr == .None, "insert: %s", emsg)
	eerr, emsg = editor.editor_replace_content(f.e, "plain.txt", "two", "deux", "literal", false)
	testing.expectf(t, eerr == .None, "replace: %s", emsg)

	// The plain file never gains a marker.
	disk := read_fixture_file(f, "plain.txt")
	defer delete(disk, context.allocator)
	testing.expect_value(t, disk, "zero\none\ndeux\n")
}

// ---------------------------------------------------------------------------
// Symbol delete seam collapse
// ---------------------------------------------------------------------------

// delete_middle writes the fixture, drops any cached buffer so the edit
// reads the fresh bytes, deletes `name`, and returns the disk contents.
delete_middle :: proc(
	t: ^testing.T,
	f: ^Editor_Fixture,
	src: string,
	name: string,
	with_comments: bool,
) -> string {
	write_fixture_file(f^, "t.go", src)
	editor.editor_drop_buffer(f.e, "t.go")
	roots := build_go_symbols(t, src)
	defer symbol.symbol_forest_destroy(roots, context.allocator)
	s := find_symbol_named(roots, name)
	testing.expectf(t, s != nil, "%s not found", name)
	if s == nil {
		return ""
	}
	derr, dmsg := editor.editor_symbol_delete(f.e, "t.go", s, with_comments, "go")
	testing.expectf(t, derr == .None, "delete %s: %s", name, dmsg)
	return read_fixture_file(f^, "t.go")
}

// A whole-symbol delete leaves the neighborhood's shape at the seam: one
// blank separator when the removed block had one on either side, none
// when it had none, and nothing dangling at the file edges. The plain
// form contributes its own trailing newline as residue; the comment form
// deletes whole lines.
@(test)
editor_symbol_delete_seam_collapse :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	// Separated on both sides, plain form: the body's leftover newline
	// plus both separators collapse to one blank line.
	sep_src := "package a\n\ntype First struct{}\n\ntype Second struct{}\n\ntype Third struct{}\n"
	after_sep := delete_middle(t, &f, sep_src, "Second", false)
	defer delete(after_sep, context.allocator)
	testing.expect(t, after_sep == "package a\n\ntype First struct{}\n\ntype Third struct{}\n", after_sep)

	// Comment form on the same layout: the doc comment goes with the
	// block and the seam still keeps exactly one separator.
	com_src := "package a\n\ntype First struct{}\n\n// Second is a thing.\ntype Second struct{}\n\ntype Third struct{}\n"
	after_com := delete_middle(t, &f, com_src, "Second", true)
	defer delete(after_com, context.allocator)
	testing.expect(t, after_com == "package a\n\ntype First struct{}\n\ntype Third struct{}\n", after_com)

	// No separators at all: the neighbors stay adjacent — the plain
	// form's leftover newline is residue, not a separator.
	tight_src := "package a\n\ntype First struct{}\ntype Second struct{}\ntype Third struct{}\n"
	after_tight := delete_middle(t, &f, tight_src, "Second", false)
	defer delete(after_tight, context.allocator)
	testing.expect(t, after_tight == "package a\n\ntype First struct{}\ntype Third struct{}\n", after_tight)

	// File-final block, comment form: nothing dangles past the last
	// definition; the file keeps its single trailing newline.
	last_src := "package a\n\ntype First struct{}\n\n// Last is a thing.\ntype Last struct{}\n"
	after_last := delete_middle(t, &f, last_src, "Last", true)
	defer delete(after_last, context.allocator)
	testing.expect(t, after_last == "package a\n\ntype First struct{}\n", after_last)
}

// The same seam discipline under CRLF: whole lines in, whole lines out,
// every surviving line keeps its terminator.
@(test)
editor_symbol_delete_seam_crlf :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Crlf)
	defer editor_fixture_destroy(f)

	src := "package a\r\n\r\ntype First struct{}\r\n\r\ntype Second struct{}\r\n\r\ntype Third struct{}\r\n"
	after := delete_middle(t, &f, src, "Second", false)
	defer delete(after, context.allocator)
	testing.expect(
		t,
		after == "package a\r\n\r\ntype First struct{}\r\n\r\ntype Third struct{}\r\n",
		after,
	)
}

// A same-file move vacates the source site through the same line-granular
// range: the neighbors it leaves behind keep exactly one separator.
@(test)
editor_symbol_move_vacates_seam :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	src := "package a\n\ntype First struct{}\n\ntype Second struct{}\n\ntype Third struct{}\n"
	write_fixture_file(f, "m.go", src)
	roots := build_go_symbols(t, src)
	defer symbol.symbol_forest_destroy(roots, context.allocator)
	s := find_symbol_named(roots, "Second")
	testing.expectf(t, s != nil, "Second not found")
	if s == nil {
		return
	}
	summary, merr, mmsg := editor.editor_symbol_move(
		f.e, "Second", s, "m.go", "go", src,
		"m.go", "go", src, nil, "end", .Move,
	)
	testing.expectf(t, merr == .None, "move: %s", mmsg)
	_ = summary
	after := read_fixture_file(f, "m.go")
	defer delete(after, context.allocator)
	testing.expectf(
		t,
		strings.contains(after, "type First struct{}\n\ntype Third struct{}"),
		"vacated seam keeps one separator: %q",
		after,
	)
	testing.expectf(t, !strings.contains(after, "type First struct{}\n\n\n"), "no multi-blank seam: %q", after)
	testing.expect(t, strings.contains(after, "type Second struct{}"), "moved symbol present")
}

// A banner comment separated from the docstring by a blank line stays
// with the file: only the docstring attached to the moved symbol travels.
@(test)
editor_symbol_move_banner_comment_stays :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	src := "package a\n\n// section: helpers\n\n// Second is a thing.\ntype Second struct{}\n\ntype Third struct{}\n"
	write_fixture_file(f, "m.go", src)
	roots := build_go_symbols(t, src)
	defer symbol.symbol_forest_destroy(roots, context.allocator)
	s := find_symbol_named(roots, "Second")
	testing.expectf(t, s != nil, "Second not found")
	if s == nil {
		return
	}
	summary, merr, mmsg := editor.editor_symbol_move(
		f.e, "Second", s, "m.go", "go", src,
		"m.go", "go", src, nil, "end", .Move,
	)
	testing.expectf(t, merr == .None, "move: %s", mmsg)
	_ = summary
	after := read_fixture_file(f, "m.go")
	defer delete(after, context.allocator)
	testing.expectf(
		t,
		after == "package a\n\n// section: helpers\n\ntype Third struct{}\n\n// Second is a thing.\ntype Second struct{}\n",
		"banner stays, docstring travels: %q",
		after,
	)
}

// Files without a trailing newline have no phantom final line; the end of
// such a file is still a position: end-of-file inserts and last-symbol
// deletes land there instead of failing (and leaving a cross-file move
// half-done).
@(test)
editor_symbol_move_without_trailing_newline :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	// Target without a trailing newline: the insert lands at the end.
	src := "package a\n\ntype Mover struct{}\n"
	write_fixture_file(f, "s.go", src)
	dst := "package a\n\ntype Keeper struct{}" // no trailing newline
	write_fixture_file(f, "t.go", dst)
	roots := build_go_symbols(t, src)
	defer symbol.symbol_forest_destroy(roots, context.allocator)
	mover := find_symbol_named(roots, "Mover")
	testing.expectf(t, mover != nil, "Mover not found")
	if mover == nil {
		return
	}
	_, merr, mmsg := editor.editor_symbol_move(
		f.e, "Mover", mover, "s.go", "go", src,
		"t.go", "go", dst, nil, "end", .Move,
	)
	testing.expectf(t, merr == .None, "insert at EOF: %s", mmsg)
	after_t := read_fixture_file(f, "t.go")
	defer delete(after_t, context.allocator)
	testing.expectf(
		t,
		after_t == "package a\n\ntype Keeper struct{}\n\ntype Mover struct{}\n",
		"target gained the symbol after its last line: %q",
		after_t,
	)
	after_s := read_fixture_file(f, "s.go")
	defer delete(after_s, context.allocator)
	testing.expectf(t, after_s == "package a\n", "source vacated: %q", after_s)

	// Source without a trailing newline: deleting its last symbol reaches
	// one line past the last line.
	lone := "package a\n\ntype Lone struct{}" // no trailing newline
	write_fixture_file(f, "s2.go", lone)
	lone_roots := build_go_symbols(t, lone)
	defer symbol.symbol_forest_destroy(lone_roots, context.allocator)
	lsym := find_symbol_named(lone_roots, "Lone")
	testing.expectf(t, lsym != nil, "Lone not found")
	if lsym == nil {
		return
	}
	dst2 := "package b\n"
	write_fixture_file(f, "t2.go", dst2)
	_, derr, dmsg := editor.editor_symbol_move(
		f.e, "Lone", lsym, "s2.go", "go", lone,
		"t2.go", "go", dst2, nil, "end", .Move,
	)
	testing.expectf(t, derr == .None, "delete last line: %s", dmsg)
	after_s2 := read_fixture_file(f, "s2.go")
	defer delete(after_s2, context.allocator)
	testing.expectf(t, after_s2 == "package a\n", "source vacated to its package line: %q", after_s2)
	after_t2 := read_fixture_file(f, "t2.go")
	defer delete(after_t2, context.allocator)
	testing.expectf(t, after_t2 == "package b\n\ntype Lone struct{}\n", "target received: %q", after_t2)
}

@(test)
svc_read_source_contents_ownership :: proc(t: ^testing.T) {
	// The shared editor-or-disk read behind the LSP producers: the
	// from_editor flag IS the byte ownership (editor allocator vs the
	// caller's arena). One predicate decides both the fallback and the
	// ownership, so an empty-but-successful editor view can never swap
	// arena bytes in under a caller's ed.allocator-keyed defer.
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)
	write_fixture_file(f, "src.txt", "disk bytes\n")

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	abs, _ := filepath.join([]string{f.dir, "src.txt"}, context.temp_allocator)

	// No editor at all: plain disk read on the caller's arena.
	got, owned, rerr := svc.read_source_contents(nil, "src.txt", abs, a)
	testing.expectf(t, rerr == "", "read: %s", rerr)
	testing.expect_value(t, got, "disk bytes\n")
	testing.expect(t, !owned, "nil editor is not editor-owned")

	// An editor with no buffer open still owns its answer: editor_read_file
	// takes the disk snapshot itself on the editor's allocator — the caller
	// frees through ed.allocator exactly when the flag is set (done here).
	got2, owned2, rerr2 := svc.read_source_contents(f.e, "src.txt", abs, a)
	testing.expectf(t, rerr2 == "", "read 2: %s", rerr2)
	testing.expect_value(t, got2, "disk bytes\n")
	testing.expect(t, owned2, "editor read is editor-owned")
	delete(got2, f.e.allocator)

	// A failing read keeps the ownership false: the caller's defer must
	// never free error-path bytes through the editor allocator.
	_, owned3, rerr3 := svc.read_source_contents(nil, "gone.txt", "/nonexistent/gone.txt", a)
	testing.expect(t, rerr3 != "", "missing file errors")
	testing.expect(t, !owned3, "failure keeps ownership false")
}

@(test)
editor_crlf_position_offsets :: proc(t: ^testing.T) {
	// An LSP-supplied edit can reintroduce \r\n after the read side folded
	// CRLF to LF; the stored line views hide the \r, so line/col ->
	// byte-offset math must count the wider separator (regression: the
	// flat "+1" per line drifted one byte per preceding CRLF line).
	// Heap-allocated like every production buffer: file_buffer_destroy
	// frees the struct itself.
	buf := new(editor.File_Buffer, context.allocator)
	editor.file_buffer_init(buf, "a.txt", "one\r\ntwo\r\nthree", context.allocator)
	defer editor.file_buffer_destroy(buf)

	testing.expect(t, len(buf.lines) == 3, "three lines")
	testing.expect(
		t,
		buf.line_seps[0] == 2 && buf.line_seps[1] == 2,
		"CRLF separators record width 2",
	)

	off0, ok0 := editor.position_offset(buf, 0, 0)
	off2, ok2 := editor.position_offset(buf, 2, 0)
	testing.expect(t, ok0 && off0 == 0, "line 0 starts at 0")
	testing.expect(t, ok2 && off2 == 10, "line 2 starts after two CRLF lines (3+2+3+2)")
	testing.expect_value(t, buf.contents[off2:], "three")

	// The edit scope splices at the computed offset — end to end proof
	// that the math and the raw contents agree.
	ef := editor.Edited_File{buf = buf}
	err, msg := editor.edited_insert_text(&ef, 2, 0, ">>")
	testing.expectf(t, err == .None, "insert: %v %s", err, msg)
	testing.expect_value(t, buf.contents, "one\r\ntwo\r\n>>three")
}

// A file whose last byte is a lone '\r' (no '\n' follows) carries it as
// content — the read-side fold only folds complete pairs — so the final
// line's view must keep it and the end-of-line column must resolve past it
// (regression: the final segment took the CRLF strip too, shortening the
// last line view by one byte and landing end-of-file inserts before the
// '\r').
@(test)
editor_final_lone_cr_stays_content :: proc(t: ^testing.T) {
	buf := new(editor.File_Buffer, context.allocator)
	editor.file_buffer_init(buf, "cr.txt", "abc\r", context.allocator)
	defer editor.file_buffer_destroy(buf)

	testing.expect(t, len(buf.lines) == 1, "one line")
	testing.expect_value(t, buf.lines[0], "abc\r")
	off, ok := editor.position_offset(buf, 0, 4)
	testing.expect(t, ok, "end-of-line position accepted")
	testing.expect(t, off == 4, "column past the lone CR resolves at end of content")
	ef := editor.Edited_File{buf = buf}
	err, msg := editor.edited_insert_text(&ef, 0, 4, "!")
	testing.expectf(t, err == .None, "insert: %v %s", err, msg)
	testing.expect_value(t, buf.contents, "abc\r!")

	// CRLF lines keep folding their \r out of the view (the terminator a
	// real newline follows is a separator, not content).
	buf2 := new(editor.File_Buffer, context.allocator)
	editor.file_buffer_init(buf2, "crlf.txt", "ab\r\ncd", context.allocator)
	defer editor.file_buffer_destroy(buf2)
	testing.expect(t, len(buf2.lines) == 2, "two lines")
	testing.expect_value(t, buf2.lines[0], "ab")
	off2, ok2 := editor.position_offset(buf2, 1, 0)
	testing.expect(t, ok2 && off2 == 4, "line 1 starts after the CRLF pair")
}

// --- Buffer bound (LRU) ------------------------------------------------------

// editor_bounded_fixture builds an editor with test-injected buffer caps
// (production callers take the EDITOR_MAX_* defaults).
editor_bounded_fixture :: proc(t: ^testing.T, max_buffers: int, max_bytes: int) -> Editor_Fixture {
	dir, err := os.make_directory_temp("", "aubade-edbnd-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	e := new(editor.Editor, context.allocator)
	editor.editor_init(e, dir, .Lf, "", svc.editor_file_io_port(), context.allocator, max_buffers, max_bytes)
	return {dir = dir, e = e}
}

// editor_buffer_bound_evicts_oldest pins the entry cap: beyond
// max_buffers distinct edited files the least recently used buffer drops
// through the ordinary close path (listener notified), the just-edited
// file is spared, and a later edit of a dropped file re-reads from disk
// with the saved state intact.
@(test)
editor_buffer_bound_evicts_oldest :: proc(t: ^testing.T) {
	f := editor_bounded_fixture(t, 3, 1 << 30)
	defer editor_fixture_destroy(f)

	closed := make([dynamic]string, 0, 8, context.allocator)
	defer {
		for p in closed {
			delete(p)
		}
		delete(closed)
	}
	listener := editor.Buffer_Listener{
		on_close = proc(user: rawptr, rel_path: string) {
			c := cast(^[dynamic]string)user
			append(c, strings.clone(rel_path, context.allocator))
		},
		user = &closed,
	}
	editor.editor_set_listener(f.e, listener)

	names := []string{"f0.txt", "f1.txt", "f2.txt", "f3.txt"}
	for name in names {
		write_fixture_file(f, name, "x\n")
	}
	for name in names {
		eerr, emsg := editor.editor_insert_at_line(f.e, name, 0, "// touch\n")
		testing.expectf(t, eerr == .None, "insert %s: %s", name, emsg)
	}
	testing.expect_value(t, len(f.e.buffers), 3)
	_, f0_in := f.e.buffers["f0.txt"]
	_, f3_in := f.e.buffers["f3.txt"]
	testing.expect(t, !f0_in, "oldest buffer must be evicted")
	testing.expect(t, f3_in, "just-edited buffer must stay")
	testing.expect_value(t, len(closed), 1)
	testing.expect_value(t, closed[0], "f0.txt")

	// Re-editting the evicted file reloads from disk: the first edit's
	// save is the on-disk state the fresh buffer adopts.
	eerr, emsg := editor.editor_insert_at_line(f.e, "f0.txt", 0, "// touch\n")
	testing.expectf(t, eerr == .None, "re-insert f0: %s", emsg)
	after := read_fixture_file(f, "f0.txt")
	defer delete(after)
	testing.expect_value(t, after, "// touch\n// touch\nx\n")
	testing.expect_value(t, len(f.e.buffers), 3)
	testing.expect_value(t, len(closed), 2)
	testing.expect_value(t, closed[1], "f1.txt")
}

// editor_buffer_bound_bytes pins the byte cap: once the charged total
// exceeds max_bytes the oldest buffer drops, however few entries there
// are.
@(test)
editor_buffer_bound_bytes :: proc(t: ^testing.T) {
	f := editor_bounded_fixture(t, 64, 400)
	defer editor_fixture_destroy(f)

	pad: [120]u8
	for i in 0..<len(pad) {
		pad[i] = 'a'
	}
	write_fixture_file(f, "b0.txt", transmute(string)pad[:])
	write_fixture_file(f, "b1.txt", transmute(string)pad[:])

	// One edited buffer charges ~263 bytes (contents + path + fixed) —
	// under the 400 cap; a second crosses it and drops the first.
	eerr, emsg := editor.editor_insert_at_line(f.e, "b0.txt", 0, "// t\n")
	testing.expectf(t, eerr == .None, "insert b0: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)
	eerr, emsg = editor.editor_insert_at_line(f.e, "b1.txt", 0, "// t\n")
	testing.expectf(t, eerr == .None, "insert b1: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)
	_, b1_in := f.e.buffers["b1.txt"]
	testing.expect(t, b1_in, "the just-edited buffer survives the byte cap")
	testing.expectf(t, f.e.buffer_bytes <= 400, "ledger must be back under the cap, got %d", f.e.buffer_bytes)
}

// editor_buffer_bound_oversize_stays pins the overshoot rule: a buffer
// whose own cost exceeds max_bytes stays resident while it is the file
// being edited, and ages out for the next file once it is the oldest.
@(test)
editor_buffer_bound_oversize_stays :: proc(t: ^testing.T) {
	f := editor_bounded_fixture(t, 8, 64)
	defer editor_fixture_destroy(f)

	write_fixture_file(f, "o0.txt", "0123456789")
	write_fixture_file(f, "o1.txt", "0123456789")

	eerr, emsg := editor.editor_insert_at_line(f.e, "o0.txt", 0, "// t\n")
	testing.expectf(t, eerr == .None, "insert o0: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)
	testing.expect(t, f.e.buffer_bytes > 64, "oversize single buffer stays over the cap")

	// The next edit makes o0 the oldest non-keep entry: it drops even
	// though the survivor alone still exceeds the cap.
	eerr, emsg = editor.editor_insert_at_line(f.e, "o1.txt", 0, "// t\n")
	testing.expectf(t, eerr == .None, "insert o1: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)
	_, o1_in := f.e.buffers["o1.txt"]
	testing.expect(t, o1_in, "the just-edited buffer stays")
}

// editor_buffer_lru_touch_reorders pins the recency rule: re-editing and
// plain reads both promote a buffer, so eviction always takes the least
// recently used file, not the least recently created one.
@(test)
editor_buffer_lru_touch_reorders :: proc(t: ^testing.T) {
	f := editor_bounded_fixture(t, 2, 1 << 30)
	defer editor_fixture_destroy(f)

	names := []string{"t0.txt", "t1.txt"}
	for name in names {
		write_fixture_file(f, name, "x\n")
		eerr, emsg := editor.editor_insert_at_line(f.e, name, 0, "// t\n")
		testing.expectf(t, eerr == .None, "insert %s: %s", name, emsg)
	}

	// A read of the older file promotes it above t1.
	read, rerr, _ := editor.editor_read_file(f.e, "t0.txt")
	testing.expectf(t, rerr == .None, "read t0: %v", rerr)
	delete(read, context.allocator)

	write_fixture_file(f, "t2.txt", "x\n")
	eerr, emsg := editor.editor_insert_at_line(f.e, "t2.txt", 0, "// t\n")
	testing.expectf(t, eerr == .None, "insert t2: %s", emsg)

	testing.expect_value(t, len(f.e.buffers), 2)
	_, t0_in := f.e.buffers["t0.txt"]
	_, t1_in := f.e.buffers["t1.txt"]
	_, t2_in := f.e.buffers["t2.txt"]
	testing.expect(t, t0_in, "the read-promoted buffer stays")
	testing.expect(t, !t1_in, "the untouched buffer is the eviction victim")
	testing.expect(t, t2_in, "the just-edited buffer stays")
}

// editor_buffer_ledger_matches_contents pins the byte ledger: after a
// sequence of growing and shrinking edits every slot's charge equals its
// buffer's recomputed cost, the charges sum to the ledger, and the LRU
// covers exactly the open buffers.
@(test)
editor_buffer_ledger_matches_contents :: proc(t: ^testing.T) {
	f := editor_fixture(t, .Lf)
	defer editor_fixture_destroy(f)

	write_fixture_file(f, "g0.txt", "alpha\n")
	write_fixture_file(f, "g1.txt", "beta\n")
	names := []string{"g0.txt", "g1.txt"}
	for name in names {
		eerr, emsg := editor.editor_insert_at_line(f.e, name, 0, "// grown a lot\n")
		testing.expectf(t, eerr == .None, "insert %s: %s", name, emsg)
	}
	eerr, emsg := editor.editor_delete_lines(f.e, "g1.txt", 0, 0)
	testing.expectf(t, eerr == .None, "delete g1: %s", emsg)
	eerr, emsg = editor.editor_replace_content(f.e, "g0.txt", "alpha", "a", "literal", false)
	testing.expectf(t, eerr == .None, "replace g0: %s", emsg)

	sum := 0
	for slot in f.e.lru {
		cost := editor.buffer_cost(slot.buf)
		testing.expectf(
			t,
			slot.cost == cost,
			"slot %s: charged %d, recomputed %d",
			slot.buf.rel_path,
			slot.cost,
			cost,
		)
		sum += slot.cost
	}
	testing.expectf(t, sum == f.e.buffer_bytes, "ledger %d != slot sum %d", f.e.buffer_bytes, sum)
	testing.expect_value(t, len(f.e.lru), len(f.e.buffers))
}

// editor_edit_ctx_tracks_buffer_bound pins the multi-step edit path
// (symbol_edit's editor_edit_ctx): its buffers join the same LRU and the
// same prune runs after the transaction.
@(test)
editor_edit_ctx_tracks_buffer_bound :: proc(t: ^testing.T) {
	f := editor_bounded_fixture(t, 1, 1 << 30)
	defer editor_fixture_destroy(f)

	job_insert :: proc(ef: ^editor.Edited_File, user: rawptr) -> (err: editor.Editor_Err, msg: string) {
		return editor.edited_insert_text(ef, 0, 0, "// job\n")
	}

	write_fixture_file(f, "x.txt", "x\n")
	write_fixture_file(f, "y.txt", "y\n")
	eerr, emsg := editor.editor_edit_ctx(f.e, "x.txt", {apply = job_insert})
	testing.expectf(t, eerr == .None, "ctx x: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)
	eerr, emsg = editor.editor_edit_ctx(f.e, "y.txt", {apply = job_insert})
	testing.expectf(t, eerr == .None, "ctx y: %s", emsg)
	testing.expect_value(t, len(f.e.buffers), 1)
	_, y_in := f.e.buffers["y.txt"]
	testing.expect(t, y_in, "the ctx-edited buffer stays under a 1-file cap")
	after := read_fixture_file(f, "y.txt")
	defer delete(after)
	testing.expect_value(t, after, "// job\ny\n")
}

// --- the reload-stat gate ----------------------------------------------------

// Counting_IO delegates to the production file-IO implementations while
// counting port reads and stats, so a test can pin the buffered-read gate:
// an unchanged (mtime_ns, size) record skips the full read entirely.
Counting_IO :: struct {
	reads: int,
	stats: int,
}

counting_read :: proc(user: rawptr, abs_path: string, max_bytes: i64, alloc: mem.Allocator) -> (data: []u8, err: editor.Editor_Err, msg: string) {
	c := cast(^Counting_IO)user
	c.reads += 1
	return svc.editor_file_read(user, abs_path, max_bytes, alloc)
}

counting_write :: proc(user: rawptr, abs_path: string, data: []u8) -> (err: editor.Editor_Err, msg: string) {
	return svc.editor_file_write(user, abs_path, data)
}

counting_stat :: proc(user: rawptr, abs_path: string) -> (mtime_ns: i64, size: i64, ok: bool) {
	c := cast(^Counting_IO)user
	c.stats += 1
	return svc.editor_file_stat(user, abs_path)
}

// A buffered read whose recorded disk stat still matches skips the port
// read; any stat drift (size here, so the mismatch is deterministic) adopts
// the external bytes exactly as before the gate existed.
@(test)
editor_buffer_hit_gates_on_disk_stat :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-editor-stat-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	c := new(Counting_IO, context.allocator)
	defer free(c, context.allocator)
	e := new(editor.Editor, context.allocator)
	f := Editor_Fixture{dir = dir, e = e}
	defer editor_fixture_destroy(f)
	editor.editor_init(e, dir, .Lf, "", {
		user  = c,
		read  = counting_read,
		write = counting_write,
		stat  = counting_stat,
	}, context.allocator)

	write_fixture_file(f, "gate.txt", "one\ntwo\n")

	// Unbuffered read: one port read, no probe.
	contents, rerr, rmsg := editor.editor_read_file(f.e, "gate.txt")
	testing.expectf(t, rerr == .None, "read: %s", rmsg)
	delete(contents)
	testing.expect_value(t, c.reads, 1)

	// The edit creates the buffer (one snapshot read) and saves; the save
	// drops the stat record, so the owning-editor read re-probes once.
	eerr, emsg := editor.editor_replace_lines(f.e, "gate.txt", 0, 0, "TOP\n")
	testing.expectf(t, eerr == .None, "replace: %s", emsg)
	testing.expect_value(t, c.reads, 2)
	contents, rerr, rmsg = editor.editor_read_file(f.e, "gate.txt")
	testing.expectf(t, rerr == .None, "probe read: %s", rmsg)
	delete(contents)
	testing.expect_value(t, c.reads, 3)
	testing.expect_value(t, c.stats, 1)

	// Unchanged disk: the gate answers from the record — no port read.
	contents, rerr, rmsg = editor.editor_read_file(f.e, "gate.txt")
	testing.expectf(t, rerr == .None, "gated read: %s", rmsg)
	testing.expect_value(t, contents, "TOP\ntwo\n")
	delete(contents)
	testing.expectf(t, c.reads == 3, "unchanged-stat read must not touch the port (reads=%d)", c.reads)
	testing.expect_value(t, c.stats, 2)

	// An external rewrite of a different size punches through the gate and
	// is adopted (the pre-gate external-change contract).
	write_fixture_file(f, "gate.txt", "externally\nrewritten\n")
	contents, rerr, rmsg = editor.editor_read_file(f.e, "gate.txt")
	testing.expectf(t, rerr == .None, "adopt read: %s", rmsg)
	defer delete(contents)
	testing.expect_value(t, contents, "externally\nrewritten\n")
	testing.expect_value(t, c.reads, 4)
	testing.expect_value(t, c.stats, 3)

	// The adoption re-recorded the new stat: the next read gates again.
	tail: string
	tail, rerr, rmsg = editor.editor_read_file(f.e, "gate.txt")
	testing.expectf(t, rerr == .None, "post-adoption read: %s", rmsg)
	delete(tail)
	testing.expectf(t, c.reads == 4, "post-adoption read must gate (reads=%d)", c.reads)
	testing.expect_value(t, c.stats, 4)
}

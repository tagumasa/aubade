// Tests for the syntax diagnostics walk: clean sources yield nothing, an
// invalid token lands inside an ERROR diagnostic, missing-token recovery
// yields zero-width MISSING diagnostics, ordering and bounds hold, and
// the destroy path releases without leaks. Fixtures parse Go — the
// grammar every other ts test pins its expectations against.
package tests

import "core:strings"
import "core:testing"
import "src:ts"

// diag_check_flat asserts the invariants every diagnostics array must
// hold: spans inside the source, starts ascending (non-strictly — a
// container and its first child can share a start byte), messages
// matching the kind, and MISSING entries zero-width.
diag_check_flat :: proc(t: ^testing.T, diags: []ts.Diagnostic, source_len: int) {
	for i in 0..<len(diags) {
		d := &diags[i]
		testing.expectf(
			t,
			int(d.start_byte) <= int(d.end_byte) && int(d.end_byte) <= source_len,
			"diagnostic %d span [%d,%d) escapes a %d-byte source",
			i, d.start_byte, d.end_byte, source_len,
		)
		if i > 0 {
			testing.expectf(
				t,
				d.start_byte >= diags[i - 1].start_byte,
				"diagnostic %d starts before diagnostic %d",
				i, i - 1,
			)
		}
		switch d.kind {
		case .Error:
			testing.expect_value(t, d.message, ts.DIAG_MESSAGE_ERROR)
		case .Missing:
			testing.expect_value(t, d.message, ts.DIAG_MESSAGE_MISSING)
			testing.expectf(t, d.start_byte == d.end_byte, "missing diagnostic %d is not zero-width", i)
		}
	}
}

@(test)
ts_diagnostics_clean_source :: proc(t: ^testing.T) {
	res, err := ts.parse("package main\n\nfunc hello() {}\n", "go")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	diags := ts.diagnostics_tree(res.tree, context.allocator)
	testing.expect(t, diags == nil, "clean source must yield no diagnostics")
	ts.diagnostics_destroy(diags)

	// The destroy path is a safe no-op on nil (a declined or clean walk).
	ts.diagnostics_destroy(nil)
}

@(test)
ts_diagnostics_nil_tree :: proc(t: ^testing.T) {
	testing.expect(t, ts.diagnostics_tree(nil) == nil, "a nil tree yields no diagnostics")
}

@(test)
ts_diagnostics_empty_source :: proc(t: ^testing.T) {
	// An empty file parses to a zero-extent source_file with no damage.
	res, err := ts.parse("", "go")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	diags := ts.diagnostics_tree(res.tree, context.allocator)
	testing.expect(t, diags == nil, "empty source must yield no diagnostics")
	ts.diagnostics_destroy(diags)
}

@(test)
ts_diagnostics_error_token :: proc(t: ^testing.T) {
	// '@' matches no Go token anywhere, so the lexer cannot place it: the
	// byte can only enter the tree inside an ERROR node.
	code := "package main\n\nfunc main() {\n\tprintln(\"ok\")\n\t@\n}\n"
	res, err := ts.parse(code, "go")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	diags := ts.diagnostics_tree(res.tree, context.allocator)
	defer ts.diagnostics_destroy(diags)
	diag_check_flat(t, diags, len(code))

	at := strings.index_byte(code, '@')
	testing.expectf(t, at >= 0, "fixture lost its stray token")
	covered := false
	for i in 0..<len(diags) {
		if diags[i].kind == .Error && int(diags[i].start_byte) <= at && at < int(diags[i].end_byte) {
			covered = true
			break
		}
	}
	testing.expect(t, covered, "no ERROR diagnostic covers the invalid byte")

	// tree-sitter stacks an outer and an inner ERROR with the same extent
	// on an unplaceable token; the walk collapses them to one.
	testing.expectf(t, len(diags) == 1, "expected 1 diagnostic, got %d", len(diags))
	if len(diags) == 1 {
		testing.expect_value(t, diags[0].kind, ts.Diagnostic_Kind.Error)
		testing.expectf(t, int(diags[0].start_byte) == at && int(diags[0].end_byte) == at+1,
			"error span [%d,%d), want [%d,%d)", diags[0].start_byte, diags[0].end_byte, at, at+1)
	}
}

@(test)
ts_diagnostics_missing_token :: proc(t: ^testing.T) {
	// A short variable declaration with no right-hand side: the minimal
	// recovery inserts the absent token rather than skipping the closing
	// brace, which tree-sitter records as a zero-width MISSING leaf.
	code := "package main\n\nfunc main() {\n\tx :=\n}\n"
	res, err := ts.parse(code, "go")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	diags := ts.diagnostics_tree(res.tree, context.allocator)
	defer ts.diagnostics_destroy(diags)
	diag_check_flat(t, diags, len(code))

	// This shape recovers by insertion: the absent expression becomes a
	// zero-width MISSING leaf rather than an ERROR.
	missing := 0
	for i in 0..<len(diags) {
		if diags[i].kind == .Missing {
			missing += 1
		}
	}
	testing.expectf(t, missing >= 1, "expected a MISSING diagnostic, got %d diagnostics", len(diags))
}

@(test)
ts_diagnostics_unbalanced_brace :: proc(t: ^testing.T) {
	// EOF inside an open block: recovery wraps the incomplete tail in an
	// ERROR region or inserts the missing `}` — at least one diagnostic
	// either way.
	code := "package main\n\nfunc main() {\n\tprintln(\"unbalanced\")\n"
	res, err := ts.parse(code, "go")
	testing.expectf(t, err == "", "parse: %s", err)
	defer ts.parse_release(&res)

	diags := ts.diagnostics_tree(res.tree, context.allocator)
	defer ts.diagnostics_destroy(diags)
	diag_check_flat(t, diags, len(code))

	// An ERROR diagnostic implies the C error flag; the flag never
	// implies a diagnostic, because it cannot see MISSING nodes.
	has_error_diag := false
	for i in 0..<len(diags) {
		if diags[i].kind == .Error {
			has_error_diag = true
			break
		}
	}
	if has_error_diag {
		testing.expect(t, ts.node_has_error(ts.parse_root(&res)), "C error flag must agree with an ERROR diagnostic")
	}
	testing.expect(t, len(diags) >= 1, "an unbalanced brace must yield at least one diagnostic")
}

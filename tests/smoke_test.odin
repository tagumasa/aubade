// Smoke tests: core behaviors the codebase depends on, kept as the first
// green test on every platform.
package tests

import "core:path/filepath"
import "core:testing"
import "src:ts"

@(test)
string_iteration_yields_rune_then_byte_index :: proc(t: ^testing.T) {
	first_rune: rune = 0
	first_index := -1
	count := 0
	for c, i in "aubade" {
		if count == 0 {
			first_rune = c
			first_index = i
		}
		count += 1
	}
	// Odin string iteration binds (rune, byte_index): the rune comes first.
	// The build tools rely on this order when copying paths into fixed buffers.
	testing.expect_value(t, first_rune, 'a')
	testing.expect_value(t, first_index, 0)
	testing.expect_value(t, count, 6)
}

@(test)
filepath_join_stays_relative :: proc(t: ^testing.T) {
	joined, err := filepath.join([]string{".", "aubade-endpoint.json"}, context.allocator)
	testing.expect(t, err == nil, "join must succeed")
	// A relative first element must not be absolutized; the runtime file
	// joins (endpoint publication, lock paths) depend on this.
	testing.expect_value(t, joined, "aubade-endpoint.json")
	delete(joined)
}

@(test)
grammar_names_are_unique :: proc(t: ^testing.T) {
	// Mirrors the invariant of tools/build's grammar table: unique language
	// ids. Duplicated here so the test suite is self-contained (package
	// main cannot be imported).
	table := ts.GRAMMARS
	seen := make(map[string]bool)
	defer delete(seen)
	for i in 0..<len(table) {
		testing.expectf(t, !seen[table[i].name], "duplicate grammar name %q", table[i].name)
		seen[table[i].name] = true
	}
	// The floor guards against a truncated registry (a stub or partial
	// table), not the exact size: the grammar count is a licensing-driven
	// curation decision that has moved 206 -> 187.
	testing.expectf(t, len(table) >= 180, "expected the full grammar registry, got %d", len(table))
}

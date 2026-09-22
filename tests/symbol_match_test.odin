// The index matching rule's units: name_component_matches (exact by
// default with ASCII case folding, `*`-only glob otherwise) and the
// workspace/symbol top-up filter that reuses it. The handler-level
// behavior these feed lives in symbol_find_semantics_test.
package tests

import "core:testing"
import "src:symbol"

@(test)
name_component_matches_exact :: proc(t: ^testing.T) {
	testing.expect_value(t, symbol.name_component_matches("mono_ns", "mono_ns"), true)
	testing.expect_value(t, symbol.name_component_matches("mono_ns", "MONO_NS"), true)
	testing.expect_value(t, symbol.name_component_matches("MONO_NS", "mono_ns"), true)
	// Exact means whole-name: prefixes and suffixes of a longer name do
	// not hit — the subsequence behavior that motivated the rule is gone.
	testing.expect_value(t, symbol.name_component_matches("mono_ns", "mono_clock"), false)
	testing.expect_value(t, symbol.name_component_matches("mono_ns", "symbol_range_from_contents"), false)
	testing.expect_value(t, symbol.name_component_matches("mono_ns", "xmono_nsx"), false)
	testing.expect_value(t, symbol.name_component_matches("", ""), true)
	testing.expect_value(t, symbol.name_component_matches("", "x"), false)
	testing.expect_value(t, symbol.name_component_matches("x", ""), false)
}

@(test)
name_component_matches_glob :: proc(t: ^testing.T) {
	testing.expect_value(t, symbol.name_component_matches("mono_*", "mono_ns"), true)
	testing.expect_value(t, symbol.name_component_matches("mono_*", "mono_clock"), true)
	testing.expect_value(t, symbol.name_component_matches("mono_*", "symbol_range_from_contents"), false)
	testing.expect_value(t, symbol.name_component_matches("*_ns", "mono_ns"), true)
	testing.expect_value(t, symbol.name_component_matches("*_ns", "mono_clock"), false)
	testing.expect_value(t, symbol.name_component_matches("*o_*s", "mono_ns"), true)
	testing.expect_value(t, symbol.name_component_matches("m*o_ns", "mo_ns"), true)
	testing.expect_value(t, symbol.name_component_matches("m*o_ns", "m_ns"), false)
	testing.expect_value(t, symbol.name_component_matches("*", "anything"), true)
	testing.expect_value(t, symbol.name_component_matches("MONO_*", "mono_ns"), true)
}

@(test)
name_component_matches_literals :: proc(t: ^testing.T) {
	// Only `*` is special on the index path: `?`, `%`, and `_` match
	// literally (mirroring the store's escaped LIKE translation).
	testing.expect_value(t, symbol.name_component_matches("a?b", "a?b"), true)
	testing.expect_value(t, symbol.name_component_matches("a?b", "axb"), false)
	testing.expect_value(t, symbol.name_component_matches("a%b", "a%b"), true)
	testing.expect_value(t, symbol.name_component_matches("a%b", "axb"), false)
	testing.expect_value(t, symbol.name_component_matches("a_b", "a_b"), true)
	testing.expect_value(t, symbol.name_component_matches("a_b", "axb"), false)
}

@(test)
index_topup_row_matches_rule :: proc(t: ^testing.T) {
	// One plain component: an exact (or glob) name match admits the row.
	testing.expect_value(t, symbol.index_topup_row_matches({"mono_ns"}, false, "MONO_NS", ""), true)
	testing.expect_value(t, symbol.index_topup_row_matches({"mono_*"}, false, "mono_clock", ""), true)
	testing.expect_value(t, symbol.index_topup_row_matches({"mono_ns"}, false, "symbol_range_from_contents", ""), false)
	// Two relative components: the container must match the outer one.
	testing.expect_value(t, symbol.index_topup_row_matches({"Foo", "bar"}, false, "bar", "Foo"), true)
	testing.expect_value(t, symbol.index_topup_row_matches({"Foo", "bar"}, false, "bar", "Other"), false)
	// Anchored and deeper-than-two forms cannot be verified from
	// SymbolInformation's single container level — no top-up row qualifies.
	testing.expect_value(t, symbol.index_topup_row_matches({"foo"}, true, "Foo", ""), false)
	testing.expect_value(t, symbol.index_topup_row_matches({"A", "B", "c"}, false, "c", "B"), false)
	testing.expect_value(t, symbol.index_topup_row_matches({"/", "A", "c"}, true, "c", "A"), false)
}

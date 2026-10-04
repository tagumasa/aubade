// Tests for the capture-name to semantic-token mapping and the legend
// derived from it: exact and longest-match lookup, unknown-capture skip,
// curated odin/go rows, and the invariant that the legend is exactly the
// set of types and modifiers the mapping tables can emit, in LSP
// standard order.
package tests

import "core:testing"
import "src:lspserver"
import "src:ts"

ST_ODIN_CAPTURES :: []string{
	"attribute",
	"boolean",
	"character",
	"comment",
	"conditional",
	"conditional.ternary",
	"constant",
	"constant.builtin",
	"error",
	"field",
	"float",
	"function",
	"function.call",
	"function.macro",
	"include",
	"keyword",
	"keyword.function",
	"keyword.operator",
	"keyword.return",
	"label",
	"namespace",
	"number",
	"operator",
	"parameter",
	"preproc",
	"punctuation.bracket",
	"punctuation.delimiter",
	"punctuation.special",
	"repeat",
	"spell",
	"storageclass",
	"string",
	"string.escape",
	"type",
	"type.builtin",
	"variable",
	"variable.builtin",
}

ST_GO_CAPTURES :: []string{
	"comment",
	"constant.builtin",
	"escape",
	"function",
	"function.builtin",
	"function.method",
	"keyword",
	"number",
	"operator",
	"property",
	"string",
	"type",
	"variable",
}

// Capture names with no mapping. escape is a root name with no mapped
// ancestor; the rest have no defensible standard type. (Dotted escape
// names such as string.escape are NOT skipped: the longest-match lookup
// resolves them through their parent string entry, by design.)
ST_UNMAPPED :: []string{
	"error",
	"label",
	"punctuation.bracket",
	"punctuation.delimiter",
	"punctuation.special",
	"spell",
	"escape",
}

ST_STANDARD_TYPE_NAMES :: []string{
	"namespace",
	"type",
	"class",
	"enum",
	"interface",
	"struct",
	"typeParameter",
	"parameter",
	"variable",
	"property",
	"enumMember",
	"event",
	"function",
	"method",
	"macro",
	"keyword",
	"modifier",
	"comment",
	"string",
	"number",
	"regexp",
	"operator",
	"decorator",
}

ST_STANDARD_MODIFIER_NAMES :: []string{
	"declaration",
	"definition",
	"readonly",
	"static",
	"deprecated",
	"abstract",
	"async",
	"modification",
	"documentation",
	"defaultLibrary",
}

St_Mapping_Expect :: struct {
	capture:   string,
	token:     lspserver.Token_Type,
	modifiers: lspserver.Token_Modifier_Set,
}

st_expect_mapping :: proc(t: ^testing.T, e: St_Mapping_Expect) {
	token, modifiers, found := lspserver.capture_token(e.capture)
	testing.expectf(t, found, "capture %q: expected a mapping", e.capture)
	testing.expectf(t, token == e.token, "capture %q: got type %v, want %v", e.capture, token, e.token)
	testing.expectf(t, modifiers == e.modifiers, "capture %q: got modifiers %v, want %v", e.capture, modifiers, e.modifiers)
}

st_contains :: proc(names: []string, name: string) -> bool {
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}

// Exact match: a plain capture name resolves directly.
@(test)
st_lookup_exact_match :: proc(t: ^testing.T) {
	st_expect_mapping(t, St_Mapping_Expect{capture = "variable", token = .Variable})
	st_expect_mapping(t, St_Mapping_Expect{capture = "module.builtin", token = .Namespace, modifiers = {.Default_Library}})
}

// Longest match: a dotted name with no exact entry falls back through
// its dot hierarchy — "function.method.call" through "function.method",
// "keyword.operator.logical" through "keyword.operator".
@(test)
st_lookup_dotted_fallback :: proc(t: ^testing.T) {
	st_expect_mapping(t, St_Mapping_Expect{capture = "function.method.call", token = .Method})
	st_expect_mapping(t, St_Mapping_Expect{capture = "keyword.operator.logical", token = .Keyword})
}

// A capture with no entry at any hierarchy level reports no-match so the
// caller skips it — including the documented unmapped names.
@(test)
st_lookup_unknown_skips :: proc(t: ^testing.T) {
	unmapped := []string{"pneumonoultramilkshaker", "frobnicate.deeper.still", "spell", "error", "punctuation.bracket", "escape"}
	for name in unmapped {
		_, _, found := lspserver.capture_token(name)
		testing.expectf(t, !found, "capture %q: expected no mapping", name)
	}
}

// Curated odin rows: representative captures assert their mapped type
// and modifiers.
@(test)
st_curated_odin_entries :: proc(t: ^testing.T) {
	st_expect_mapping(t, St_Mapping_Expect{capture = "storageclass", token = .Keyword})
	st_expect_mapping(t, St_Mapping_Expect{capture = "function.macro", token = .Macro})
	st_expect_mapping(t, St_Mapping_Expect{capture = "field", token = .Property})
	st_expect_mapping(t, St_Mapping_Expect{capture = "attribute", token = .Decorator})
	st_expect_mapping(t, St_Mapping_Expect{capture = "type.builtin", token = .Type, modifiers = {.Default_Library}})
	st_expect_mapping(t, St_Mapping_Expect{capture = "constant.builtin", token = .Variable, modifiers = {.Readonly, .Default_Library}})
}

// Curated go rows: representative captures assert their mapped type and
// modifiers.
@(test)
st_curated_go_entries :: proc(t: ^testing.T) {
	st_expect_mapping(t, St_Mapping_Expect{capture = "function.method", token = .Method})
	st_expect_mapping(t, St_Mapping_Expect{capture = "function.builtin", token = .Function, modifiers = {.Default_Library}})
	st_expect_mapping(t, St_Mapping_Expect{capture = "property", token = .Property})
}

// Every capture in the pinned odin and go highlight queries is either
// mapped or in the documented unmapped set — the curated coverage
// contract, checked name by name.
@(test)
st_curated_vocabulary_complete :: proc(t: ^testing.T) {
	tables := [][]string{ST_ODIN_CAPTURES, ST_GO_CAPTURES}
	for table in tables {
		for name in table {
			_, _, found := lspserver.capture_token(name)
			testing.expectf(t, found == !st_contains(ST_UNMAPPED, name), "capture %q: mapped=%v, want %v", name, found, !st_contains(ST_UNMAPPED, name))
		}
	}
}

// The enum members spell the LSP 3.17 standard vocabularies in
// specification order.
@(test)
st_standard_vocabulary_order :: proc(t: ^testing.T) {
	testing.expectf(t, lspserver.TOKEN_TYPE_COUNT == len(ST_STANDARD_TYPE_NAMES), "token type count %v, want %v", lspserver.TOKEN_TYPE_COUNT, len(ST_STANDARD_TYPE_NAMES))
	testing.expectf(t, lspserver.TOKEN_MODIFIER_COUNT == len(ST_STANDARD_MODIFIER_NAMES), "token modifier count %v, want %v", lspserver.TOKEN_MODIFIER_COUNT, len(ST_STANDARD_MODIFIER_NAMES))
	type_names := ST_STANDARD_TYPE_NAMES
	modifier_names := ST_STANDARD_MODIFIER_NAMES
	for i in 0 ..< lspserver.TOKEN_TYPE_COUNT {
		testing.expectf(t, lspserver.token_type_name(lspserver.Token_Type(i)) == type_names[i],
			"token type %v: got %q, want %q", i, lspserver.token_type_name(lspserver.Token_Type(i)), type_names[i])
	}
	for i in 0 ..< lspserver.TOKEN_MODIFIER_COUNT {
		testing.expectf(t, lspserver.token_modifier_name(lspserver.Token_Modifier(i)) == modifier_names[i],
			"token modifier %v: got %q, want %q", i, lspserver.token_modifier_name(lspserver.Token_Modifier(i)), modifier_names[i])
	}
}

// The legend is exactly the set of types and modifiers the mapping
// tables can emit, in standard order — derived, not declared beside the
// tables. Legend indices and modifier bits rank the emitted subset only.
@(test)
st_legend_is_table_derived :: proc(t: ^testing.T) {
	seen_types: bit_set[lspserver.Token_Type]
	seen_modifiers: bit_set[lspserver.Token_Modifier]
	tables := [][]lspserver.Capture_Token{lspserver.CURATED_CAPTURES, lspserver.GENERIC_CAPTURES}
	for table in tables {
		for entry in table {
			seen_types |= {entry.token}
			for m in lspserver.Token_Modifier {
				if m in entry.modifiers {
					seen_modifiers |= {m}
				}
			}
		}
	}

	types, type_count := lspserver.legend_token_types()
	legend_types_set: bit_set[lspserver.Token_Type]
	for i in 0 ..< type_count {
		legend_types_set |= {types[i]}
	}
	testing.expect(t, legend_types_set == seen_types)
	for i in 1 ..< type_count {
		testing.expectf(t, int(types[i - 1]) < int(types[i]), "legend types out of standard order at %v", i)
	}

	modifiers, modifier_count := lspserver.legend_token_modifiers()
	legend_modifiers_set: bit_set[lspserver.Token_Modifier]
	for i in 0 ..< modifier_count {
		legend_modifiers_set |= {modifiers[i]}
	}
	testing.expect(t, legend_modifiers_set == seen_modifiers)
	for i in 1 ..< modifier_count {
		testing.expectf(t, int(modifiers[i - 1]) < int(modifiers[i]), "legend modifiers out of standard order at %v", i)
	}

	// The exact emitted subsets, pinned: standard types with no mapping
	// (class, enum, interface, struct, typeParameter, enumMember, event,
	// modifier) stay out of the legend, and so do the standard modifiers
	// no entry carries.
	expected_types := [15]lspserver.Token_Type{.Namespace, .Type, .Parameter, .Variable, .Property, .Function, .Method, .Macro, .Keyword, .Comment, .String, .Number, .Regexp, .Operator, .Decorator}
	testing.expectf(t, type_count == len(expected_types), "legend type count %v, want %v", type_count, len(expected_types))
	for i in 0 ..< len(expected_types) {
		testing.expectf(t, types[i] == expected_types[i], "legend type %v: got %v, want %v", i, types[i], expected_types[i])
	}
	expected_modifiers := [4]lspserver.Token_Modifier{.Definition, .Readonly, .Documentation, .Default_Library}
	testing.expectf(t, modifier_count == len(expected_modifiers), "legend modifier count %v, want %v", modifier_count, len(expected_modifiers))
	for i in 0 ..< len(expected_modifiers) {
		testing.expectf(t, modifiers[i] == expected_modifiers[i], "legend modifier %v: got %v, want %v", i, modifiers[i], expected_modifiers[i])
	}

	for i in 0 ..< type_count {
		index, ok := lspserver.legend_type_index(types[i])
		testing.expectf(t, ok && index == i, "legend index of %v: got %v, %v", types[i], index, ok)
	}
	non_emitted_types := []lspserver.Token_Type{.Class, .Enum_Member, .Event}
	for non_emitted in non_emitted_types {
		_, ok := lspserver.legend_type_index(non_emitted)
		testing.expectf(t, !ok, "legend index exists for non-emitted type %v", non_emitted)
	}

	expected_bits := [4]u32{0, 1, 2, 3}
	for i in 0 ..< len(expected_modifiers) {
		bit, ok := lspserver.legend_modifier_bit(expected_modifiers[i])
		testing.expectf(t, ok && bit == expected_bits[i], "legend bit of %v: got %v, %v", expected_modifiers[i], bit, ok)
	}
	_, ok := lspserver.legend_modifier_bit(.Declaration)
	testing.expect(t, !ok)
}

// The per-connection rank cache agrees with the legend procs it derives
// from: every announced member carries the proc's rank, every member the
// mapping tables never emit reads -1 in the cache.
@(test)
st_legend_ranks_match_the_legend_procs :: proc(t: ^testing.T) {
	ranks := lspserver.legend_ranks_build()
	for tt in lspserver.Token_Type {
		index, ok := lspserver.legend_type_index(tt)
		got := ranks.type_rank[int(tt)]
		if ok {
			testing.expectf(t, got == index, "rank of type %v: cache %v, proc %v", tt, got, index)
		} else {
			testing.expectf(t, got == -1, "type %v has no legend rank but the cache holds %v", tt, got)
		}
	}
	for m in lspserver.Token_Modifier {
		bit, ok := lspserver.legend_modifier_bit(m)
		got := ranks.modifier_bit[int(m)]
		if ok {
			testing.expectf(t, got == int(bit), "bit of modifier %v: cache %v, proc %v", m, got, bit)
		} else {
			testing.expectf(t, got == -1, "modifier %v has no legend bit but the cache holds %v", m, got)
		}
	}
}

// End to end: capture names coming out of the real query machinery over
// an odin source resolve through the same lookup, and a capture name
// outside the vocabulary reaches the lookup and is skipped there.
@(test)
st_capture_names_flow_through_lookup :: proc(t: ^testing.T) {
	code := "main :: proc() {\n\tdo_work(42)\n}\n"
	query := "(call_expression function: (identifier) @function.call)\n(identifier) @pneumonoultramilkshaker\n"

	results, qerr, msg := ts.query(code, "odin", query, context.allocator)
	testing.expectf(t, qerr == .None, "odin query failed: %v: %s", qerr, msg)
	defer ts.query_results_destroy(results, context.allocator)

	call_site_captures, unknown_captures := 0, 0
	for result in results {
		for capture in result.captures {
			if capture.name == "function.call" {
				token, modifiers, found := lspserver.capture_token(capture.name)
				testing.expectf(t, found, "capture %q: expected a mapping", capture.name)
				testing.expectf(t, token == .Function && modifiers == {}, "capture %q: got %v %v", capture.name, token, modifiers)
				call_site_captures += 1
			} else if capture.name == "pneumonoultramilkshaker" {
				_, _, found := lspserver.capture_token(capture.name)
				testing.expectf(t, !found, "capture %q: expected no mapping", capture.name)
				unknown_captures += 1
			}
		}
	}
	testing.expectf(t, call_site_captures == 1, "expected one call-site capture, got %v", call_site_captures)
	testing.expectf(t, unknown_captures >= 1, "expected the unknown capture to reach the lookup, got %v", unknown_captures)
}

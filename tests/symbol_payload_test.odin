// Tests for the L1 payload codec: round-trips over a hand-built exotic
// forest (non-ASCII names, overloads, absent ranges, flat container names)
// and a real finalized tree-sitter outline, plus the corruption rejections
// readers rely on to treat bad payloads as cache misses.
package tests

import "core:strings"
import "core:testing"
import "src:symbol"

// build_exotic_forest builds a forest exercising the codec's field surface:
// multi-byte names/details, container_name on a flat symbol, overload
// indices, a leaf without ranges, and a body encode must drop.
build_exotic_forest :: proc(a := context.allocator) -> []^symbol.Symbol {
	outer := symbol.symbol_new(a)
	outer.name = strings.clone("Outer_型", a)
	outer.kind = .Struct
	outer.detail = strings.clone("構造体の詳細 — ダッシュ入り", a)
	outer.body = strings.clone("func body that must not survive the payload", a)
	outer.has_body = true
	outer.range = new(symbol.Range, a)
	outer.range^ = {
		start = {line = 1, character = 4},
		end   = {line = 30, character = 1},
	}
	outer.selection_range = new(symbol.Range, a)
	outer.selection_range^ = {
		start = {line = 1, character = 4},
		end   = {line = 1, character = 13},
	}

	field := symbol.symbol_new(a)
	field.name = strings.clone("fïeld", a)
	field.kind = .Field
	// range/selection_range stay nil: the absent-range path.

	over_a := symbol.symbol_new(a)
	over_a.name = strings.clone("over", a)
	over_a.kind = .Function
	over_a.overload_idx = 0
	over_a.range = new(symbol.Range, a)
	over_a.range^ = {
		start = {line = 5, character = 0},
		end   = {line = 6, character = 0},
	}

	over_b := symbol.symbol_new(a)
	over_b.name = strings.clone("over", a)
	over_b.kind = .Function
	over_b.overload_idx = 1
	over_b.selection_range = new(symbol.Range, a)
	over_b.selection_range^ = {
		start = {line = 8, character = 0},
		end   = {line = 8, character = 4},
	}

	outer.children = make([dynamic]^symbol.Symbol, 0, 3, a)
	append(&outer.children, field)
	append(&outer.children, over_a)
	append(&outer.children, over_b)

	flat := symbol.symbol_new(a)
	flat.name = strings.clone("Flat_Method", a)
	flat.kind = .Method
	flat.container_name = strings.clone("Elsewhere", a)

	roots := make([dynamic]^symbol.Symbol, 0, 2, a)
	append(&roots, outer)
	append(&roots, flat)
	return roots[:]
}

// expect_symbols_equal compares a decoded node against its source: every
// payload column round-trips, parents relink to the decoded tree, and
// bodies are absent (the payload is bodyless by design).
expect_symbols_equal :: proc(t: ^testing.T, want: ^symbol.Symbol, got: ^symbol.Symbol, parent: ^symbol.Symbol) {
	testing.expectf(t, got != nil, "symbol %s decoded to nil", want.name)
	if got == nil {
		return
	}
	testing.expectf(t, got.name == want.name, "name %q != %q", got.name, want.name)
	testing.expectf(t, got.kind == want.kind, "kind %v != %v", got.kind, want.kind)
	testing.expectf(t, got.container_name == want.container_name, "container %q != %q", got.container_name, want.container_name)
	testing.expectf(t, got.detail == want.detail, "detail %q != %q", got.detail, want.detail)
	testing.expectf(t, got.overload_idx == want.overload_idx, "overload %d != %d", got.overload_idx, want.overload_idx)

	if want.range == nil {
		testing.expectf(t, got.range == nil, "symbol %s: range should be absent", want.name)
	} else if got.range != nil {
		testing.expectf(t, got.range^ == want.range^, "symbol %s: range mismatch", want.name)
	}
	if want.selection_range == nil {
		testing.expectf(t, got.selection_range == nil, "symbol %s: selection should be absent", want.name)
	} else if got.selection_range != nil {
		testing.expectf(t, got.selection_range^ == want.selection_range^, "symbol %s: selection mismatch", want.name)
	}

	testing.expectf(t, got.body == "" && !got.has_body, "symbol %s: payload must not carry a body", want.name)
	testing.expectf(t, got.parent == parent, "symbol %s: parent link mismatch", want.name)
	testing.expectf(t, got.location != nil, "symbol %s: location missing", want.name)
	if got.location != nil {
		testing.expectf(t, strings.has_prefix(got.location.uri, "file://"), "symbol %s: uri %q", want.name, got.location.uri)
		if want.location != nil {
			testing.expectf(t, got.location.abs_path == want.location.abs_path, "symbol %s: abs path", want.name)
			testing.expectf(t, got.location.rel_path == want.location.rel_path, "symbol %s: rel path", want.name)
		}
	}

	testing.expectf(t, len(got.children) == len(want.children), "symbol %s: child count %d != %d", want.name, len(got.children), len(want.children))
	n := len(want.children)
	if len(got.children) < n {
		n = len(got.children)
	}
	for i in 0..<n {
		expect_symbols_equal(t, want.children[i], got.children[i], got)
	}
}

@(test)
symbol_payload_round_trips_exotic_forest :: proc(t: ^testing.T) {
	roots := build_exotic_forest()
	defer symbol.symbol_forest_destroy(roots, context.allocator)

	data := symbol.encode_symbol_payload(roots, context.allocator)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) > 5, "payload too small: %d bytes", len(data))

	decoded, ok := symbol.decode_symbol_payload(data, "/proj/src/odd.go", "src/odd.go", context.allocator)
	testing.expectf(t, ok, "decode failed")
	if !ok {
		return
	}
	defer symbol.symbol_forest_destroy(decoded, context.allocator)

	testing.expectf(t, len(decoded) == len(roots), "root count %d != %d", len(decoded), len(roots))
	if len(decoded) != len(roots) {
		return
	}
	for i in 0..<len(roots) {
		expect_symbols_equal(t, roots[i], decoded[i], nil)
	}
}

@(test)
symbol_payload_round_trips_real_outline :: proc(t: ^testing.T) {
	code := "package main\n" +
		"type Server struct{}\n" +
		"func (s *Server) Start() error { return nil }\n" +
		"func (s *Server) Stop() {}\n" +
		"func helper() int { return 1 }\n"
	roots := build_go_symbols(t, code)
	defer symbol.symbol_forest_destroy(roots, context.allocator)
	testing.expectf(t, len(roots) > 0, "outline produced no roots")

	data := symbol.encode_symbol_payload(roots, context.allocator)
	defer delete(data, context.allocator)

	decoded, ok := symbol.decode_symbol_payload(data, "/proj/src/server.go", "src/server.go", context.allocator)
	testing.expectf(t, ok, "decode failed")
	if !ok {
		return
	}
	defer symbol.symbol_forest_destroy(decoded, context.allocator)

	testing.expectf(t, symbol.count_symbols(decoded) == symbol.count_symbols(roots), "symbol count mismatch")
	testing.expectf(t, len(decoded) == len(roots), "root count %d != %d", len(decoded), len(roots))
	if len(decoded) != len(roots) {
		return
	}
	for i in 0..<len(roots) {
		expect_symbols_equal(t, roots[i], decoded[i], nil)
	}
}

@(test)
symbol_payload_empty_forest :: proc(t: ^testing.T) {
	data := symbol.encode_symbol_payload(nil, context.allocator)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) == 5, "empty payload should be the 5-byte header, got %d", len(data))

	decoded, ok := symbol.decode_symbol_payload(data, "/a", "a", context.allocator)
	testing.expectf(t, ok, "empty decode failed")
	if !ok {
		return
	}
	testing.expectf(t, len(decoded) == 0, "empty decode produced roots")
	symbol.symbol_forest_destroy(decoded, context.allocator)
}

// The builders cap forests at MAX_TREE_DEPTH, so nesting deeper than the old
// 100-level walk guard (but inside the builder cap) is a shape the encoder
// legitimately stores — decode must accept it, or such a file becomes a
// permanent L1 cache miss that re-parses and re-stores per lookup.
@(test)
symbol_payload_round_trips_deep_nesting :: proc(t: ^testing.T) {
	a := context.allocator
	depth := symbol.MAX_RECURSION_DEPTH + 50
	testing.expect(t, depth < symbol.MAX_TREE_DEPTH, "fixture must stay inside the builder cap")

	root := symbol.symbol_new(a)
	cur := root
	for _ in 1..<depth {
		next := symbol.symbol_new(a)
		cur.children = make([dynamic]^symbol.Symbol, 0, 1, a)
		append(&cur.children, next)
		cur = next
	}
	roots := make([]^symbol.Symbol, 1, a)
	roots[0] = root

	data := symbol.encode_symbol_payload(roots, a)
	defer delete(data, a)

	decoded, ok := symbol.decode_symbol_payload(data, "/proj/deep.go", "deep.go", a)
	testing.expectf(t, ok, "deeply nested payload failed to decode")
	if !ok {
		symbol.symbol_forest_destroy(roots, a)
		return
	}
	testing.expectf(t, symbol.count_symbols(decoded) == depth, "decoded %d symbols, want %d", symbol.count_symbols(decoded), depth)

	symbol.symbol_forest_destroy(decoded, a)
	symbol.symbol_forest_destroy(roots, a)
}

@(test)
symbol_payload_rejects_corruption :: proc(t: ^testing.T) {
	roots := build_exotic_forest()
	defer symbol.symbol_forest_destroy(roots, context.allocator)
	data := symbol.encode_symbol_payload(roots, context.allocator)
	defer delete(data, context.allocator)

	// Empty payloads (the pre-wiring rows carry zero-length blobs) miss.
	_, ok := symbol.decode_symbol_payload(nil, "/a", "a", context.allocator)
	testing.expectf(t, !ok, "nil payload decoded")

	// Wrong version byte.
	bad_version := make([]u8, len(data), context.allocator)
	copy(bad_version, data)
	bad_version[0] = 99
	_, ok = symbol.decode_symbol_payload(bad_version, "/a", "a", context.allocator)
	testing.expectf(t, !ok, "wrong version decoded")
	delete(bad_version, context.allocator)

	// Truncation at every length must fail cleanly (no partial decode).
	for cut in 1..<len(data) {
		_, ok = symbol.decode_symbol_payload(data[:cut], "/a", "a", context.allocator)
		testing.expectf(t, !ok, "truncated payload at %d decoded", cut)
	}

	// Trailing garbage.
	trailing := make([]u8, len(data) + 3, context.allocator)
	copy(trailing, data)
	trailing[len(data)] = 0
	trailing[len(data) + 1] = 1
	trailing[len(data) + 2] = 2
	_, ok = symbol.decode_symbol_payload(trailing, "/a", "a", context.allocator)
	testing.expectf(t, !ok, "trailing garbage decoded")
	delete(trailing, context.allocator)

	// An inflated string length (the first record's name length sits at
	// offset 5) overruns the payload.
	inflated := make([]u8, len(data), context.allocator)
	copy(inflated, data)
	inflated[5] = 0xFF
	inflated[6] = 0xFF
	_, ok = symbol.decode_symbol_payload(inflated, "/a", "a", context.allocator)
	testing.expectf(t, !ok, "inflated length decoded")
	delete(inflated, context.allocator)
}

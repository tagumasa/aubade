// The L1 payload codec: the compact binary form of a finalized, bodyless
// symbol forest — the per-file sparse tree the symbol cache persists so
// outline lookups survive a cold start without re-parsing or re-querying a
// language server. One implementation for both producers (tree-sitter and
// LSP); the store treats the bytes as opaque.
//
// Layout (all integers little-endian):
//
//	version:    u8
//	root_count: u32, then each root record
//	record:     name_len u32 + bytes
//	            kind u32 (Symbol_Kind's underlying numbering)
//	            container_len u32 + bytes
//	            detail_len u32 + bytes
//	            has_range u8 (0/1), then when 1: start.line, start.character,
//	              end.line, end.character (4x u32)
//	            has_selection u8 (0/1), then when 1: 4x u32 likewise
//	            overload_idx as i32 bit pattern
//	            child_count u32, then that many child records (pre-order:
//	              a node's children follow it immediately)
//
// Bodies and locations are deliberately absent: bodies are re-derived from
// the current file contents (line slicing, never a parse) and locations are
// rebuilt from the file being read — the payload carries the necessary
// columns only. Anything that fails a version, bounds, or trailing-byte
// check decodes to ok=false, which readers treat as a cache miss.
package symbol

import "base:runtime"
import "core:strings"

PAYLOAD_VERSION :: u8(1)

Payload_Level :: struct {
	syms: []^Symbol,
	idx:  int,
}

Payload_Reader :: struct {
	data: []u8,
	pos:  int,
}

// encode_symbol_payload serializes a finalized forest into `a`. The result
// is one allocation (delete it with `delete(payload, a)` or free it with the
// arena it was built on). An empty forest encodes to the 5-byte header.
encode_symbol_payload :: proc(roots: []^Symbol, a := context.allocator) -> []u8 {
	buf := make([dynamic]u8, 0, 256, a)

	root_count := 0
	for s in roots {
		if s != nil {
			root_count += 1
		}
	}
	payload_append_u8(&buf, PAYLOAD_VERSION)
	payload_append_u32(&buf, u32(root_count))

	// Iterative pre-order with per-level cursors: user-shaped nesting must
	// not drive native recursion (the model's other walks use work stacks
	// for the same reason). A node's children are visited immediately after
	// it, matching the count-prefixed record order.
	stack := make([dynamic]Payload_Level, 0, 8, context.temp_allocator)
	defer delete(stack)
	append(&stack, Payload_Level{syms = roots})
	for len(stack) > 0 {
		top := &stack[len(stack) - 1]
		if top.idx >= len(top.syms) {
			pop(&stack)
			continue
		}
		s := top.syms[top.idx]
		top.idx += 1
		if s == nil {
			continue
		}
		children := 0
		for c in s.children {
			if c != nil {
				children += 1
			}
		}
		payload_append_str(&buf, s.name)
		payload_append_u32(&buf, u32(s.kind))
		payload_append_str(&buf, s.container_name)
		payload_append_str(&buf, s.detail)
		if s.range != nil {
			payload_append_u8(&buf, 1)
			payload_append_range(&buf, s.range)
		} else {
			payload_append_u8(&buf, 0)
		}
		if s.selection_range != nil {
			payload_append_u8(&buf, 1)
			payload_append_range(&buf, s.selection_range)
		} else {
			payload_append_u8(&buf, 0)
		}
		payload_append_u32(&buf, cast(u32)(cast(i32)(s.overload_idx)))
		payload_append_u32(&buf, u32(children))
		if children > 0 {
			append(&stack, Payload_Level{syms = s.children[:]})
		}
	}
	return buf[:]
}

// decode_symbol_payload rebuilds a forest in `a` (locations anchored to
// abs_path/rel_path, parents linked, bodies absent). ok=false means the
// payload is not decodable — readers treat that as a cache miss, never as an
// error: the index is a cache, not a source of truth.
decode_symbol_payload :: proc(data: []u8, abs_path: string, rel_path: string, a := context.allocator) -> (roots: []^Symbol, ok: bool) {
	if len(data) < 5 || data[0] != PAYLOAD_VERSION {
		return nil, false
	}
	r := Payload_Reader{data = data, pos = 1}
	root_count, count_ok := payload_read_u32(&r)
	if !count_ok {
		return nil, false
	}
	out := make([dynamic]^Symbol, 0, payload_cap_hint(root_count), a)
	for _ in 0..<root_count {
		s, sok := payload_read_symbol(&r, nil, abs_path, rel_path, a, 0)
		if !sok {
			symbol_forest_destroy(out[:], a)
			return nil, false
		}
		append(&out, s)
	}
	if r.pos != len(data) {
		symbol_forest_destroy(out[:], a)
		return nil, false
	}
	return out[:], true
}

// payload_cap_hint bounds the initial capacity of a children list so a
// corrupt count cannot request an enormous allocation before the per-record
// bounds checks reject the data.
payload_cap_hint :: proc(count: u32) -> int {
	hint := int(count)
	if hint > 256 {
		hint = 256
	}
	return hint
}

payload_read_symbol :: proc(
	r: ^Payload_Reader,
	parent: ^Symbol,
	abs_path: string,
	rel_path: string,
	a: runtime.Allocator,
	depth: int,
) -> (s: ^Symbol, ok: bool) {
	// MAX_TREE_DEPTH, not the tighter walk guard: the builders cap forests at
	// that depth (the outline conversion and the documentSymbol walk), so a
	// payload we encoded must always decode — rejecting here would turn every
	// lookup on a deeply nested file into a permanent cache miss.
	if depth > MAX_TREE_DEPTH {
		return nil, false
	}
	// Validate the whole record before allocating: a truncated payload must
	// not strand half-built strings under the caller's allocator.
	name_v, k1 := payload_read_str(r)
	kind_raw, k2 := payload_read_u32(r)
	container_v, k3 := payload_read_str(r)
	detail_v, k4 := payload_read_str(r)
	has_rng, k5 := payload_read_u8(r)
	rng_v: Range
	if k5 && has_rng == 1 {
		rng_v, k5 = payload_read_range(r)
	}
	has_sel, k6 := payload_read_u8(r)
	sel_v: Range
	if k6 && has_sel == 1 {
		sel_v, k6 = payload_read_range(r)
	}
	overload_raw, k7 := payload_read_u32(r)
	child_count, k8 := payload_read_u32(r)
	if !k1 || !k2 || !k3 || !k4 || !k5 || !k6 || !k7 || !k8 {
		return nil, false
	}
	if has_rng > 1 || has_sel > 1 {
		return nil, false
	}

	s = symbol_new(a)
	s.parent = parent
	s.name = strings.clone(name_v, a)
	s.kind = cast(Symbol_Kind)kind_raw
	s.container_name = strings.clone(container_v, a)
	s.detail = strings.clone(detail_v, a)
	s.overload_idx = int(cast(i32)overload_raw)
	if has_rng == 1 {
		rg := new(Range, a)
		rg^ = rng_v
		s.range = rg
	}
	if has_sel == 1 {
		sel := new(Range, a)
		sel^ = sel_v
		s.selection_range = sel
	}
	loc := new(Location, a)
	loc^ = {range = rng_v}
	loc.uri = file_uri(abs_path, a)
	loc.abs_path = strings.clone(abs_path, a)
	loc.rel_path = strings.clone(rel_path, a)
	s.location = loc

	if child_count > 0 {
		s.children = make([dynamic]^Symbol, 0, payload_cap_hint(child_count), a)
		for _ in 0..<child_count {
			c, cok := payload_read_symbol(r, s, abs_path, rel_path, a, depth + 1)
			if !cok {
				symbol_node_destroy(s, a)
				return nil, false
			}
			append(&s.children, c)
		}
	}
	return s, true
}

payload_append_u8 :: proc(buf: ^[dynamic]u8, v: u8) {
	append(buf, v)
}

payload_append_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	append(buf, u8(v & 0xFF))
	append(buf, u8((v >> 8) & 0xFF))
	append(buf, u8((v >> 16) & 0xFF))
	append(buf, u8((v >> 24) & 0xFF))
}

// payload_append_str appends the raw bytes of s (strings are byte strings;
// indexing by byte keeps multi-byte names intact).
payload_append_str :: proc(buf: ^[dynamic]u8, s: string) {
	payload_append_u32(buf, u32(len(s)))
	for i in 0..<len(s) {
		append(buf, s[i])
	}
}

payload_append_range :: proc(buf: ^[dynamic]u8, rg: ^Range) {
	payload_append_u32(buf, rg.start.line)
	payload_append_u32(buf, rg.start.character)
	payload_append_u32(buf, rg.end.line)
	payload_append_u32(buf, rg.end.character)
}

payload_read_u8 :: proc(r: ^Payload_Reader) -> (v: u8, ok: bool) {
	if r.pos + 1 > len(r.data) {
		return 0, false
	}
	v = r.data[r.pos]
	r.pos += 1
	return v, true
}

payload_read_u32 :: proc(r: ^Payload_Reader) -> (v: u32, ok: bool) {
	if r.pos + 4 > len(r.data) {
		return 0, false
	}
	v = u32(r.data[r.pos]) |
		(u32(r.data[r.pos + 1]) << 8) |
		(u32(r.data[r.pos + 2]) << 16) |
		(u32(r.data[r.pos + 3]) << 24)
	r.pos += 4
	return v, true
}

// payload_read_str returns a view into the payload bytes; decode clones
// everything it keeps into the forest's allocator.
payload_read_str :: proc(r: ^Payload_Reader) -> (v: string, ok: bool) {
	n, nok := payload_read_u32(r)
	if !nok {
		return "", false
	}
	if int(n) > len(r.data) - r.pos {
		return "", false
	}
	v = string(r.data[r.pos : r.pos + int(n)])
	r.pos += int(n)
	return v, true
}

payload_read_range :: proc(r: ^Payload_Reader) -> (v: Range, ok: bool) {
	sl, k1 := payload_read_u32(r)
	sc, k2 := payload_read_u32(r)
	el, k3 := payload_read_u32(r)
	ec, k4 := payload_read_u32(r)
	if !k1 || !k2 || !k3 || !k4 {
		return {}, false
	}
	return {
		start = {line = sl, character = sc},
		end   = {line = el, character = ec},
	}, true
}

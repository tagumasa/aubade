// Generic JSON value helpers: casting, member access, construction, and
// deterministic marshaling of core:encoding/json values. jsonrpc keeps
// only the message envelope; every package that touches parsed JSON
// (config JSONC files, the MCP server, svc handlers, daemon endpoint
// state, tools) goes through these.
package jsonutil

import "core:encoding/json"
import "core:mem"
import "core:strings"

// as_object casts an Object value to its base map (shared, not copied).
as_object :: proc(v: json.Value) -> (map[string]json.Value, bool) {
	#partial switch o in v {
	case json.Object:
		return cast(map[string]json.Value)o, true
	}
	return nil, false
}

// value_str extracts a string from a String value ("" otherwise).
value_str :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String:
		return string(x)
	case:
	}
	return ""
}

// obj_get_bool reads a boolean member (false when absent or not a bool).
obj_get_bool :: proc(v: json.Value, key: string) -> bool {
	if val, ok := obj_get(v, key); ok {
		#partial switch x in val {
		case json.Boolean:
			return x
		case:
		}
	}
	return false
}

// value_int extracts an integer from an Integer value (0 otherwise).
value_int :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer:
		return i64(x)
	case:
	}
	return 0
}

// value_bool extracts a bool from a Boolean value (false otherwise).
value_bool :: proc(v: json.Value) -> bool {
	#partial switch x in v {
	case json.Boolean:
		return x
	case:
	}
	return false
}

// obj_get_int reads an integer member (0 when absent or not an integer).
obj_get_int :: proc(v: json.Value, key: string) -> i64 {
	if val, ok := obj_get(v, key); ok {
		return value_int(val)
	}
	return 0
}

// as_array casts an Array value to its base dynamic array (shared).
as_array :: proc(v: json.Value) -> ([]json.Value, bool) {
	#partial switch a in v {
	case json.Array:
		d := cast([dynamic]json.Value)a
		return d[:], true
	}
	return nil, false
}

// obj_get looks a key up in an Object value.
obj_get :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	m, ok := as_object(v)
	if !ok {
		return nil, false
	}
	if val, found := m[key]; found {
		return val, true
	}
	return nil, false
}

// values_equal is a deep semantic comparison: objects compare by key set
// regardless of member order, arrays by ordered elements, scalars by
// value. Formatting differences (spacing, member order) do not count —
// setup uses it to decide whether an existing registration still matches
// what it would write, so byte-level render differences never trigger a
// rewrite.
values_equal :: proc(a, b: json.Value) -> bool {
	#partial switch va in a {
	case json.Object:
		ma := cast(map[string]json.Value)va
		mb, ok := as_object(b)
		if !ok || len(ma) != len(mb) {
			return false
		}
		for k, v in ma {
			ov, found := mb[k]
			if !found || !values_equal(v, ov) {
				return false
			}
		}
		return true
	case json.Array:
		da := cast([dynamic]json.Value)va
		ab, ok := as_array(b)
		if !ok || len(da) != len(ab) {
			return false
		}
		for v, i in da {
			if !values_equal(v, ab[i]) {
				return false
			}
		}
		return true
	case json.String:
		sb, ok := b.(json.String)
		return ok && string(va) == string(sb)
	case json.Integer:
		ib, ok := b.(json.Integer)
		return ok && i64(va) == i64(ib)
	case json.Float:
		fb, ok := b.(json.Float)
		return ok && f64(va) == f64(fb)
	case json.Boolean:
		bb, ok := b.(json.Boolean)
		return ok && bool(va) == bool(bb)
	case json.Null:
		_, b_nil := b.(json.Null)
		return b_nil
	case:
		return false
	}
}

// ---------------------------------------------------------------------------
// JSON construction helpers. Map literals are disabled in this codebase, so
// objects are created empty (capturing an explicit allocator) and filled
// with obj_set; arrays come from json_array.
// ---------------------------------------------------------------------------

json_string :: proc(s: string) -> json.Value {
	return json.String(s)
}

json_int :: proc(n: i64) -> json.Value {
	return json.Integer(n)
}

json_bool :: proc(b: bool) -> json.Value {
	return json.Boolean(b)
}

json_object :: proc(capacity: int, a: mem.Allocator) -> map[string]json.Value {
	return make(map[string]json.Value, capacity, a)
}

// A map value copied out of a json.Value carries its own header: writes
// through the copy leave the original's count stale and its lookups miss.
// Object construction therefore writes through a ^map and enters the union
// only after the last write (obj_set_object / json.Value(json.Object(m))).
obj_set :: proc(m: ^map[string]json.Value, key: string, val: json.Value) {
	(m^)[key] = val
}

obj_set_object :: proc(m: ^map[string]json.Value, key: string, sub: map[string]json.Value) {
	(m^)[key] = json.Value(json.Object(sub))
}

json_array :: proc(items: []json.Value, a: mem.Allocator) -> json.Value {
	arr := make([dynamic]json.Value, 0, len(items), a)
	for it in items {
		append(&arr, it)
	}
	return json.Array(arr)
}

// json_string_array builds the array in place — no intermediate
// []json.Value left behind for the caller to remember to free.
json_string_array :: proc(items: []string, a: mem.Allocator) -> json.Value {
	arr := make([dynamic]json.Value, 0, len(items), a)
	for s in items {
		append(&arr, json_string(s))
	}
	return json.Array(arr)
}

// marshal_value serializes deterministically (map keys sorted). Every
// artifact that is compared, persisted, or shown to a user (config writes,
// tracker payloads and exports, golden tests) must go through this one.
marshal_value :: proc(v: json.Value, a := context.temp_allocator) -> string {
	out, err := json.unparse(v, {sort_maps_by_key = true}, allocator = a)
	if err != nil {
		return "null"
	}
	return out
}

// marshal_value_unsorted is the wire serializer: JSON objects are unordered
// on the wire, so the per-object key sort is skipped on the hot RPC paths
// (request/reply bodies, tool-call arguments). Wire consumers parse the
// result; anything string-compared needs marshal_value above.
marshal_value_unsorted :: proc(v: json.Value, a := context.temp_allocator) -> string {
	out, err := json.unparse(v, {}, allocator = a)
	if err != nil {
		return "null"
	}
	return out
}

// clone_value deep-copies a parsed value into `a`: strings and containers
// are duplicated, scalars pass through. Ownership transfers that must
// outlive the source arena (a queue entry leaving the reader's message
// arena) clone through this — never hand out pointers into a foreign arena.
clone_value :: proc(v: json.Value, a := context.allocator) -> json.Value {
	#partial switch x in v {
	case json.String:
		return json.Value(json.String(strings.clone(string(x), a)))
	case json.Integer, json.Boolean, json.Float:
		return v
	case json.Array:
		dyn := make(json.Array, 0, len(x), a)
		for ev in x {
			append(&dyn, clone_value(ev, a))
		}
		return json.Value(json.Array(dyn))
	case json.Object:
		m := make(json.Object, len(x), a)
		for k, ev in x {
			m[strings.clone(k, a)] = clone_value(ev, a)
		}
		return json.Value(json.Object(m))
	case:
		return nil
	}
	return nil
}

// free_value releases a value that clone_value built in `a`: strings,
// arrays, and maps are freed recursively; scalars and null carry no
// allocation. The counterpart of clone_value for table-owned copies that
// must be released without an arena free_all.
free_value :: proc(v: json.Value, a: mem.Allocator) {
	#partial switch x in v {
	case json.String:
		delete(string(x), a)
	case json.Array:
		for ev in x {
			free_value(ev, a)
		}
		delete(cast([dynamic]json.Value)x)
	case json.Object:
		// Odin maps store only key headers: the key byte clones that
		// clone_value inserted remain this side's ownership and are freed
		// here — delete frees the map storage, never the key bytes.
		for k, ev in x {
			free_value(ev, a)
			delete(k, a)
		}
		delete(cast(map[string]json.Value)x)
	case: // Null, Integer, Float, Boolean carry no allocation
	}
}

// json_quote renders s as a JSON string literal: \u00XX (lowercase
// hex) for C0 controls, U+FFFD passthrough for invalid UTF-8.
json_quote :: proc(s: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(s) + 8, a)
	append(&buf, '"')
	// Rune iteration: invalid UTF-8 decodes to U+FFFD, so shell output
	// with broken bytes still yields a valid JSON string.
	for r in s {
		switch r {
		case '"':
			append(&buf, "\\\"")
		case '\\':
			append(&buf, "\\\\")
		case '\n':
			append(&buf, "\\n")
		case '\r':
			append(&buf, "\\r")
		case '\t':
			append(&buf, "\\t")
		case:
			if r < 0x20 {
				// Remaining C0 controls emit \u00XX (lowercase hex).
				append(&buf, "\\u00")
				append(&buf, hex_digit(u32(r >> 4) & 0xF))
				append(&buf, hex_digit(u32(r) & 0xF))
			} else {
				append_quote_rune(&buf, r)
			}
		}
	}
	append(&buf, '"')
	return string(buf[:])
}

// hex_digit renders one nibble as a lowercase hex byte — nibbles >= 10 must
// land on 'a'..'f', never on the punctuation after '9' in the ASCII table.
hex_digit :: proc(v: u32) -> u8 {
	if v < 10 {
		return u8('0' + v)
	}
	return u8('a' + v - 10)
}

append_quote_rune :: proc(out: ^[dynamic]u8, r: rune) {
	v := u32(r)
	switch {
	case v < 0x80:
		append(out, u8(v))
	case v < 0x800:
		append(out, u8(0xC0 | (v >> 6)))
		append(out, u8(0x80 | (v & 0x3F)))
	case v < 0x10000:
		append(out, u8(0xE0 | (v >> 12)))
		append(out, u8(0x80 | ((v >> 6) & 0x3F)))
		append(out, u8(0x80 | (v & 0x3F)))
	case:
		append(out, u8(0xF0 | (v >> 18)))
		append(out, u8(0x80 | ((v >> 12) & 0x3F)))
		append(out, u8(0x80 | ((v >> 6) & 0x3F)))
		append(out, u8(0x80 | (v & 0x3F)))
	}
}

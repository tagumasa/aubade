// Dedicated suite for src/jsonutil — the helpers every package that
// touches parsed JSON leans on. The assertions here pin the load-bearing
// behaviors, not coverage for its own sake: values_equal decides whether
// config_set rewrites a user file (jsonc_edit's upsert), the two marshal
// forms are respectively the deterministic compared/persisted rendering
// and the JSON-RPC wire serializer, json_string_array builds tracker
// snapshot payloads, and clone_value/free_value own queue entries that
// outlive their source arena.
package tests

import "core:encoding/json"
import "core:mem"
import "core:testing"
import "src:jsonutil"

@(test)
jsonutil_values_equal_semantics :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Objects compare by key set regardless of member order — the
	// config-rewrite decision must not fire on insertion-order differences.
	ab := jsonutil.json_object(2, a)
	jsonutil.obj_set(&ab, "x", jsonutil.json_int(1))
	jsonutil.obj_set(&ab, "y", jsonutil.json_string("s"))
	ba := jsonutil.json_object(2, a)
	jsonutil.obj_set(&ba, "y", jsonutil.json_string("s"))
	jsonutil.obj_set(&ba, "x", jsonutil.json_int(1))
	testing.expect(t, jsonutil.values_equal(json.Value(json.Object(ab)), json.Value(json.Object(ba))))

	// Containers compare recursively.
	inner_a := jsonutil.json_object(1, a)
	jsonutil.obj_set(&inner_a, "k", jsonutil.json_bool(false))
	inner_b := jsonutil.json_object(1, a)
	jsonutil.obj_set(&inner_b, "k", jsonutil.json_bool(false))
	outer_a := jsonutil.json_object(1, a)
	jsonutil.obj_set_object(&outer_a, "in", inner_a)
	outer_b := jsonutil.json_object(1, a)
	jsonutil.obj_set_object(&outer_b, "in", inner_b)
	testing.expect(t, jsonutil.values_equal(json.Value(json.Object(outer_a)), json.Value(json.Object(outer_b))))

	// Key-set mismatches fail in either direction.
	small := jsonutil.json_object(1, a)
	jsonutil.obj_set(&small, "x", jsonutil.json_int(1))
	big := jsonutil.json_object(2, a)
	jsonutil.obj_set(&big, "x", jsonutil.json_int(1))
	jsonutil.obj_set(&big, "z", jsonutil.json_int(2))
	testing.expect(t, !jsonutil.values_equal(json.Value(json.Object(small)), json.Value(json.Object(big))))
	testing.expect(t, !jsonutil.values_equal(json.Value(json.Object(big)), json.Value(json.Object(small))))

	// Scalars compare by kind first: 1, "1", and true are three different
	// values, and Integer never equals a Float of the same numeric value —
	// the JSON literals differ textually, so a rewrite over one with the
	// other is correct.
	testing.expect(t, jsonutil.values_equal(jsonutil.json_int(1), jsonutil.json_int(1)))
	testing.expect(t, !jsonutil.values_equal(jsonutil.json_int(1), jsonutil.json_string("1")))
	testing.expect(t, !jsonutil.values_equal(jsonutil.json_int(1), jsonutil.json_bool(true)))
	testing.expect(t, !jsonutil.values_equal(jsonutil.json_int(1), json.Float(1.0)))
	testing.expect(t, jsonutil.values_equal(json.Float(1.5), json.Float(1.5)))
	testing.expect(t, jsonutil.values_equal(jsonutil.json_string("a"), jsonutil.json_string("a")))
	testing.expect(t, !jsonutil.values_equal(jsonutil.json_string("a"), jsonutil.json_string("b")))
	testing.expect(t, jsonutil.values_equal(json.Null{}, json.Null{}))
	testing.expect(t, !jsonutil.values_equal(json.Null{}, jsonutil.json_int(0)))

	// Array comparison is ordered and length-sensitive.
	arr12 := jsonutil.json_array({jsonutil.json_int(1), jsonutil.json_int(2)}, a)
	arr21 := jsonutil.json_array({jsonutil.json_int(2), jsonutil.json_int(1)}, a)
	arr1 := jsonutil.json_array({jsonutil.json_int(1)}, a)
	testing.expect(t, !jsonutil.values_equal(arr12, arr21))
	testing.expect(t, !jsonutil.values_equal(arr12, arr1))
	testing.expect(t, jsonutil.values_equal(arr12, jsonutil.json_array({jsonutil.json_int(1), jsonutil.json_int(2)}, a)))

	// An object never equals an array.
	testing.expect(t, !jsonutil.values_equal(json.Value(json.Object(ab)), arr12))
}

@(test)
jsonutil_marshal_forms :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Byte-exact JSON in expect() comparisons only — never through
	// expect_value/expectf, whose fmt layer reads braces in the rendered
	// string as parameter markers.

	// marshal_value sorts object keys no matter the insertion order — the
	// form everything compared or persisted goes through.
	m := jsonutil.json_object(3, a)
	jsonutil.obj_set(&m, "zebra", jsonutil.json_int(1))
	jsonutil.obj_set(&m, "alpha", jsonutil.json_string("x"))
	jsonutil.obj_set(&m, "mid", jsonutil.json_bool(true))
	testing.expect(t, jsonutil.marshal_value(json.Value(json.Object(m)), a) ==
		"{\"alpha\":\"x\",\"mid\":true,\"zebra\":1}")

	// marshal_value_unsorted is the wire form; single-member objects are
	// byte-stable without the sort.
	single := jsonutil.json_object(1, a)
	jsonutil.obj_set(&single, "only", jsonutil.json_int(7))
	testing.expect(t, jsonutil.marshal_value_unsorted(json.Value(json.Object(single)), a) ==
		"{\"only\":7}")

	// Scalars, empties, and nesting render exactly.
	testing.expect(t, jsonutil.marshal_value(jsonutil.json_int(42), a) == "42")
	// Floats render through core json's fixed-precision writer ('f' mode,
	// 16 fractional digits) — pinned as-is: the format is the core's
	// choice, surfaced through this wrapper unchanged.
	testing.expect(t, jsonutil.marshal_value(json.Float(1.5), a) == "1.5000000000000000")
	testing.expect(t, jsonutil.marshal_value(jsonutil.json_bool(false), a) == "false")
	testing.expect(t, jsonutil.marshal_value(json.Null{}, a) == "null")
	testing.expect(t, jsonutil.marshal_value(json.Value(json.Object(jsonutil.json_object(0, a))), a) == "{}")
	testing.expect(t, jsonutil.marshal_value(jsonutil.json_array(nil, a), a) == "[]")
	testing.expect(t, jsonutil.marshal_value(jsonutil.json_string("a\"b\\c\nd"), a) == "\"a\\\"b\\\\c\\nd\"")

	nested_in := jsonutil.json_object(1, a)
	jsonutil.obj_set(&nested_in, "b", jsonutil.json_array(
		{jsonutil.json_int(1), json.Null{}, jsonutil.json_bool(true), jsonutil.json_string("x")},
		a,
	))
	nested := jsonutil.json_object(1, a)
	jsonutil.obj_set_object(&nested, "a", nested_in)
	testing.expect(t, jsonutil.marshal_value(json.Value(json.Object(nested)), a) ==
		"{\"a\":{\"b\":[1,null,true,\"x\"]}}")

	// json_string_array is the tracker-snapshot payload builder: elements
	// are strings, order preserved, empty input an empty array.
	strs := jsonutil.json_string_array({"beta", "alpha"}, a)
	testing.expect(t, jsonutil.marshal_value(strs, a) == "[\"beta\",\"alpha\"]")
	if arr, ok := jsonutil.as_array(strs); ok {
		testing.expect_value(t, len(arr), 2)
		testing.expect_value(t, jsonutil.value_str(arr[0]), "beta")
	} else {
		testing.expectf(t, ok, "string array should cast")
	}
	testing.expect(t, jsonutil.marshal_value(jsonutil.json_string_array(nil, a), a) == "[]")
}

@(test)
jsonutil_accessors :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	obj := jsonutil.json_object(3, a)
	jsonutil.obj_set(&obj, "flag", jsonutil.json_bool(true))
	jsonutil.obj_set(&obj, "name", jsonutil.json_string("x"))
	jsonutil.obj_set(&obj, "count", jsonutil.json_int(1))
	v := json.Value(json.Object(obj))

	// obj_get_bool reads false for absent AND non-bool members — dispatch
	// decisions keyed on it must not misfire on a string or number.
	testing.expect(t, jsonutil.obj_get_bool(v, "flag"))
	testing.expect(t, !jsonutil.obj_get_bool(v, "nope"))
	testing.expect(t, !jsonutil.obj_get_bool(v, "name"))
	testing.expect(t, !jsonutil.obj_get_bool(v, "count"))

	// value_str reads "" for anything but a String.
	name, ok := jsonutil.obj_get(v, "name")
	testing.expect(t, ok)
	testing.expect_value(t, jsonutil.value_str(name), "x")
	count, _ := jsonutil.obj_get(v, "count")
	testing.expect_value(t, jsonutil.value_str(count), "")
	missing, mok := jsonutil.obj_get(v, "nope")
	testing.expect(t, !mok)
	testing.expect_value(t, jsonutil.value_str(missing), "")

	// Member access on the wrong kind reports not-found, never casts.
	arr := jsonutil.json_array({jsonutil.json_int(1)}, a)
	_, aok := jsonutil.obj_get(arr, "flag")
	testing.expect(t, !aok)
	_, ook := jsonutil.as_object(arr)
	testing.expect(t, !ook)
	_, arrok := jsonutil.as_array(v)
	testing.expect(t, !arrok)
	items, iok := jsonutil.as_array(arr)
	testing.expect(t, iok)
	testing.expect_value(t, len(items), 1)
}

@(test)
jsonutil_clone_free_roundtrip :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	src_a := mem.dynamic_arena_allocator(&arena)

	// The source value lives on the arena; the clones live on the test's
	// tracking allocator (context.allocator under odin test) — every clone
	// byte must be freed by free_value or the tracking allocator reports
	// a leak.
	items := jsonutil.json_object(1, src_a)
	jsonutil.obj_set(&items, "list", jsonutil.json_string_array({"a", "b"}, src_a))
	nested := jsonutil.json_object(2, src_a)
	jsonutil.obj_set_object(&nested, "items", items)
	jsonutil.obj_set(&nested, "n", jsonutil.json_int(2))
	root := jsonutil.json_object(2, src_a)
	jsonutil.obj_set(&root, "label", jsonutil.json_string("demo"))
	jsonutil.obj_set_object(&root, "nested", nested)
	src := json.Value(json.Object(root))

	clone1 := jsonutil.clone_value(src, context.allocator)
	clone2 := jsonutil.clone_value(src, context.allocator)
	testing.expect(t, jsonutil.values_equal(clone1, clone2))
	testing.expect(t, jsonutil.values_equal(clone1, src))

	// Deep copy: freeing one clone leaves the other and the arena-held
	// original intact — the clone owns its bytes, it never points into
	// the source arena.
	jsonutil.free_value(clone1, context.allocator)
	testing.expect(t, jsonutil.values_equal(clone2, src))
	jsonutil.free_value(clone2, context.allocator)

	// Scalars pass through allocation-free; null clones to nil — clone
	// and free are balanced no-ops for both.
	sv := jsonutil.clone_value(jsonutil.json_int(9), context.allocator)
	testing.expect(t, jsonutil.values_equal(sv, jsonutil.json_int(9)))
	jsonutil.free_value(sv, context.allocator)
	fv := jsonutil.clone_value(json.Float(0.5), context.allocator)
	jsonutil.free_value(fv, context.allocator)
	nv := jsonutil.clone_value(json.Null{}, context.allocator)
	jsonutil.free_value(nv, context.allocator)
}

@(test)
jsonutil_json_quote_tab_and_cr :: proc(t: ^testing.T) {
	// The named escapes \t and \r are the two json_quote cases no other
	// test exercises (the tools suite covers \n, quotes, backslash, C0
	// hex, and invalid UTF-8).
	got := jsonutil.json_quote("a\tb\rc", context.allocator)
	testing.expect_value(t, got, "\"a\\tb\\rc\"")
	delete(got)

	got = jsonutil.json_quote("", context.allocator)
	testing.expect_value(t, got, "\"\"")
	delete(got)
}

@(test)
jsonutil_json_quote_bytes_preserves_bytes :: proc(t: ^testing.T) {
	// On valid UTF-8 the two quote forms render byte-identical output,
	// named escapes and C0 \u00XX included.
	same := "a\tb\rc\"d\\e\x0bf"
	bq := jsonutil.json_quote_bytes(same, context.allocator)
	rq := jsonutil.json_quote(same, context.allocator)
	testing.expect(t, bq == rq)
	delete(bq)
	delete(rq)

	// Invalid UTF-8 passes through byte-for-byte instead of becoming
	// U+FFFD — the file-render contract: the literal records the
	// source bytes (config templates, registrations, registry).
	broken := "x\xFFy"
	got := jsonutil.json_quote_bytes(broken, context.allocator)
	testing.expect(t, got == "\"x\xFFy\"")
	delete(got)

	// The sanitizing form replaces the broken byte with U+FFFD — the
	// wire/tool-answer contract.
	sanitized := jsonutil.json_quote(broken, context.allocator)
	testing.expect(t, sanitized == "\"x\xEF\xBF\xBDy\"")
	delete(sanitized)
}

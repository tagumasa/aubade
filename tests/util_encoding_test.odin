// Tests for src/util/encoding.odin. Pure, no I/O, no fixtures. The
// round-trip property under test is the editor's freshness-probe
// stability contract: decode(encode(x)) == x for every representable x.
package tests

import "core:testing"
import "core:strings"
import "src:util"

@(test)
encode_latin1_ascii :: proc(t: ^testing.T) {
	got := util.encode_latin1("hello", context.temp_allocator)
	testing.expect_value(t, len(got), 5)
	testing.expect_value(t, string(got), "hello")
}

@(test)
encode_latin1_high_runes :: proc(t: ^testing.T) {
	// '日' is U+65E5 (> 255), so it must become '?'. 'é' is U+00E9
	// (in latin-1 as 0xE9), so it survives the conversion.
	got := util.encode_latin1("é日", context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, rune(got[0]), 0xE9)
	testing.expect_value(t, rune(got[1]), '?')
}

@(test)
encode_latin1_bom_rune_unrepresentable :: proc(t: ^testing.T) {
	// A string whose first RUNE is U+FEFF (a decoded UTF-8 BOM reaching a
	// latin-1 encode directly) is unrepresentable: it becomes '?', like
	// every rune above 255. The decoder never produces this rune from
	// latin-1 bytes, so saves never hit the path.
	bom_bytes: [3]u8 = {0xEF, 0xBB, 0xBF}
	bom := string(bom_bytes[:])
	combined := strings.concatenate({bom, "abc"}, context.temp_allocator)
	got := util.encode_latin1(combined, context.temp_allocator)
	testing.expect_value(t, len(got), 4)
	testing.expect_value(t, string(got), "?abc")
}

@(test)
strip_utf8_bom_present :: proc(t: ^testing.T) {
	src := []byte{0xEF, 0xBB, 0xBF, 'h', 'i'}
	got := util.strip_utf8_bom(src)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, rune(got[0]), 'h')
	testing.expect_value(t, rune(got[1]), 'i')
}

@(test)
strip_utf8_bom_absent :: proc(t: ^testing.T) {
	src := []byte{'h', 'e', 'l', 'l', 'o'}
	got := util.strip_utf8_bom(src)
	testing.expect_value(t, len(got), 5)
	testing.expect_value(t, rune(got[0]), 'h')
}

@(test)
has_utf8_bom_cases :: proc(t: ^testing.T) {
	testing.expect(t, util.has_utf8_bom([]byte{0xEF, 0xBB, 0xBF}), "exact BOM")
	testing.expect(t, util.has_utf8_bom([]byte{0xEF, 0xBB, 0xBF, 'x'}), "BOM with body")
	testing.expect(t, !util.has_utf8_bom([]byte{0xEF, 0xBB}), "truncated BOM")
	testing.expect(t, !util.has_utf8_bom([]byte{'x', 0xEF, 0xBB, 0xBF}), "not at offset 0")
	testing.expect(t, !util.has_utf8_bom([]byte{}), "empty")
}

@(test)
ensure_trailing_newline_appends :: proc(t: ^testing.T) {
	testing.expect_value(t, util.ensure_trailing_newline("hello", context.temp_allocator), "hello\n")
	testing.expect_value(t, util.ensure_trailing_newline("hello\n", context.temp_allocator), "hello\n")
	testing.expect_value(t, util.ensure_trailing_newline("hello\n\n", context.temp_allocator), "hello\n\n")
}

@(test)
ensure_trailing_newline_empty :: proc(t: ^testing.T) {
	// Empty string stays empty — don't add a stray newline.
	testing.expect_value(t, util.ensure_trailing_newline("", context.temp_allocator), "")
}

@(test)
encode_content_utf8 :: proc(t: ^testing.T) {
	// 'é' is 0xC3 0xA9 in UTF-8; Latin-1 would have it as 0xE9.
	got, owned := util.encode_content("utf-8", "héllo", context.temp_allocator)
	testing.expect(t, !owned, "the utf-8 path returns a view")
	testing.expect_value(t, len(got), 6)
	testing.expect_value(t, rune(got[0]), 'h')
	testing.expect_value(t, rune(got[1]), 0xC3)
	testing.expect_value(t, rune(got[2]), 0xA9)
}

@(test)
encode_content_utf8_case_insensitive :: proc(t: ^testing.T) {
	got, _ := util.encode_content("UTF-8", "héllo", context.temp_allocator)
	testing.expect_value(t, rune(got[1]), 0xC3)
}

@(test)
encode_content_latin1 :: proc(t: ^testing.T) {
	got, owned := util.encode_content("latin-1", "héllo", context.temp_allocator)
	testing.expect(t, owned, "the latin-1 path owns its output")
	testing.expect_value(t, len(got), 5)
	testing.expect_value(t, rune(got[0]), 'h')
	// 'é' is 0xE9 in latin-1.
	testing.expect_value(t, rune(got[1]), 0xE9)
}

@(test)
encode_content_utf16_le_owned :: proc(t: ^testing.T) {
	got, owned := util.encode_content("utf-16", "abc", context.temp_allocator)
	testing.expect(t, owned, "the utf-16 path owns its output")
	// BOM (FF FE) + three LE units.
	testing.expect_value(t, len(got), 8)
	testing.expect_value(t, rune(got[0]), 0xFF)
	testing.expect_value(t, rune(got[1]), 0xFE)
	testing.expect_value(t, rune(got[2]), 'a')
}

@(test)
encode_content_unknown_falls_through :: proc(t: ^testing.T) {
	got, owned := util.encode_content("utf-32", "abc", context.temp_allocator)
	testing.expect(t, !owned)
	testing.expect_value(t, string(got), "abc")
}

@(test)
encode_content_empty_encoding :: proc(t: ^testing.T) {
	got, _ := util.encode_content("", "abc", context.temp_allocator)
	testing.expect_value(t, string(got), "abc")
}

@(test)
decode_latin1_bytes_byte_per_rune :: proc(t: ^testing.T) {
	// Latin-1 is single-byte: 0xC3 and 0xA9 are the characters Ã and ©,
	// never a UTF-8 'é' — guessing UTF-8 would reinterpret genuine
	// latin-1 text and break the encode symmetry.
	src: [6]u8 = {'h', 0xC3, 0xA9, 'l', 'l', 'o'}
	got := util.decode_latin1_bytes(src[:], context.temp_allocator)
	testing.expect_value(t, utf8_rune_count(got), 6)
	testing.expect_value(t, utf8_rune_at(got, 1), 0xC3)
	testing.expect_value(t, utf8_rune_at(got, 2), 0xA9)
}

@(test)
decode_latin1_bytes_high_byte :: proc(t: ^testing.T) {
	// 0xE9 alone is not valid UTF-8; the decoder still maps it straight
	// to U+00E9.
	invalid := []byte{'h', 0xE9, 'l', 'l', 'o'}
	got := util.decode_latin1_bytes(invalid, context.temp_allocator)
	testing.expect_value(t, utf8_rune_count(got), 5)
	testing.expect_value(t, utf8_rune_at(got, 1), 0xE9)
}

@(test)
decode_latin1_bytes_bom_prefix_is_content :: proc(t: ^testing.T) {
	// A UTF-8-BOM-looking prefix in a latin-1 file is the three real
	// characters ï»¿ — content, not a marker to strip.
	src := []byte{0xEF, 0xBB, 0xBF, 0xE9}
	got := util.decode_latin1_bytes(src[:], context.temp_allocator)
	testing.expect_value(t, utf8_rune_at(got, 0), 0xEF)
	testing.expect_value(t, utf8_rune_at(got, 1), 0xBB)
	testing.expect_value(t, utf8_rune_at(got, 2), 0xBF)
	testing.expect_value(t, utf8_rune_at(got, 3), 0xE9)
}

@(test)
latin1_round_trip_exact :: proc(t: ^testing.T) {
	// The freshness-probe contract: whatever the encoder writes, the
	// decoder reads back rune for rune.
	src := []byte{0xEF, 0xBB, 0xBF, 'h', 0xC3, 0xA9, 'l', 0xE9}
	decoded := util.decode_latin1_bytes(src, context.temp_allocator)
	encoded := util.encode_latin1(decoded, context.temp_allocator)
	testing.expect_value(t, len(encoded), len(src))
	match := len(encoded) == len(src)
	if match {
		for i := 0; i < len(src); i += 1 {
			if encoded[i] != src[i] {
				match = false
			}
		}
	}
	testing.expect(t, match, "latin-1 round trip must be byte-exact")
}

@(test)
utf16_round_trip_le_and_be :: proc(t: ^testing.T) {
	orders := []bool{false, true}
	for be in orders {
		// Includes a surrogate pair (U+65E5) and an accented rune.
		s := "héllo日\n"
		encoded := util.encode_utf16_bytes(s, be, context.temp_allocator)
		decoded := util.decode_utf16_bytes(encoded, context.temp_allocator)
		testing.expectf(t, decoded == s, "utf-16 round trip (be=%v) must be exact", be)
	}
}

@(test)
utf16_decode_bom_detection :: proc(t: ^testing.T) {
	le := util.encode_utf16_bytes("aé日", false, context.temp_allocator)
	be := util.encode_utf16_bytes("aé日", true, context.temp_allocator)
	// Both byte orders decode identically — the BOM decides, so files
	// written by either side read the same.
	testing.expect_value(t, util.decode_utf16_bytes(le, context.temp_allocator), "aé日")
	testing.expect_value(t, util.decode_utf16_bytes(be, context.temp_allocator), "aé日")
}

@(test)
utf16_decode_bomless_defaults_le :: proc(t: ^testing.T) {
	// Strip the BOM from an LE encoding: the remaining bytes decode as
	// little-endian by default.
	le := util.encode_utf16_bytes("aé", false, context.temp_allocator)
	testing.expect_value(t, util.decode_utf16_bytes(le[2:], context.temp_allocator), "aé")
}

@(test)
utf16_decode_unpaired_surrogate_is_replacement :: proc(t: ^testing.T) {
	// A lone low surrogate (LE, BOM-less): the decode must yield a valid
	// string, not corrupt runes.
	src := []byte{0x3D, 0xD8}
	got := util.decode_utf16_bytes(src, context.temp_allocator)
	testing.expect_value(t, utf8_rune_count(got), 1)
}

utf8_rune_at :: proc(s: string, idx: int) -> rune {
	i := 0
	for r in s {
		if i == idx {
			return r
		}
		i += 1
	}
	return -1
}

utf8_rune_count :: proc(s: string) -> int {
	n := 0
	for _ in s {
		n += 1
	}
	return n
}

@(test)
percent_decode_policies :: proc(t: ^testing.T) {
	// Keep_Bytes (the path-decoder stance): valid escapes decode, malformed
	// and truncated escapes pass their bytes through literally.
	keep := util.percent_decode("a%20b%2", context.allocator)
	defer delete(keep, context.allocator)
	testing.expect_value(t, keep, "a b%2")
	malformed := util.percent_decode("x%zz", context.allocator)
	defer delete(malformed, context.allocator)
	testing.expect_value(t, malformed, "x%zz")

	// plus_to_space (the form/query stance): '+' maps to a space alongside
	// the escapes.
	plus := util.percent_decode("a+b%21", context.allocator, plus_to_space = true)
	defer delete(plus, context.allocator)
	testing.expect_value(t, plus, "a b!")

	// Return_Input (the guard stance): one malformed escape anywhere returns
	// the whole input unchanged — a partial decode must never reach a
	// security matcher.
	bail := util.percent_decode("a%20b%zz", context.allocator, malformed = .Return_Input)
	defer delete(bail, context.allocator)
	testing.expect_value(t, bail, "a%20b%zz")
	truncated := util.percent_decode("a%2", context.allocator, malformed = .Return_Input)
	defer delete(truncated, context.allocator)
	testing.expect_value(t, truncated, "a%2")
}

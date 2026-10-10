// Direct tests for util.json_sanity_ok — the pre-parse scan that guards
// the core parser's uncapped recursion, UTF-8 normalization, and
// control-character truncation on config files, hooks stdin, tracker
// payloads, web bodies, and the daemon endpoint.
package tests

import "core:testing"
import "src:util"

@(test)
jsonscan_accepts_wellformed_bodies :: proc(t: ^testing.T) {
	testing.expect(t, util.json_sanity_ok(json_bytes("{\"a\":[1,2,{\"b\":\"x y\"}],\"c\":null}")))
	testing.expect(t, util.json_sanity_ok(json_bytes("[]")))
	testing.expect(t, util.json_sanity_ok(json_bytes("{}")))
	// Multi-byte UTF-8 inside strings passes the sequence validator.
	testing.expect(t, util.json_sanity_ok(json_bytes("{\"k\":\"\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\"}")))
}

@(test)
jsonscan_bounds_nesting_depth :: proc(t: ^testing.T) {
	at_cap := make([dynamic]u8, 0, 2 * util.MAX_JSON_DEPTH, context.allocator)
	defer delete(at_cap)
	for _ in 0..<util.MAX_JSON_DEPTH {
		append(&at_cap, '[')
	}
	for _ in 0..<util.MAX_JSON_DEPTH {
		append(&at_cap, ']')
	}
	testing.expect(t, util.json_sanity_ok(at_cap[:]))

	over_cap := make([dynamic]u8, 0, 2 * (util.MAX_JSON_DEPTH + 1), context.allocator)
	defer delete(over_cap)
	for _ in 0..<util.MAX_JSON_DEPTH + 1 {
		append(&over_cap, '[')
	}
	for _ in 0..<util.MAX_JSON_DEPTH + 1 {
		append(&over_cap, ']')
	}
	testing.expect(t, !util.json_sanity_ok(over_cap[:]))
}

@(test)
jsonscan_rejects_bad_utf8_and_control_chars :: proc(t: ^testing.T) {
	// Invalid lead byte, truncated sequence, and an overlong C0 lead all
	// fail the sequence validator.
	testing.expect(t, !util.json_sanity_ok(json_bytes("{\"k\":\"x\xFFy\"}")))
	testing.expect(t, !util.json_sanity_ok(json_bytes("{\"k\":\"x\xE2\x82\"}")))
	testing.expect(t, !util.json_sanity_ok(json_bytes("{\"k\":\"x\xC0\x80\"}")))
	// Raw control bytes inside strings — including the named escapes'
	// raw forms — are rejected; the escaped spellings pass.
	testing.expect(t, !util.json_sanity_ok(json_bytes("{\"k\":\"a\tb\"}")))
	testing.expect(t, !util.json_sanity_ok(json_bytes("{\"k\":\"a\x00b\"}")))
	testing.expect(t, util.json_sanity_ok(json_bytes("{\"k\":\"a\\tb\\\"c\"}")))
	// A close before its open drives depth negative.
	testing.expect(t, !util.json_sanity_ok(json_bytes("{\"a\":1]}")))
}

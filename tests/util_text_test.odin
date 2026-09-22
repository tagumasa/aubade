// Tests for src/util/text.odin and src/util/text_priv.odin. Pure; no I/O
// or fixtures. The private helpers are exercised indirectly through the
// public API.
package tests

import "core:testing"
import "src:util"

@(test)
utf16_col_to_byte_offset_ascii :: proc(t: ^testing.T) {
	// "abc" — col 2 should be at byte offset 2 (start of 'c').
	testing.expect_value(t, util.utf16_col_to_byte_offset("abc", 2), 2)
}

@(test)
utf16_col_to_byte_offset_past_end :: proc(t: ^testing.T) {
	testing.expect_value(t, util.utf16_col_to_byte_offset("abc", 10), 3)
}

@(test)
utf16_col_to_byte_offset_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, util.utf16_col_to_byte_offset("abc", 0), 0)
}

@(test)
utf16_col_to_byte_offset_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, util.utf16_col_to_byte_offset("", 1), 0)
}

@(test)
utf16_col_to_byte_offset_bmp :: proc(t: ^testing.T) {
	// "héllo" — h(0) é(1-2) l(3) l(4) o(5). col 2 (after h+é) = byte 3.
	testing.expect_value(t, util.utf16_col_to_byte_offset("héllo", 2), 3)
	// col 3 (after h+é+l) = byte 4.
	testing.expect_value(t, util.utf16_col_to_byte_offset("héllo", 3), 4)
}

@(test)
utf16_col_to_byte_offset_surrogate_pair :: proc(t: ^testing.T) {
	// "\U0001F600ab" — emoji 😀 is 4 bytes UTF-8, 2 UTF-16 units. col 2
	// should land at byte offset 4 (past the emoji).
	line := "\U0001F600ab"
	testing.expect_value(t, util.utf16_col_to_byte_offset(line, 2), 4)
	// col 1 lands inside the surrogate pair and rounds to the pair's
	// start (byte 0) under the documented mid-pair convention.
	testing.expect_value(t, util.utf16_col_to_byte_offset(line, 1), 0)
	// col 3 lands after 'a' at byte 5.
	testing.expect_value(t, util.utf16_col_to_byte_offset(line, 3), 5)
}

@(test)
byte_offset_to_utf16_col_ascii :: proc(t: ^testing.T) {
	testing.expect_value(t, util.byte_offset_to_utf16_col("abc", 2), 2)
}

@(test)
byte_offset_to_utf16_col_past_end :: proc(t: ^testing.T) {
	testing.expect_value(t, util.byte_offset_to_utf16_col("abc", 10), 3)
}

@(test)
byte_offset_to_utf16_col_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, util.byte_offset_to_utf16_col("abc", 0), 0)
}

@(test)
byte_offset_to_utf16_col_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, util.byte_offset_to_utf16_col("", 0), 0)
}

@(test)
byte_offset_to_utf16_col_bmp :: proc(t: ^testing.T) {
	// "héllo": h(0) é(1-2) l(3) l(4) o(5). byte 3 → utf16 col 2.
	testing.expect_value(t, util.byte_offset_to_utf16_col("héllo", 3), 2)
	// byte 1 → utf16 col 1 (just past 'h').
	testing.expect_value(t, util.byte_offset_to_utf16_col("héllo", 1), 1)
}

@(test)
byte_offset_to_utf16_col_surrogate_pair :: proc(t: ^testing.T) {
	line := "\U0001F600ab"
	// After the emoji (byte 4) the col is 2.
	testing.expect_value(t, util.byte_offset_to_utf16_col(line, 4), 2)
	// Past everything → 4 (h + a + b = 4 UTF-16 units).
	testing.expect_value(t, util.byte_offset_to_utf16_col(line, 100), 4)
}

@(test)
utf16_round_trip :: proc(t: ^testing.T) {
	// byte<->col should be inverse for code-unit boundaries. col=1 on
	// "\U0001F600ab" lands inside the surrogate pair and rounds to the
	// pair's start under LSP convention, so it's intentionally excluded.
	cases := []struct {
		line: string,
		col:  int,
	}{
		{"abc", 0},
		{"abc", 1},
		{"abc", 2},
		{"abc", 3},
		{"héllo", 0},
		{"héllo", 1},
		{"héllo", 2},
		{"héllo", 3},
		{"héllo", 4},
		{"héllo", 5},
		{"\U0001F600ab", 0},
		{"\U0001F600ab", 2},
		{"\U0001F600ab", 3},
		{"\U0001F600ab", 4},
	}
	for c in cases {
		boff := util.utf16_col_to_byte_offset(c.line, c.col)
		got := util.byte_offset_to_utf16_col(c.line, boff)
		testing.expect_value(t, got, c.col)
	}
}

@(test)
line_start_offsets_simple :: proc(t: ^testing.T) {
	// Two '\n' delimit three lines; offsets = [0, 4, 8]. There is no
	// trailing '\n' so no fourth entry.
	got := util.line_start_offsets("abc\ndef\nghi", context.temp_allocator)
	defer delete(got, context.temp_allocator)
	testing.expect_value(t, len(got), 3)
	if len(got) >= 3 {
		testing.expect_value(t, got[0], 0)
		testing.expect_value(t, got[1], 4)
		testing.expect_value(t, got[2], 8)
	}
}

@(test)
line_start_offsets_empty :: proc(t: ^testing.T) {
	got := util.line_start_offsets("", context.temp_allocator)
	defer delete(got, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	if len(got) >= 1 {
		testing.expect_value(t, got[0], 0)
	}
}

@(test)
line_start_offsets_trailing_newline :: proc(t: ^testing.T) {
	got := util.line_start_offsets("abc\n", context.temp_allocator)
	defer delete(got, context.temp_allocator)
	// "abc\n" splits into two lines: "abc" and ""; starts at 0 and 4.
	testing.expect_value(t, len(got), 2)
	if len(got) >= 2 {
		testing.expect_value(t, got[0], 0)
		testing.expect_value(t, got[1], 4)
	}
}

@(test)
detect_indent_tabs :: proc(t: ^testing.T) {
	testing.expect(t, util.detect_indent("\t\tif foo {") == "\t\t")
}

@(test)
detect_indent_spaces :: proc(t: ^testing.T) {
	testing.expect(t, util.detect_indent("    if foo {") == "    ")
}

@(test)
detect_indent_mixed :: proc(t: ^testing.T) {
	testing.expect(t, util.detect_indent("  \tif foo {") == "  \t")
}

@(test)
detect_indent_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, util.detect_indent(""), "")
}

@(test)
detect_indent_all_blank :: proc(t: ^testing.T) {
	testing.expect_value(t, util.detect_indent("\n\n   \n\t\n"), "")
}

@(test)
detect_indent_no_indent :: proc(t: ^testing.T) {
	testing.expect_value(t, util.detect_indent("foo\nbar\nbaz"), "")
}

@(test)
detect_indent_skips_blank_lead :: proc(t: ^testing.T) {
	// First two lines are blank; first non-blank has 2 spaces.
	testing.expect_value(t, util.detect_indent("\n\n  foo"), "  ")
}


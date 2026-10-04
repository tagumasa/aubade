// Tests for the semanticTokens relative encoder: delta monotonicity,
// reconstruction to absolute positions, same-start and skipped captures,
// the line-advance column reset, modifier bit ORing, byte columns over
// multi-byte UTF-8, empty input, the caller-defect refusals, and the
// line-tail rules — a capture spanning a line break clips to its start
// line's text under either encoding, and a "\r\n" terminator counts as no
// line character.
package tests

import "core:testing"
import "src:lspserver"

// Enc_Expect is one token's expected absolute record: position, byte
// length, token type, and modifier set.
Enc_Expect :: struct {
	line:      int,
	char:      int,
	length:    int,
	token:     lspserver.Token_Type,
	modifiers: lspserver.Token_Modifier_Set,
}

// Enc_Token is one token decoded back out of the wire data: absolute
// position, byte length, legend type index, and legend modifier mask.
Enc_Token :: struct {
	line:       int,
	char:       int,
	length:     int,
	type_index: i32,
	modifiers:  i32,
}

// Byte layout of the main fixture: "package demo" ends at the newline of
// byte 12, a blank line follows at 13, so line 2 ("main :: proc() {")
// spans bytes 14 .. 30 and line 3 ("\tprint(msg)") spans bytes 31 .. 42.
ENC_MAIN_SOURCE :: "package demo\n\nmain :: proc() {\n\tprint(msg)\n}\n"

// Captures in position-ascending order: the function main, the proc
// keyword, then print and msg on the next line.
ENC_MAIN_CAPTURES :: []lspserver.Capture_Hit{
	{capture = "function",         start_byte = 14, end_byte = 18},
	{capture = "keyword.function", start_byte = 22, end_byte = 26},
	{capture = "function",         start_byte = 32, end_byte = 37},
	{capture = "variable",         start_byte = 38, end_byte = 41},
}

// enc_ranks derives the legend rank cache the encoder resolves through —
// built from the same legend procs the expectations below read, so a rank
// drift between cache and procs fails here.
enc_ranks :: proc() -> lspserver.Legend_Ranks {
	return lspserver.legend_ranks_build()
}

// The same four tokens at their absolute positions.
ENC_MAIN_EXPECT :: []Enc_Expect{
	{line = 2, char = 0, length = 4, token = .Function},
	{line = 2, char = 8, length = 4, token = .Keyword},
	{line = 3, char = 1, length = 5, token = .Function},
	{line = 3, char = 7, length = 3, token = .Variable},
}

enc_modifier_mask :: proc(set: lspserver.Token_Modifier_Set) -> i32 {
	mask: i32
	for m in lspserver.Token_Modifier {
		if m in set {
			if bit, ok := lspserver.legend_modifier_bit(m); ok {
				mask |= i32(1) << bit
			}
		}
	}
	return mask
}

// enc_decode_token decodes the quintuple at data[offset] against the
// running position: a positive line delta advances the line and re-bases
// the char at the delta, a zero line delta adds to the current char —
// the same rule the wire form encodes with.
enc_decode_token :: proc(data: []i32, offset: int, line, char: ^int) -> Enc_Token {
	delta_line, delta_start := data[offset], data[offset+1]
	if delta_line > 0 {
		line^ += int(delta_line)
		char^ = int(delta_start)
	} else {
		char^ += int(delta_start)
	}
	return Enc_Token{
		line       = line^,
		char       = char^,
		length     = int(data[offset+2]),
		type_index = data[offset+3],
		modifiers  = data[offset+4],
	}
}

enc_expect_token :: proc(t: ^testing.T, got: Enc_Token, want: Enc_Expect, at: int) {
	index, ok := lspserver.legend_type_index(want.token)
	testing.expectf(t, ok, "token %v: type %v has no legend index", at, want.token)
	testing.expectf(t, got.line == want.line, "token %v: line %v, want %v", at, got.line, want.line)
	testing.expectf(t, got.char == want.char, "token %v: char %v, want %v", at, got.char, want.char)
	testing.expectf(t, got.length == want.length, "token %v: length %v, want %v", at, got.length, want.length)
	testing.expectf(t, got.type_index == i32(index), "token %v: type index %v, want %v", at, got.type_index, index)
	testing.expectf(t, got.modifiers == enc_modifier_mask(want.modifiers), "token %v: modifier mask %v, want %v", at, got.modifiers, enc_modifier_mask(want.modifiers))
}

// All five integers of every token stay non-negative across a multi-line
// fixture with several tokens per line, and decoded positions advance
// monotonically.
@(test)
enc_deltas_stay_non_negative :: proc(t: ^testing.T) {
	data, err := lspserver.semantic_tokens_encode(ENC_MAIN_CAPTURES, ENC_MAIN_SOURCE, nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) == 5*len(ENC_MAIN_EXPECT), "data holds %v integers, want %v", len(data), 5*len(ENC_MAIN_EXPECT))

	line, char: int
	prev_line, prev_char: int
	for offset := 0; offset < len(data); offset += 5 {
		for i := offset; i < offset+5; i += 1 {
			testing.expectf(t, data[i] >= 0, "integer %v at token %v is negative", data[i], offset/5)
		}
		token := enc_decode_token(data, offset, &line, &char)
		monotone := token.line > prev_line || (token.line == prev_line && token.char >= prev_char)
		testing.expectf(t, monotone, "token %v sits at line %v char %v, going backwards", offset/5, token.line, token.char)
		prev_line, prev_char = token.line, token.char
	}
}

// Decoding the data array back to absolute positions lands on the input
// captures' lines, chars, lengths, legend types, and modifier masks.
@(test)
enc_data_reconstructs_input_positions :: proc(t: ^testing.T) {
	data, err := lspserver.semantic_tokens_encode(ENC_MAIN_CAPTURES, ENC_MAIN_SOURCE, nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)

	line, char: int
	for entry, at in ENC_MAIN_EXPECT {
		token := enc_decode_token(data, at*5, &line, &char)
		enc_expect_token(t, token, entry, at)
	}
}

// Two captures on the same bytes — the nested-capture overlap a query can
// produce — emit two tokens, the second with zero line and char deltas.
@(test)
enc_same_start_tokens :: proc(t: ^testing.T) {
	captures := []lspserver.Capture_Hit{
		{capture = "function", start_byte = 0, end_byte = 1},
		{capture = "function", start_byte = 0, end_byte = 1},
	}
	data, err := lspserver.semantic_tokens_encode(captures, "f(x)\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) == 10, "data holds %v integers, want 10", len(data))
	testing.expectf(t, data[5] == 0 && data[6] == 0, "second token deltas are line %v char %v, want 0 0", data[5], data[6])
}

// A capture with no entry at any hierarchy level emits nothing, and the
// next token's deltas measure from the last emitted token.
@(test)
enc_unknown_capture_skipped :: proc(t: ^testing.T) {
	captures := []lspserver.Capture_Hit{
		{capture = "variable",              start_byte = 0, end_byte = 1},
		{capture = "punctuation.delimiter", start_byte = 2, end_byte = 3},
		{capture = "variable",              start_byte = 4, end_byte = 5},
	}
	data, err := lspserver.semantic_tokens_encode(captures, "x + y\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) == 10, "data holds %v integers, want 10", len(data))
	// The second variable sits at char 4: its char delta measures from
	// the emitted x at char 0, not from the skipped capture at char 2.
	testing.expectf(t, data[5] == 0 && data[6] == 4, "second token deltas are line %v char %v, want 0 4", data[5], data[6])
}

// Across a line advance the char delta is relative to the line start, so
// a token off column zero on its own line keeps its absolute char.
@(test)
enc_line_advance_resets_column_base :: proc(t: ^testing.T) {
	captures := []lspserver.Capture_Hit{
		{capture = "variable", start_byte = 0, end_byte = 2},
		{capture = "variable", start_byte = 6, end_byte = 8},
	}
	data, err := lspserver.semantic_tokens_encode(captures, "ab\ncd ef\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, data[5] == 1 && data[6] == 3, "second token deltas are line %v char %v, want 1 3", data[5], data[6])
}

// Two modifiers on one capture OR into one bitmask of their legend bits.
@(test)
enc_modifier_bits_or_together :: proc(t: ^testing.T) {
	captures := []lspserver.Capture_Hit{
		{capture = "constant.builtin", start_byte = 0, end_byte = 2},
	}
	data, err := lspserver.semantic_tokens_encode(captures, "PI\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)
	readonly_bit, readonly_ok := lspserver.legend_modifier_bit(.Readonly)
	library_bit, library_ok := lspserver.legend_modifier_bit(.Default_Library)
	testing.expectf(t, readonly_ok && library_ok, "expected both modifier bits in the legend")
	expected := (i32(1) << readonly_bit) | (i32(1) << library_bit)
	testing.expectf(t, data[4] == expected, "modifier mask %v, want %v", data[4], expected)
}

// Columns count UTF-8 code units — bytes. The three-byte 日 before y
// pushes y to char 12 (ten runes would say 10), and the quoted string
// spans five bytes, not three runes.
@(test)
enc_multibyte_columns_count_bytes :: proc(t: ^testing.T) {
	captures := []lspserver.Capture_Hit{
		{capture = "string",   start_byte = 4,  end_byte = 9},
		{capture = "variable", start_byte = 12, end_byte = 13},
	}
	data, err := lspserver.semantic_tokens_encode(captures, "x = \"日\" + y\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) == 10, "data holds %v integers, want 10", len(data))
	testing.expectf(t, data[2] == 5, "string length %v, want 5 bytes", data[2])
	line, char: int
	first := enc_decode_token(data, 0, &line, &char)
	testing.expectf(t, first.line == 0 && first.char == 4, "string sits at line %v char %v, want 0 4", first.line, first.char)
	second := enc_decode_token(data, 5, &line, &char)
	testing.expectf(t, second.line == 0 && second.char == 12, "y sits at line %v char %v, want 0 12", second.line, second.char)
}

// Nil and empty capture lists encode to an empty data array, no error.
@(test)
enc_empty_input_gives_empty_output :: proc(t: ^testing.T) {
	data, err := lspserver.semantic_tokens_encode(nil, "", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "nil input: encode failed: %v", err)
	testing.expect(t, len(data) == 0)
	if data != nil {
		delete(data, context.allocator)
	}

	data, err = lspserver.semantic_tokens_encode([]lspserver.Capture_Hit{}, "x\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "empty input: encode failed: %v", err)
	testing.expect(t, len(data) == 0)
	if data != nil {
		delete(data, context.allocator)
	}
}

// A capture list that moves backwards would encode negative deltas, so
// the encoder refuses it instead.
@(test)
enc_unsorted_input_refused :: proc(t: ^testing.T) {
	backwards := []lspserver.Capture_Hit{
		{capture = "variable", start_byte = 3, end_byte = 5},
		{capture = "variable", start_byte = 0, end_byte = 2},
	}
	data, err := lspserver.semantic_tokens_encode(backwards, "ab\ncd\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .Captures_Unsorted, "got error %v, want .Captures_Unsorted", err)
	testing.expect(t, len(data) == 0)
	if data != nil {
		delete(data, context.allocator)
	}
}

// A capture whose byte range does not index the source text is refused
// rather than read out of bounds.
@(test)
enc_out_of_range_input_refused :: proc(t: ^testing.T) {
	oversized := []lspserver.Capture_Hit{
		{capture = "variable", start_byte = 0, end_byte = 99},
	}
	data, err := lspserver.semantic_tokens_encode(oversized, "ab\ncd\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .Capture_Out_Of_Range, "got error %v, want .Capture_Out_Of_Range", err)
	testing.expect(t, len(data) == 0)
	if data != nil {
		delete(data, context.allocator)
	}
}

// A capture spanning a line break clips to its start line's tail under
// BOTH encodings — the wire form names exactly one line per token, so the
// length never crosses the start line's terminator.
@(test)
enc_multiline_capture_clips_to_start_line :: proc(t: ^testing.T) {
	// The capture spans "ab\ncd": two full lines and the break.
	captures := []lspserver.Capture_Hit{
		{capture = "variable", start_byte = 0, end_byte = 6},
	}
	data, err := lspserver.semantic_tokens_encode(captures, "ab\ncd\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "utf-8 encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, len(data) == 5, "data holds %v integers, want 5", len(data))
	testing.expectf(t, data[0] == 0 && data[1] == 0, "token sits on the start line, got line %v char %v", data[0], data[1])
	testing.expectf(t, data[2] == 2, "utf-8 length %v clips to the start line's tail (2), not the full span", data[2])

	data16, err16 := lspserver.semantic_tokens_encode(captures, "ab\ncd\n", nil, .Utf16, enc_ranks(), context.allocator)
	testing.expectf(t, err16 == .None, "utf-16 encode failed: %v", err16)
	defer delete(data16, context.allocator)
	testing.expectf(t, len(data16) == 5, "utf-16 data holds %v integers, want 5", len(data16))
	testing.expectf(t, data16[0] == 0 && data16[1] == 0 && data16[2] == 2, "utf-16 token = line %v char %v length %v, want 0 0 2", data16[0], data16[1], data16[2])
}

// A "\r\n" terminator counts as no line character under either encoding:
// a token ending on the '\r' stops at the text tail, not on the
// terminator's second half.
@(test)
enc_crlf_terminator_counts_no_line_character :: proc(t: ^testing.T) {
	// Bytes: a[0] b[1] \r[2] \n[3] c[4] d[5].
	captures := []lspserver.Capture_Hit{
		{capture = "variable", start_byte = 0, end_byte = 3}, // "ab\r" — ends on the '\r'
		{capture = "variable", start_byte = 4, end_byte = 6}, // "cd" on line 1
	}
	data, err := lspserver.semantic_tokens_encode(captures, "ab\r\ncd\r\n", nil, .Utf8, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "utf-8 encode failed: %v", err)
	defer delete(data, context.allocator)
	testing.expectf(t, data[0] == 0 && data[1] == 0 && data[2] == 2, "utf-8 token 0 = line %v char %v length %v, want 0 0 2", data[0], data[1], data[2])
	testing.expectf(t, data[5] == 1 && data[6] == 0 && data[7] == 2, "utf-8 token 1 = line %v char %v length %v, want 1 0 2", data[5], data[6], data[7])

	data16, err16 := lspserver.semantic_tokens_encode(captures, "ab\r\ncd\r\n", nil, .Utf16, enc_ranks(), context.allocator)
	testing.expectf(t, err16 == .None, "utf-16 encode failed: %v", err16)
	defer delete(data16, context.allocator)
	testing.expectf(t, data16[0] == 0 && data16[1] == 0 && data16[2] == 2, "utf-16 token 0 = line %v char %v length %v, want 0 0 2", data16[0], data16[1], data16[2])
	testing.expectf(t, data16[5] == 1 && data16[6] == 0 && data16[7] == 2, "utf-16 token 1 = line %v char %v length %v, want 1 0 2", data16[5], data16[6], data16[7])
}

// The utf-16 column cursor advances across multi-byte runes: each token
// on a line holding a two-byte rune counts that rune as one unit, and the
// second token's column builds on the carried position.
@(test)
enc_utf16_cursor_walks_multibyte_runes :: proc(t: ^testing.T) {
	// Bytes: x[0] ' '1 =2 ' '3 "4 日[5,6,7] "8 \n9 y[10].
	captures := []lspserver.Capture_Hit{
		{capture = "string",   start_byte = 4,  end_byte = 9},  // "日": 5 bytes, 3 utf-16 units
		{capture = "variable", start_byte = 10, end_byte = 11}, // y on line 1
	}
	data, err := lspserver.semantic_tokens_encode(captures, "x = \"日\"\ny\n", nil, .Utf16, enc_ranks(), context.allocator)
	testing.expectf(t, err == .None, "encode failed: %v", err)
	defer delete(data, context.allocator)

	line, char: int
	first := enc_decode_token(data, 0, &line, &char)
	testing.expectf(t, first.line == 0 && first.char == 4 && first.length == 3,
		"string sits at line %v char %v length %v, want 0 4 3", first.line, first.char, first.length)
	second := enc_decode_token(data, 5, &line, &char)
	testing.expectf(t, second.line == 1 && second.char == 0 && second.length == 1,
		"y sits at line %v char %v length %v, want 1 0 1", second.line, second.char, second.length)
}

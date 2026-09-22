// LSP-free text utilities: the position/range/text-edit helpers that
// don't depend on the LSP types (Position, Range, TextEdit,
// UnifiedSymbolInformation) or the regex engine (PCRE2, vendored
// separately). The regex-backed and LSP-position-tied helpers live with their
// consumers (src/lsp, src/svc) rather than in this LSP-free module.
//
// Two reasons the LSP-free subset is its own module:
//
//   1. The remaining types are an LSP concept (text coordinates are an
//      internal concept that LSP merely adopts). Decoupling them lets the
//      rest of the code depend on a small, well-typed text layer.
//   2. These primitives are pure: they take strings + ints, return strings +
//      ints (or allocators + slices). They are trivial to test and reason
//      about in isolation, and they are reusable far beyond the LSP layer
//      (e.g. for relative path resolution and indent detection in prompt
//      rendering).
package util

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// utf16_col_to_byte_offset converts a zero-based UTF-16 code unit column on
// a single line into the corresponding byte offset within that line. LSP
// positions use UTF-16 columns; Odin strings are UTF-8 byte sequences, so
// we walk the line once and sum rune byte widths until
// we've covered utf16_col units.
//
// If utf16_col points into the middle of a surrogate pair (col is odd
// within the pair), the byte offset of the pair's leading rune is returned
// — LSP convention rounds half-open positions to the start of the
// containing code point. If utf16_col is past the end of the line, the
// full line length is returned.
utf16_col_to_byte_offset :: proc(line: string, utf16_col: int) -> int {
	if utf16_col <= 0 {
		return 0
	}
	byte_off: int
	units: int
	i: int
	for i < len(line) {
		r, size := utf8.decode_rune_in_string(line[i:])
		span_end := units + utf16_len(r)
		if utf16_col < span_end {
			// The column lands inside this rune's unit span — at the
			// rune's first unit or mid-pair — and rounds to the rune's
			// start offset either way.
			return byte_off
		}
		byte_off += size
		units = span_end
		i += size
	}
	return byte_off
}

// line_start_offsets returns the byte offset of the start of every line in
// `text`. Lines are delimited by '\n'; the first entry is always 0.
// Callers can combine it with byte_offset_to_utf16_col to convert
// file-relative byte offsets into LSP line/UTF-16-column positions without
// re-scanning the whole file per position. The returned slice is allocated
// from `a`; the caller is responsible for freeing it.
line_start_offsets :: proc(text: string, a: mem.Allocator) -> []int {
	offsets := make([dynamic]int, 0, strings.count(text, "\n") + 1, a)
	append(&offsets, 0)
	for r, i in text {
		if r == '\n' {
			append(&offsets, i + 1)
		}
	}
	return offsets[:]
}

// byte_offset_to_utf16_col converts a byte offset within a single line to
// the corresponding zero-based UTF-16 code unit column. Inverse of
// utf16_col_to_byte_offset; needed when converting byte-based positions
// (e.g. tree-sitter columns) to LSP positions. If byte_off is at or past
// the end of the line, the line's UTF-16 length is returned.
byte_offset_to_utf16_col :: proc(line: string, byte_off: int) -> int {
	if byte_off <= 0 {
		return 0
	}
	pos: int
	units: int
	i: int
	for i < len(line) {
		r, size := utf8.decode_rune_in_string(line[i:])
		if pos >= byte_off {
			break
		}
		pos += size
		units += utf16_len(r)
		i += size
	}
	return units
}

// detect_indent returns the leading whitespace string (spaces or tabs) of
// the first non-blank line in `text`. Empty when all lines are blank or
// the text is empty. Useful for determining the base indentation of an
// extracted code block so it can be re-indented to match a target context.
detect_indent :: proc(text: string) -> string {
	for line in strings.split(text, "\n", context.temp_allocator) {
		trimmed := strings.trim_right(line, " \t\r")
		if trimmed == "" {
			continue
		}
		for ch, i in line {
			if ch != ' ' && ch != '\t' {
				return line[:i]
			}
		}
	}
	return ""
}

// limit_length truncates result to max_chars if necessary, trying each
// shortened candidate in order after the too-long notice; the first
// that fits wins, otherwise the notice stands alone (ports the
// reference mcp helper; max_chars <= 0 disables the limit). The cap
// counts characters (runes), not bytes — a byte count would cut CJK
// answers at a third of their intended length.
limit_length :: proc(
	result:    string,
	max_chars: int,
	shortened: []string,
	a := context.allocator,
) -> string {
	if max_chars <= 0 || utf8.rune_count_in_string(result) <= max_chars {
		return result
	}
	too_long := strings.concatenate({
		"The answer is too long (",
		int_to_dec(utf8.rune_count_in_string(result), a),
		" characters). You can adjust your query or raise the max_answer_chars parameter.",
	}, a)
	for s in shortened {
		candidate := strings.concatenate({too_long, "\n", s}, a)
		if utf8.rune_count_in_string(candidate) <= max_chars {
			return candidate
		}
	}
	return too_long
}

// resolve_max_chars returns requested when positive, otherwise default_max.
resolve_max_chars :: proc(requested, default_max: int) -> int {
	if requested <= 0 {
		return default_max
	}
	return requested
}

// ascii_equal_ci compares strings ASCII-case-insensitively without
// allocating (hot paths — header parsing, option matching — run it per
// frame or per key and must not grow any allocator).
ascii_equal_ci :: proc(x: string, y: string) -> bool {
	if len(x) != len(y) {
		return false
	}
	for i in 0..<len(x) {
		cx := x[i]
		cy := y[i]
		if cx >= 'A' && cx <= 'Z' {
			cx = cx + ('a' - 'A')
		}
		if cy >= 'A' && cy <= 'Z' {
			cy = cy + ('a' - 'A')
		}
		if cx != cy {
			return false
		}
	}
	return true
}

int_to_dec :: proc(v: int, a := context.allocator) -> string {
	buf: [24]u8
	if v == 0 {
		return "0"
	}
	neg := v < 0
	u := uint(v)
	if neg {
		u = uint(-v)
	}
	i := len(buf)
	for u > 0 {
		if i == 0 {
			return ""
		}
		i -= 1
		buf[i] = u8('0' + u % 10)
		u /= 10
	}
	if neg {
		if i == 0 {
			return ""
		}
		i -= 1
		buf[i] = '-'
	}
	// The digits live on this frame — clone them out or the string dangles.
	return strings.clone(string(buf[i:]), a)
}

// quoted_join renders `values` as `quote`-wrapped names joined by `sep` —
// the enumeration style of validation messages that list the accepted
// spellings of a closed vocabulary. The pieces are built on the temp
// allocator; only the final string is cloned into `a`.
quoted_join :: proc(values: []string, sep: string, quote: string, a := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, 32, context.temp_allocator)
	first := true
	for v in values {
		if !first {
			strings.write_string(&b, sep)
		}
		first = false
		strings.write_string(&b, quote)
		strings.write_string(&b, v)
		strings.write_string(&b, quote)
	}
	out := strings.clone(strings.to_string(b), a)
	strings.builder_destroy(&b)
	return out
}

// wire_names is quoted_join over a closed enum's wire vocabulary: each
// member renders through the same `to_string` the acceptance checks use,
// so a message built this way can never drift from the validation.
wire_names :: proc(
	$E: typeid,
	to_string: proc(E) -> string,
	sep: string,
	quote: string,
	a := context.allocator,
) -> string {
	values := make([dynamic]string, 0, 8, context.temp_allocator)
	defer delete(values)
	for e in E {
		append(&values, to_string(e))
	}
	return quoted_join(values[:], sep, quote, a)
}

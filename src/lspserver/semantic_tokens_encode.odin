// Encoding of highlights-query captures into the LSP 3.17 semanticTokens
// wire form. The capture tables and the legend live in semantic_tokens.odin;
// this file turns their results into the flat delta-encoded integer array
// the textDocument/semanticTokens/full response carries in data: per token
// the five integers deltaLine, deltaStartChar, length, tokenType,
// tokenModifiers.
//
// Deltas in this wire form must be non-negative, so the encoder takes a
// position-ascending capture list and refuses one that would move
// backwards, and with it any byte range that does not index the source
// text — both are query-side defects, reported through Encode_Err instead
// of being encoded.
package lspserver

import "core:mem"
import "core:unicode/utf8"

import "src:util"

// Capture_Hit is one highlights-query capture: its bare dotted capture
// name (the form capture_token takes) and its byte range in the source
// text. The query side hands the encoder a slice of these ordered by
// start_byte.
Capture_Hit :: struct {
	capture:    string,
	start_byte: int,
	end_byte:   int,
}

// Encode_Err is the encoder's closed failure vocabulary. Captures_Unsorted
// reports an input whose captures would produce a negative delta;
// Capture_Out_Of_Range reports a capture whose byte range does not index
// the source text (start before zero, end before start, or end past the
// source's last byte).
Encode_Err :: enum {
	None,
	Captures_Unsorted,
	Capture_Out_Of_Range,
}

// Position_Encoding is the wire position vocabulary the connection
// negotiated at initialize. Utf8 counts columns in UTF-8 code units, which
// are bytes — tree-sitter's own convention, so capture ranges ride into
// the response unconverted. Utf16 counts UTF-16 code units, the protocol's
// fallback when a client does not offer utf-8; columns then convert
// through the open document's text.
Position_Encoding :: enum {
	Utf8,
	Utf16,
}

// Tok_Pos is one mapped token's absolute wire position, before the delta
// fold: line and start char in the negotiated position encoding, the
// length in the same units, and the legend indices.
Tok_Pos :: struct {
	line:       int,
	char:       int,
	length:     int,
	type_index: int,
	modifiers:  i32,
}

// doc_line_span returns one line's own text and its delimiter-exclusive
// end offset. The line runs from line_starts[line] to its '\n' (or the
// end of the text); one '\r' preceding that '\n' is stripped too — LSP
// counts neither half of a "\r\n" terminator as a line character. One
// home for that rule among the byte-span families: the tokens encoder
// and the diagnostics publish convert daemon byte spans against this
// span. (The relay family deliberately KEEPS the '\r' — see
// relay_line_text: its columns round-trip the daemon's own converter,
// which counts the byte.)
doc_line_span :: proc(text: string, line_starts: []int, line: int) -> (line_text: string, text_end: int) {
	line_start := line_starts[line]
	end: int
	if line + 1 < len(line_starts) {
		end = line_starts[line + 1]
	} else {
		end = len(text)
	}
	if end > line_start && text[end - 1] == '\n' {
		end -= 1
		if end > line_start && text[end - 1] == '\r' {
			end -= 1
		}
	}
	return text[line_start:end], end
}

// semantic_tokens_encode renders position-ascending captures as the
// semanticTokens data array in the connection's negotiated encoding
// (.Utf8 counts columns in bytes, .Utf16 in UTF-16 code units derived
// through the source text). Captures with no entry at any level of the
// capture tables emit nothing — the unknown-capture rule — and a
// capture's modifiers OR into one bitmask of legend bits. A token that
// spans lines cannot ride the wire form (each token names exactly one
// line), so it is clipped to the start line's tail under either encoding
// — the convention most servers apply to multi-line tokens.
//
// line_starts must be the line-start index of `source` (see
// util.line_start_offsets); nil builds one for the call. Its results are
// plain integers, so the array is safe to release before the caller reads
// the returned data. `ranks` is the connection's legend rank cache (see
// Legend_Ranks). The caller owns the returned array: request arenas
// free_all it, other allocators delete it with the allocator passed in.
semantic_tokens_encode :: proc(captures: []Capture_Hit, source: string, line_starts: []int, enc: Position_Encoding, ranks: Legend_Ranks, a: mem.Allocator) -> (data: []i32, err: Encode_Err) {
	idx := line_starts
	built := false
	if idx == nil {
		idx = util.line_start_offsets(source, a)
		built = true
	}
	defer if built {
		delete(idx, a)
	}
	toks, perr := semantic_tokens_positions(captures, source, idx, enc, ranks, a)
	if perr != .None {
		return nil, perr
	}
	defer delete(toks, a)
	return semantic_tokens_data(toks, a), .None
}

// semantic_tokens_positions is the shared first pass: one walk over the
// ascending captures that validates them (same rules and order as the
// original single-pass encoder: range check, then sortedness, per
// capture), folds the source's newlines into the line count, maps each
// capture through the tables (unknown captures skip silently but still
// advance the fold), and computes the absolute wire position per emitted
// token. Nothing is allocated per token; the positions array is one
// up-front allocation, freed here on every error path.
//
// line_starts delimits the per-line conversion for both encodings: every
// token is measured against its start line's own text (doc_line_span) so
// a multi-line capture clips at that line's tail. Under .Utf16 the column
// walk carries one cursor per line — captures ascend, so each line's
// bytes are walked once (for the line's unit total) plus each token's own
// span — never a re-walk from the line start per endpoint.
semantic_tokens_positions :: proc(captures: []Capture_Hit, source: string, line_starts: []int, enc: Position_Encoding, ranks: Legend_Ranks, a: mem.Allocator) -> (toks: []Tok_Pos, err: Encode_Err) {
	dyn := make([dynamic]Tok_Pos, 0, len(captures), a)

	line:       int // current line, counted from 0
	line_start: int // byte offset of the current line's first byte
	scanned:    int // source prefix already folded into the line count

	// The utf-16 column cursor: the line it holds, that line's full unit
	// count (the multi-line clip length), and the position — byte offset
	// within the line's text, units consumed — the walk sits at. Captures
	// ascend, so within a line both only move forward.
	cur_line:  int = -1
	cur_total: int
	cur_off:   int
	cur_units: int

	for capture in captures {
		if capture.start_byte < 0 || capture.end_byte < capture.start_byte || capture.end_byte > len(source) {
			delete(dyn)
			return nil, .Capture_Out_Of_Range
		}
		// scanned is the highest start byte walked so far, so a capture
		// below it is the sortedness precondition failing — the one
		// shape in which the deltas would go negative.
		if capture.start_byte < scanned {
			delete(dyn)
			return nil, .Captures_Unsorted
		}
		for i in scanned ..< capture.start_byte {
			if source[i] == '\n' {
				line += 1
				line_start = i + 1
			}
		}
		scanned = capture.start_byte

		token, modifiers, found := capture_token(capture.capture)
		if !found {
			continue
		}
		// The ranks were derived from the same mapping tables at server
		// init, so every type a row carries has a legend rank — a -1
		// here is unreachable by construction; skipping keeps the pass
		// total without a panic. Same structural argument for the bits
		// below: every member of a mapped capture's modifier set is
		// carried by some row, and the ranks hold exactly the modifiers
		// rows carry.
		type_index := ranks.type_rank[int(token)]
		if type_index < 0 {
			continue
		}
		wire_modifiers: i32
		for m in Token_Modifier {
			if m not_in modifiers {
				continue
			}
			if bit := ranks.modifier_bit[int(m)]; bit >= 0 {
				wire_modifiers |= i32(1) << u32(bit)
			}
		}

		line_text, text_end := doc_line_span(source, line_starts, line)
		tail := text_end - line_start // the line's own byte length
		start_off := capture.start_byte - line_start
		if start_off > tail {
			// A capture opening on the line's terminator sits at the
			// tail: the terminator is no line character.
			start_off = tail
		}

		start_char: int
		length:     int
		switch enc {
		case .Utf8:
			// The negotiated column unit is the byte.
			start_char = start_off
			end_off := capture.end_byte - line_start
			if end_off > tail {
				// Multi-line token: clip to the start line's tail.
				end_off = tail
			}
			length = end_off - start_off
		case .Utf16:
			if line != cur_line {
				// First token on this line: one walk over the line's
				// text fixes its unit total for the clip length, and
				// the carried position restarts with it.
				cur_line = line
				cur_total = util.byte_offset_to_utf16_col(line_text, len(line_text))
				cur_off = 0
				cur_units = 0
			}
			for cur_off < start_off {
				r, size := utf8.decode_rune_in_string(line_text[cur_off:])
				cur_off += size
				cur_units += util.utf16_len(r)
			}
			start_char = cur_units
			end_off := capture.end_byte - line_start
			if end_off > tail {
				// Multi-line token: clip to the start line's tail.
				length = cur_total - start_char
			} else {
				// The token's own span, walked within the line's text.
				length = util.byte_offset_to_utf16_col(line_text[start_off:], end_off - start_off)
			}
		}
		append(&dyn, Tok_Pos{line = line, char = start_char, length = length, type_index = type_index, modifiers = wire_modifiers})
	}
	return dyn[:], .None
}

// semantic_tokens_data is the shared second pass: the non-negative delta
// fold over the position-ascending token list. deltaStartChar is relative
// to the previous token's start char on the same line and to the line
// start across a line change. The caller owns the returned array.
semantic_tokens_data :: proc(toks: []Tok_Pos, a: mem.Allocator) -> []i32 {
	dyn := make([dynamic]i32, 0, len(toks)*5, a)

	prev_line: int
	prev_char: int
	for tok in toks {
		char_base := prev_char
		if tok.line != prev_line {
			char_base = 0
		}
		append(&dyn, i32(tok.line - prev_line), i32(tok.char - char_base), i32(tok.length), i32(tok.type_index), tok.modifiers)
		prev_line, prev_char = tok.line, tok.char
	}
	return dyn[:]
}

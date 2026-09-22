// Tree-free structural projection for strict JSON: the streaming mirror of
// structure.odin's read face, serving files above the parse-tree budget
// (a tree costs roughly 25x its source bytes, so a multi-megabyte model or
// a JSONL log must not be parsed into one). The scanner walks the raw
// bytes with a cursor whose whole state is the offset plus a running line
// count — nothing is materialized per token, and subtrees on diverging
// paths cost only the byte walk around them. Answers reuse the tree
// face's exact shapes: the outline renders through the same
// Structure_State writer (same indentation, previews, array heads, depth
// and item caps), and the path resolver speaks the same segment grammar
// (structure_parse_path) with the same render formats and miss-error
// texts, so a query answers identically below and above the tree budget.
// A file holding several top-level values is a JSONL stream: the root
// answers as a sequence (indexes and [] address records; the outline
// renders one entry per record). Keys and values are raw source spans —
// escape sequences are not decoded, matching the tree face's key text.
package ts

import "core:fmt"
import "core:strings"

STREAM_MAX_DEPTH :: 1024 // nesting bound; deeper input is malformed, not walked

// Stream_Cursor is the scanner's whole state: the source, the byte offset,
// and the 0-based row containing that offset (the newline count before
// it). Helpers advance monotonically and keep the row current, so a
// value's line span falls out of where the cursor stood before and after.
Stream_Cursor :: struct {
	src:  string,
	i:    int,
	line: int,
}

// stream_advance moves the cursor to `j` (never backwards), counting
// newlines so the row stays the row of src[i].
stream_advance :: proc(c: ^Stream_Cursor, j: int) {
	for k := c.i; k < j; k += 1 {
		if c.src[k] == '\n' {
			c.line += 1
		}
	}
	c.i = j
}

stream_ws :: proc(c: ^Stream_Cursor) {
	for c.i < len(c.src) {
		switch c.src[c.i] {
		case ' ', '\t', '\r':
			c.i += 1
		case '\n':
			c.i += 1
			c.line += 1
		case:
			return
		}
	}
}

stream_peek :: proc(c: ^Stream_Cursor) -> u8 {
	if c.i < len(c.src) {
		return c.src[c.i]
	}
	return 0
}

stream_err :: proc(c: ^Stream_Cursor, what: string, a := context.allocator) -> string {
	return fmt.aprintf("parse error near line %d: %s", max(c.line, 0), what, allocator = a)
}

// stream_expect consumes one exact byte (whitespace-skipped first).
stream_expect :: proc(c: ^Stream_Cursor, want: u8, what: string, a := context.allocator) -> string {
	stream_ws(c)
	if c.i >= len(c.src) || c.src[c.i] != want {
		return stream_err(c, what, a)
	}
	stream_advance(c, c.i + 1)
	return ""
}

// stream_string_span consumes a double-quoted span starting at src[i] ==
// '"' and returns the inner byte range (quotes excluded, escapes intact).
// A raw newline inside the span is malformed strict JSON — the grammar
// rejects it on the tree path, so the stream rejects it too.
stream_string_span :: proc(c: ^Stream_Cursor, a := context.allocator) -> (lo: int, hi: int, err: string) {
	lo = c.i + 1
	i := c.i + 1
	for i < len(c.src) {
		switch c.src[i] {
		case '\\':
			// Escape parity with the tree face's grammar: the escaped
			// byte is one of " \ / b f n r t u — \u carries no
			// hex-digit requirement there, so it carries none here.
			if i + 1 >= len(c.src) || !stream_escape_char(c.src[i + 1]) {
				return 0, 0, stream_err(c, "invalid escape sequence", a)
			}
			i += 2
		case '"':
			hi = i
			stream_advance(c, i + 1)
			return lo, hi, ""
		case '\n':
			return 0, 0, stream_err(c, "raw newline inside a string", a)
		case:
			i += 1
		}
	}
	return 0, 0, stream_err(c, "unterminated string", a)
}

// stream_escape_char reports whether `e` may follow a backslash inside a
// string — the tree face's escape grammar, one byte of " \ / b f n r t u.
stream_escape_char :: proc(e: u8) -> bool {
	switch e {
	case '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u':
		return true
	}
	return false
}

stream_token_is :: proc(c: ^Stream_Cursor, word: string) -> bool {
	end := min(c.i + len(word), len(c.src))
	return string(c.src[c.i:end]) == word
}

// stream_value consumes exactly one value starting at the (ws-skipped)
// cursor and returns its byte span; the cursor lands just past it. A
// full pass over the document doubles as validation — every later walk
// runs on input this proc has already accepted.
stream_value :: proc(c: ^Stream_Cursor, depth: int, a := context.allocator) -> (lo: int, hi: int, err: string) {
	stream_ws(c)
	lo = c.i
	if depth > STREAM_MAX_DEPTH {
		return 0, 0, stream_err(c, "nesting deeper than the stream budget", a)
	}
	if c.i >= len(c.src) {
		return 0, 0, stream_err(c, "unexpected end of input", a)
	}
	switch c.src[c.i] {
	case '"':
		_, end, serr := stream_string_span(c, a)
		if serr != "" {
			return 0, 0, serr
		}
		return lo, end, ""
	case '{':
		stream_advance(c, c.i + 1)
		stream_ws(c)
		if stream_peek(c) == '}' {
			stream_advance(c, c.i + 1)
			return lo, c.i, ""
		}
		for {
			stream_ws(c)
			if stream_peek(c) != '"' {
				return 0, 0, stream_err(c, "expected an object key", a)
			}
			_, _, kerr := stream_string_span(c, a)
			if kerr != "" {
				return 0, 0, kerr
			}
			if werr := stream_expect(c, ':', "expected ':' after an object key", a); werr != "" {
				return 0, 0, werr
			}
			if _, _, verr := stream_value(c, depth + 1, a); verr != "" {
				return 0, 0, verr
			}
			stream_ws(c)
			b := stream_peek(c)
			if b == ',' {
				stream_advance(c, c.i + 1)
				continue
			}
			if b == '}' {
				stream_advance(c, c.i + 1)
				return lo, c.i, ""
			}
			return 0, 0, stream_err(c, "expected ',' or '}' in an object", a)
		}
	case '[':
		stream_advance(c, c.i + 1)
		stream_ws(c)
		if stream_peek(c) == ']' {
			stream_advance(c, c.i + 1)
			return lo, c.i, ""
		}
		for {
			if _, _, verr := stream_value(c, depth + 1, a); verr != "" {
				return 0, 0, verr
			}
			stream_ws(c)
			b := stream_peek(c)
			if b == ',' {
				stream_advance(c, c.i + 1)
				continue
			}
			if b == ']' {
				stream_advance(c, c.i + 1)
				return lo, c.i, ""
			}
			return 0, 0, stream_err(c, "expected ',' or ']' in an array", a)
		}
	case '-', '0'..='9':
		// Number parity with the tree face's grammar: optional '-',
		// integer ('0' alone or nonzero-led — a digit after a leading
		// zero is a second token), then optional fraction ('.' with
		// optional digits — "1." is admitted) and optional exponent
		// ('e'/'E', optional '-', required digits — the grammar admits
		// no '+'). Looser shapes ("1.2.3", "1e+2") fail here or leave a
		// trailing byte the caller's delimiter check rejects.
		i := c.i
		if c.src[i] == '-' {
			i += 1
		}
		if i >= len(c.src) || c.src[i] < '0' || c.src[i] > '9' {
			return 0, 0, stream_err(c, "malformed number", a)
		}
		if c.src[i] == '0' {
			i += 1
			if i < len(c.src) && c.src[i] >= '0' && c.src[i] <= '9' {
				return 0, 0, stream_err(c, "malformed number", a)
			}
		} else {
			for i < len(c.src) && c.src[i] >= '0' && c.src[i] <= '9' {
				i += 1
			}
		}
		if i < len(c.src) && c.src[i] == '.' {
			i += 1
			for i < len(c.src) && c.src[i] >= '0' && c.src[i] <= '9' {
				i += 1
			}
		}
		if i < len(c.src) && (c.src[i] == 'e' || c.src[i] == 'E') {
			i += 1
			if i < len(c.src) && c.src[i] == '-' {
				i += 1
			}
			if i >= len(c.src) || c.src[i] < '0' || c.src[i] > '9' {
				return 0, 0, stream_err(c, "malformed number", a)
			}
			for i < len(c.src) && c.src[i] >= '0' && c.src[i] <= '9' {
				i += 1
			}
		}
		stream_advance(c, i)
		return lo, c.i, ""
	case 't':
		if stream_token_is(c, "true") {
			stream_advance(c, c.i + 4)
			return lo, c.i, ""
		}
	case 'f':
		if stream_token_is(c, "false") {
			stream_advance(c, c.i + 5)
			return lo, c.i, ""
		}
	case 'n':
		if stream_token_is(c, "null") {
			stream_advance(c, c.i + 4)
			return lo, c.i, ""
		}
	}
	return 0, 0, stream_err(c, "unexpected byte where a value was expected", a)
}

// stream_is_jsonl consumes the top-level values and reports whether more
// than one was present (a JSONL stream). The pass validates the whole
// document — every record, not just the first — so a torn tail surfaces
// here as a parse error; the count passes downstream discard errors, and
// the render pass would otherwise misreport the tail as a max_chars
// truncation.
stream_is_jsonl :: proc(src: string, a := context.allocator) -> (jsonl: bool, err: string) {
	c := Stream_Cursor{src = src}
	if _, _, verr := stream_value(&c, 0, a); verr != "" {
		return false, verr
	}
	seen_second := false
	for {
		stream_ws(&c)
		if c.i >= len(src) {
			return seen_second, ""
		}
		if _, _, verr := stream_value(&c, 0, a); verr != "" {
			return false, verr
		}
		seen_second = true
	}
}

// stream_count_values counts the values from the cursor to the end of
// input or the closing bracket — a cheap byte pass used by array heads
// ("[N]"), the "+N more" remainder, and negative indexes. JSONL records
// (bracket=false) are whitespace-separated: no comma is required between
// them.
stream_count_values :: proc(c: ^Stream_Cursor, bracket: bool, a := context.allocator) -> (count: int, err: string) {
	for {
		stream_ws(c)
		if c.i >= len(c.src) {
			return count, ""
		}
		if bracket && stream_peek(c) == ']' {
			return count, ""
		}
		if _, _, verr := stream_value(c, 0, a); verr != "" {
			return count, verr
		}
		count += 1
		stream_ws(c)
		if stream_peek(c) == ',' {
			stream_advance(c, c.i + 1)
			continue
		}
		if bracket && stream_peek(c) == ']' {
			return count, ""
		}
		if !bracket && c.i < len(c.src) {
			continue
		}
		if !bracket {
			return count, ""
		}
		return count, stream_err(c, "expected ',' or ']' in an array", a)
	}
}

// ---------------------------------------------------------------------------
// Outline (path == "")
// ---------------------------------------------------------------------------

structure_stream_outline :: proc(
	source: string,
	opts: Structure_Options,
	a := context.allocator,
) -> (text: string, truncated: bool, err: string) {
	jsonl, jerr := stream_is_jsonl(source, a)
	if jerr != "" {
		return "", false, jerr
	}
	b := strings.builder_make_len_cap(0, 256, a)
	// The buffer rides `a` only until the clone-out (every return below):
	// destroy it so the caller's allocator carries the answer once.
	defer strings.builder_destroy(&b)
	st := structure_state_init(&b, opts, a)
	end := len(source)
	for end > 0 {
		last := source[end - 1]
		if last == '\n' || last == '\r' || last == ' ' || last == '\t' {
			end -= 1
		} else {
			break
		}
	}
	tail := Stream_Cursor{src = source}
	stream_advance(&tail, end)
	if jsonl {
		counter := Stream_Cursor{src = source}
		n, _ := stream_count_values(&counter, false, a)
		structure_write_line(&st, 0, strings.concatenate({
			fmt.aprintf("[%d]", n, allocator = a),
			" ", stream_span_label(0, tail.line, a),
		}, a))
		if st.truncated {
			return strings.clone(strings.to_string(b), a), true, ""
		}
		c := Stream_Cursor{src = source}
		render_stream_seq(&st, &c, 1, false, a)
		return strings.clone(strings.to_string(b), a), st.truncated, ""
	}
	c := Stream_Cursor{src = source}
	stream_ws(&c)
	start_line := c.line
	if _, _, verr := stream_value(&c, 0, a); verr != "" {
		return "", false, verr
	}
	structure_write_line(&st, 0, strings.concatenate({
		stream_root_head(source, a),
		" ", stream_span_label(start_line, c.line, a),
	}, a))
	if st.truncated {
		return strings.clone(strings.to_string(b), a), true, ""
	}
	c2 := Stream_Cursor{src = source}
	render_stream_value(&st, &c2, 1, a)
	return strings.clone(strings.to_string(b), a), st.truncated, ""
}

// stream_root_head renders the root's inline shape marker: {} for an
// object, [N] with the item count for an array, the clamped preview
// otherwise.
stream_root_head :: proc(source: string, a := context.allocator) -> string {
	c := Stream_Cursor{src = source}
	stream_ws(&c)
	switch stream_peek(&c) {
	case '{':
		return "{}"
	case '[':
		counter := c
		stream_advance(&counter, counter.i + 1)
		n, _ := stream_count_values(&counter, true, a)
		return fmt.aprintf("[%d]", n, allocator = a)
	case:
		return stream_preview_at(source, c.i, a, nil)
	}
}

// render_stream_value renders the value at the cursor (document order,
// budget-capped): objects one entry per pair, arrays one entry per item
// under the same caps the tree face applies. It returns at the budget
// cut — everything past it would be dropped by the writer anyway. Input
// was validated in full before rendering, so parse divergence here only
// ends the walk early.
render_stream_value :: proc(st: ^Structure_State, c: ^Stream_Cursor, depth: int, a := context.allocator) {
	if st.truncated {
		return
	}
	if depth >= STRUCTURE_MAX_DEPTH {
		structure_write_line(st, depth, "… (max depth)")
		return
	}
	kind := stream_peek(c)
	if kind == '{' {
		stream_advance(c, c.i + 1)
		stream_ws(c)
		if stream_peek(c) == '}' {
			stream_advance(c, c.i + 1)
			return
		}
		for {
			stream_ws(c)
			if stream_peek(c) != '"' {
				return
			}
			klo, khi, _ := stream_string_span(c, a)
			if stream_expect(c, ':', "expected ':' after an object key", a) != "" {
				return
			}
			render_stream_entry(st, c, string(c.src[klo:khi]), depth, a)
			if st.truncated {
				return
			}
			stream_ws(c)
			b := stream_peek(c)
			if b == ',' {
				stream_advance(c, c.i + 1)
				continue
			}
			if b == '}' {
				stream_advance(c, c.i + 1)
			}
			return
		}
	}
	if kind == '[' {
		render_stream_seq(st, c, depth, true, a)
	}
}

// render_stream_seq renders sequence items: an array's (cursor at its
// '[') or a JSONL root's (bracket=false, cursor at the first record),
// under the tree face's array caps — at most max_array_items entries,
// then the "+N more" line with the exact remainder.
render_stream_seq :: proc(st: ^Structure_State, c: ^Stream_Cursor, depth: int, bracket: bool, a := context.allocator) {
	if st.truncated {
		return
	}
	if bracket {
		stream_advance(c, c.i + 1)
		stream_ws(c)
		if stream_peek(c) == ']' {
			stream_advance(c, c.i + 1)
			return
		}
	}
	i := 0
	for {
		if i >= st.opts.max_array_items {
			rest, _ := stream_count_values(c, bracket, a)
			structure_write_line(st, depth, fmt.aprintf("… +%d more", rest, allocator = a))
			return
		}
		render_stream_entry(st, c, fmt.aprintf("[%d]", i, allocator = a), depth, a)
		if st.truncated {
			return
		}
		i += 1
		stream_ws(c)
		b := stream_peek(c)
		if b == ',' {
			stream_advance(c, c.i + 1)
			continue
		}
		if bracket && b == ']' {
			stream_advance(c, c.i + 1)
		}
		if !bracket && c.i < len(c.src) {
			continue
		}
		return
	}
}

// render_stream_entry writes one labeled child and recurses; the cursor
// sits at the child's value start (after the pair's ':').
render_stream_entry :: proc(st: ^Structure_State, c: ^Stream_Cursor, label: string, depth: int, a := context.allocator) {
	start_line := c.line
	child := c^
	stream_ws(&child)
	kind := stream_peek(&child)
	head := ""
	switch kind {
	case '{':
		head = "{}"
	case '[':
		counter := child
		stream_advance(&counter, counter.i + 1)
		n, _ := stream_count_values(&counter, true, a)
		head = fmt.aprintf("[%d]", n, allocator = a)
	case:
		head = stream_preview_at(c.src, child.i, a, st)
	}
	if _, _, verr := stream_value(c, 0, a); verr != "" {
		st.truncated = true
		return
	}
	structure_write_line(st, depth, strings.concatenate({
		label, ": ", head,
		" ", stream_span_label(start_line, c.line, a),
	}, a))
	if kind == '{' || kind == '[' {
		render_stream_value(st, &child, depth + 1, a)
	}
}

// stream_preview_at clamps the value starting at offset i to whole runes,
// folding newlines — the tree face's scalar preview over a raw span.
stream_preview_at :: proc(source: string, i: int, a := context.allocator, st: ^Structure_State = nil) -> string {
	runes := STRUCTURE_PREVIEW_RUNES
	if st != nil && st.opts.preview_runes > 0 {
		runes = st.opts.preview_runes
	}
	end := i
	if i < len(source) && source[i] == '"' {
		// Inside a quoted scalar the delimiter bytes are ordinary
		// characters: the span runs to the closing quote (escape-aware),
		// or the preview would cut mid-string where the tree face
		// previews the whole node text.
		end = i + 1
		for end < len(source) {
			if source[end] == '\\' {
				end += 2
				continue
			}
			if source[end] == '"' {
				end += 1
				break
			}
			end += 1
		}
		if end > len(source) {
			end = len(source)
		}
	} else {
		for end < len(source) {
			b := source[end]
			if b == ',' || b == '}' || b == ']' || b == '\n' {
				break
			}
			end += 1
		}
	}
	text := strings.trim_space(source[i:end])
	if len(text) == 0 {
		return "(empty)"
	}
	b := strings.builder_make_len_cap(0, len(text) + 8, a)
	defer strings.builder_destroy(&b)
	count := 0
	for r in text {
		if count >= runes {
			strings.write_rune(&b, '…')
			break
		}
		if r == '\n' || r == '\r' {
			strings.write_rune(&b, '⏎')
		} else {
			strings.write_rune(&b, r)
		}
		count += 1
	}
	return strings.clone(strings.to_string(b), a)
}

// stream_span_label renders the (L..) / (L..-L..) line label.
stream_span_label :: proc(start, end: int, a := context.allocator) -> string {
	if start == end {
		return fmt.aprintf("(L%d)", start, allocator = a)
	}
	return fmt.aprintf("(L%d-L%d)", start, end, allocator = a)
}

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

// structure_stream_resolve_path evaluates the same jq-style subset as
// structure_resolve_path over the raw bytes — same parser, same render
// shapes, same miss-error texts — the entry for JSON above the tree
// budget. A JSONL root answers as a sequence.
structure_stream_resolve_path :: proc(
	source: string,
	path: string,
	max_chars: int,
	a := context.allocator,
) -> (res: Structure_Path_Result, err: string) {
	segs, want_keys, iterate_last, perr := structure_parse_path(path, a)
	if perr != "" {
		return {}, perr
	}

	jsonl, jerr := stream_is_jsonl(source, a)
	if jerr != "" {
		return {}, jerr
	}

	c := Stream_Cursor{src = source}
	stream_ws(&c)

	// A JSONL root with no segments is the record list itself: [] iterates
	// the records, anything else addresses them as array items.
	if jsonl && len(segs) == 0 {
		if want_keys {
			return {}, "the root is not an object; | keys needs one"
		}
		if iterate_last {
			return stream_render_items(&c, max_chars, false, a), ""
		}
		end := len(source)
		for end > 0 && (source[end - 1] == '\n' || source[end - 1] == ' ' || source[end - 1] == '\t' || source[end - 1] == '\r') {
			end -= 1
		}
		content := string(source[:end])
		truncated := false
		if max_chars > 0 && len(content) > max_chars {
			content = content[:max_chars]
			truncated = true
		}
		tail := Stream_Cursor{src = source}
		stream_advance(&tail, end)
		return {
			kind = .Value,
			content = strings.clone(content, a),
			start_line = 0,
			end_line = tail.line,
			truncated = truncated,
		}, ""
	}

	seq := jsonl // the cursor addresses the record list, not a bracketed array
	prefix := ""
	for seg_index := 0; seg_index < len(segs); seg_index += 1 {
		seg := segs[seg_index]
		at := "the root"
		if prefix != "" {
			at = strings.concatenate({"path ", prefix}, a)
		}
		stream_ws(&c)
		b := stream_peek(&c)
		if seg.kind == .Field {
			if seq || b == '[' {
				return {}, strings.concatenate({
					at, " is an array; use [index] or [] instead of a field name",
				}, a)
			}
			if b != '{' {
				return {}, strings.concatenate({
					at, " is a scalar; the path cannot descend into it",
				}, a)
			}
			// Scan for the field; non-matching values are only walked
			// past. The available-keys sample feeds the miss error.
			avail := make([dynamic]string, 0, STRUCTURE_MAX_KEYS_LISTED, a)
			defer delete(avail)
			keys_seen := 0
			matched := false
			stream_advance(&c, c.i + 1) // the '{'
			stream_ws(&c)
			if stream_peek(&c) != '}' {
				for {
					stream_ws(&c)
					if stream_peek(&c) != '"' {
						return {}, stream_err(&c, "expected an object key", a)
					}
					klo, khi, kerr := stream_string_span(&c, a)
					if kerr != "" {
						return {}, kerr
					}
					if werr := stream_expect(&c, ':', "expected ':' after an object key", a); werr != "" {
						return {}, werr
					}
					key := string(c.src[klo:khi])
					if key == seg.field {
						matched = true
						break
					}
					keys_seen += 1
					if len(avail) < STRUCTURE_MAX_KEYS_LISTED {
						append(&avail, key)
					}
					if _, _, verr := stream_value(&c, 0, a); verr != "" {
						return {}, verr
					}
					stream_ws(&c)
					nb := stream_peek(&c)
					if nb == ',' {
						stream_advance(&c, c.i + 1)
						continue
					}
					if nb == '}' {
						break
					}
					return {}, stream_err(&c, "expected ',' or '}' in an object", a)
				}
			}
			if !matched {
				list := make([dynamic]string, 0, len(avail) + 1, a)
				defer delete(list)
				for k in avail {
					append(&list, k)
				}
				if keys_seen > len(avail) {
					append(&list, fmt.aprintf("… (+%d more)", keys_seen - len(avail), allocator = a))
				}
				joined, _ := strings.join(list[:], ", ", a)
				return {}, strings.concatenate({
					"unknown field \"", seg.field, "\" at ", at,
					"; available: ", joined,
				}, a)
			}
		} else {
			if b == '{' && !seq {
				return {}, strings.concatenate({
					at, " is an object; use a field name instead of [index]",
				}, a)
			}
			if b != '[' && !seq {
				return {}, strings.concatenate({
					at, " is a scalar; the path cannot descend into it",
				}, a)
			}
			counter := c
			total := 0
			if seq {
				total, _ = stream_count_values(&counter, false, a)
			} else {
				stream_advance(&counter, counter.i + 1) // the '['
				total, _ = stream_count_values(&counter, true, a)
			}
			idx := seg.index
			if idx < 0 {
				idx += total
			}
			if idx < 0 || idx >= total {
				return {}, strings.concatenate({
					"index ", fmt.aprintf("%d", seg.index, allocator = a),
					" out of range at ", at,
					" (", fmt.aprintf("%d", total, allocator = a), " items)",
				}, a)
			}
			if !seq {
				stream_advance(&c, c.i + 1) // the '['
			}
			for n := 0; n < idx; n += 1 {
				stream_ws(&c)
				if _, _, verr := stream_value(&c, 0, a); verr != "" {
					return {}, verr
				}
				stream_ws(&c)
				if stream_peek(&c) == ',' {
					stream_advance(&c, c.i + 1)
				}
			}
			stream_ws(&c)
		}
		seq = false
		prefix = strings.concatenate({prefix, seg.label}, a)
	}

	at := "the root"
	if prefix != "" {
		at = strings.concatenate({"path ", prefix}, a)
	}
	stream_ws(&c)
	b := stream_peek(&c)
	if want_keys {
		if b != '{' {
			return {}, strings.concatenate({at, " is not an object; | keys needs one"}, a)
		}
		return stream_render_keys(&c, max_chars, a), ""
	}
	if iterate_last {
		if b != '[' {
			return {}, strings.concatenate({at, " is not an array; [] iterates arrays"}, a)
		}
		return stream_render_items(&c, max_chars, true, a), ""
	}

	lo := c.i
	start_line := c.line
	if _, _, verr := stream_value(&c, 0, a); verr != "" {
		return {}, verr
	}
	content := string(source[lo:c.i])
	truncated := false
	if max_chars > 0 && len(content) > max_chars {
		content = content[:max_chars]
		truncated = true
	}
	return {
		kind = .Value,
		content = strings.clone(content, a),
		start_line = start_line,
		end_line = c.line,
		truncated = truncated,
	}, ""
}

// stream_render_keys emits `key (Lrow)` per pair of the object whose
// cursor sits on its '{' — the tree face's | keys render.
stream_render_keys :: proc(c: ^Stream_Cursor, max_chars: int, a := context.allocator) -> Structure_Path_Result {
	stream_ws(c)
	start_line := c.line
	b := strings.builder_make_len_cap(0, 128, a)
	defer strings.builder_destroy(&b)
	used := 0
	truncated := false
	stream_advance(c, c.i + 1) // the '{'
	stream_ws(c)
	if stream_peek(c) != '}' {
		for {
			stream_ws(c)
			if stream_peek(c) != '"' {
				return {truncated = true}
			}
			klo, khi, kerr := stream_string_span(c, a)
			if kerr != "" {
				return {truncated = true}
			}
			key_line := c.line
			line := fmt.aprintf("%s (L%d)\n", c.src[klo:khi], key_line, allocator = a)
			if max_chars > 0 && used + len(line) > max_chars {
				truncated = true
				break
			}
			strings.write_string(&b, line)
			used += len(line)
			if werr := stream_expect(c, ':', "expected ':' after an object key", a); werr != "" {
				return {truncated = true}
			}
			if _, _, verr := stream_value(c, 0, a); verr != "" {
				return {truncated = true}
			}
			stream_ws(c)
			x := stream_peek(c)
			if x == ',' {
				stream_advance(c, c.i + 1)
				continue
			}
			if x == '}' {
				stream_advance(c, c.i + 1)
				break
			}
			return {truncated = true}
		}
	} else {
		stream_advance(c, c.i + 1)
	}
	return {
		kind = .Keys,
		content = strings.clone(strings.to_string(b), a),
		start_line = start_line,
		end_line = c.line,
		truncated = truncated,
	}
}

// stream_render_items emits the tree face's [] render over a sequence:
// an array's (cursor on its '[') or a JSONL root's (bracket=false).
stream_render_items :: proc(c: ^Stream_Cursor, max_chars: int, bracket: bool, a := context.allocator) -> Structure_Path_Result {
	stream_ws(c)
	start_line := c.line
	if bracket {
		stream_advance(c, c.i + 1) // the '['
	}
	b := strings.builder_make_len_cap(0, 128, a)
	defer strings.builder_destroy(&b)
	used := 0
	truncated := false
	i := 0
	stream_ws(c)
	if bracket && stream_peek(c) == ']' {
		stream_advance(c, c.i + 1)
	}
	for !truncated && c.i < len(c.src) && !(bracket && stream_peek(c) == ']') {
		lo := c.i
		is_line := c.line
		if _, _, verr := stream_value(c, 0, a); verr != "" {
			return {truncated = true}
		}
		head := fmt.aprintf("[%d] (L%d-L%d):\n", i, is_line, c.line, allocator = a)
		if max_chars > 0 && used + len(head) > max_chars {
			truncated = true
			break
		}
		strings.write_string(&b, head)
		used += len(head)
		for line in strings.split(string(c.src[lo:c.i]), "\n", a) {
			out := strings.concatenate({"  ", line, "\n"}, a)
			if max_chars > 0 && used + len(out) > max_chars {
				truncated = true
				break
			}
			strings.write_string(&b, out)
			used += len(out)
		}
		if truncated {
			break
		}
		i += 1
		stream_ws(c)
		x := stream_peek(c)
		if x == ',' {
			stream_advance(c, c.i + 1)
			stream_ws(c)
			continue
		}
		if bracket && x == ']' {
			stream_advance(c, c.i + 1)
			break
		}
		if !bracket {
			continue
		}
		return {truncated = true}
	}
	return {
		kind = .Iterated,
		content = strings.clone(strings.to_string(b), a),
		start_line = start_line,
		end_line = c.line,
		truncated = truncated,
	}
}

// Structural projection for data files: an outline (an indented key tree
// with 0-based line numbers and clamped value previews) and a jq-style path
// resolver over the same walk. This is the read face for JSON-family and
// YAML files — the grammars ship no symbol captures, so the tags-driven
// outliner serves them nothing; agents otherwise fall back to grep.
//
// The walk speaks one pair vocabulary across grammars (node-type names
// verified against the compiled grammars): json roots at `document` with
// `object`/`pair`/`array`; json5 at `file` with `member` (and `comment`
// nodes skipped); yaml at `stream`/`document` with wrappers `block_node`
// and `flow_node` carrying `block_mapping`/`block_mapping_pair`/
// `block_sequence`/`block_sequence_item` and the flow_* mirrors. YAML
// anchors and aliases are surfaced (`&name`, `*name`) but never resolved —
// resolving merge keys is a separate contract.
package ts

import "base:runtime"
import "core:fmt"
import "core:strings"

STRUCTURE_PREVIEW_RUNES :: 60
STRUCTURE_MAX_ARRAY_ITEMS :: 10
STRUCTURE_MAX_DEPTH :: 16
STRUCTURE_MAX_KEYS_LISTED :: 25

Structure_Options :: struct {
	// max_chars caps the rendered answer at whole lines (outline) or bytes
	// (extraction); 0 disables the cap. truncated reports the cut.
	max_chars: int,
	// preview_runes clamps a scalar preview (0 = STRUCTURE_PREVIEW_RUNES).
	preview_runes: int,
	// max_array_items expands at most this many array entries (0 =
	// STRUCTURE_MAX_ARRAY_ITEMS); the rest collapse to a "+N more" line.
	max_array_items: int,
}

Structure_Path_Kind :: enum {
	Value, // the source slice of the reached node
	Iterated, // one indexed entry per array item
	Keys, // one line per object key, with its line number
}

Structure_Path_Result :: struct {
	kind:       Structure_Path_Kind,
	content:    string, // owned by `a`
	start_line: int, // 0-based; span start of the reached node
	end_line:   int, // 0-based, inclusive
	truncated:  bool,
}

// structure_outline renders the key tree of an already-parsed root.
structure_outline :: proc(root: Node, source: string, opts: Structure_Options, a := context.allocator) -> (text: string, truncated: bool) {
	b := strings.builder_make_len_cap(0, 256, a)
	// The buffer rides `a` only until the clone-out: destroy it so the
	// caller's allocator carries the answer once, not twice.
	defer strings.builder_destroy(&b)
	st := structure_state_init(&b, opts, a)
	structure_render_root(&st, root, source)
	return strings.clone(strings.to_string(b), a), st.truncated
}

// structure_resolve_path evaluates a jq-style subset against the tree:
// `.a.b` fields (quoted `."odd key"` and bracket `["odd key"]` forms
// allowed), `[3]` / `[-1]` indexes, a terminal `[]` iterate-all, and a
// terminal `| keys`. Misses return an
// error naming the deepest resolved prefix and the keys available there,
// so one retry self-corrects.
structure_resolve_path :: proc(
	root: Node,
	source: string,
	path: string,
	max_chars: int,
	a := context.allocator,
) -> (res: Structure_Path_Result, err: string) {
	segs, want_keys, iterate_last, perr := structure_parse_path(path, a)
	if perr != "" {
		return {}, perr
	}

	node := structure_root_value(root, source)
	prefix := ""
	for seg in segs {
		next, ok := structure_step(node, source, seg, a)
		if !ok {
			return {}, structure_step_error(node, source, seg, prefix, a)
		}
		node = next
		prefix = strings.concatenate({prefix, seg.label}, a)
	}

	if want_keys {
		if !structure_is_object(node) {
			return {}, strings.concatenate({
				"path ", prefix, " is not an object; | keys needs one",
			}, a)
		}
		return structure_render_keys(node, source, max_chars, a), ""
	}
	if iterate_last {
		if !structure_is_seq(node) {
			return {}, strings.concatenate({
				"path ", prefix, " is not an array; [] iterates arrays",
			}, a)
		}
		return structure_render_items(node, source, max_chars, a), ""
	}

	start, end := structure_span_lines(node)
	content := node_text(node, source)
	truncated := false
	if max_chars > 0 && len(content) > max_chars {
		content = content[:max_chars]
		truncated = true
	}
	return {
		kind = .Value,
		content = strings.clone(content, a),
		start_line = start,
		end_line = end,
		truncated = truncated,
	}, ""
}

// structure_error_row returns the 0-based row of the first ERROR node in
// the tree (-1 when the parse is clean) — the read face fails loudly on
// malformed files instead of outlining a half-tree.
structure_error_row :: proc(root: Node) -> int {
	stack := make([dynamic]Node, 0, 16, context.temp_allocator)
	defer delete(stack)
	append(&stack, root)
	for len(stack) > 0 {
		n := stack[len(stack) - 1]
		pop(&stack)
		if node_is_null(n) {
			continue
		}
		if node_is_error(n) {
			return int(node_start_point(n).row)
		}
		// Push children in reverse so the LIFO pop visits them in document
		// order — the first ERROR found is the earliest one in the file.
		for i := node_named_child_count(n); i > 0; i -= 1 {
			append(&stack, node_named_child(n, i - 1))
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Node vocabulary
// ---------------------------------------------------------------------------

structure_is_object :: proc(n: Node) -> bool {
	t := cstring_to_string(node_type(n))
	return t == "object" || t == "block_mapping" || t == "flow_mapping"
}

structure_is_array :: proc(n: Node) -> bool {
	t := cstring_to_string(node_type(n))
	return t == "array" || t == "block_sequence" || t == "flow_sequence"
}

// structure_is_seq marks array-likes the path resolver can index and
// iterate — arrays, plus a multi-document yaml stream (its documents are
// the items).
structure_is_seq :: proc(n: Node) -> bool {
	return structure_is_array(n) || cstring_to_string(node_type(n)) == "stream"
}

structure_is_pair :: proc(n: Node) -> bool {
	t := cstring_to_string(node_type(n))
	return t == "pair" || t == "member" || t == "block_mapping_pair" || t == "flow_pair"
}

structure_is_wrapper :: proc(n: Node) -> bool {
	t := cstring_to_string(node_type(n))
	return t == "block_node" || t == "flow_node"
}

structure_is_alias :: proc(n: Node) -> bool {
	return cstring_to_string(node_type(n)) == "alias"
}

// structure_root_value descends through root carriers (json `document`,
// json5 `file`, yaml `stream`/`document`) to the value they hold. A
// multi-document yaml stream stays put: the outline renders `doc[i]`
// entries and the resolver indexes it like an array.
structure_root_value :: proc(root: Node, source: string) -> Node {
	n := root
	for iter := 0; iter < 8; iter += 1 {
		t := cstring_to_string(node_type(n))
		if t == "stream" {
			if node_named_child_count(n) == 1 {
				n = node_named_child(n, 0)
				continue
			}
			return n
		}
		if t == "document" || t == "file" {
			next := structure_first_meaningful_child(n, source)
			if node_is_null(next) {
				return n
			}
			n = next
			continue
		}
		return n
	}
	return n
}

structure_first_meaningful_child :: proc(n: Node, source: string) -> Node {
	count := node_named_child_count(n)
	for i := u32(0); i < count; i += 1 {
		c := node_named_child(n, i)
		t := cstring_to_string(node_type(c))
		if t == "comment" {
			continue
		}
		if structure_is_wrapper(c) {
			v, _ := structure_unwrap(c, source)
			if !node_is_null(v) {
				return v
			}
		}
		return c
	}
	return {}
}

// structure_unwrap descends a yaml value wrapper (`block_node`/`flow_node`)
// to its content node, collecting the anchor name on the way. Non-wrappers
// return unchanged.
structure_unwrap :: proc(n: Node, source: string) -> (value: Node, anchor: string) {
	cur := n
	anchor = ""
	for iter := 0; iter < 8; iter += 1 {
		if !structure_is_wrapper(cur) {
			return cur, anchor
		}
		count := node_named_child_count(cur)
		moved := false
		for i := u32(0); i < count; i += 1 {
			c := node_named_child(cur, i)
			t := cstring_to_string(node_type(c))
			if t == "anchor" {
				anchor = structure_anchor_name(c, source)
				continue
			}
			cur = c
			moved = true
			break
		}
		if !moved {
			return cur, anchor
		}
	}
	return cur, anchor
}

structure_anchor_name :: proc(anchor: Node, source: string) -> string {
	count := node_named_child_count(anchor)
	for i := u32(0); i < count; i += 1 {
		c := node_named_child(anchor, i)
		if cstring_to_string(node_type(c)) == "anchor_name" {
			return strings.trim_space(node_text(c, source))
		}
	}
	return ""
}

Structure_Pair :: struct {
	key:     string,
	key_row: int,
	value:   Node,
	anchor:  string,
}

// structure_pairs collects the (key, unwrapped value) entries of an
// object-like node, skipping comments. Keys are clone-owned by `a`.
structure_pairs :: proc(n: Node, source: string, a := context.allocator) -> []Structure_Pair {
	out := make([dynamic]Structure_Pair, 0, 8, a)
	count := node_named_child_count(n)
	for i := u32(0); i < count; i += 1 {
		c := node_named_child(n, i)
		if !structure_is_pair(c) {
			continue
		}
		// Pair children: [key, value]; yaml keys and values sit in wrappers.
		key_node := node_named_child(c, 0)
		if node_is_null(key_node) {
			continue
		}
		key_node, _ = structure_unwrap(key_node, source)
		key := structure_key_text(key_node, source, a)
		value_node := node_named_child(c, 1)
		value, anchor := Node{}, ""
		if !node_is_null(value_node) {
			value, anchor = structure_unwrap(value_node, source)
		}
		append(&out, Structure_Pair{
			key = key,
			key_row = int(node_start_point(key_node).row),
			value = value,
			anchor = anchor,
		})
	}
	return out[:]
}

// structure_key_text renders a key node's source with one surrounding
// quote pair stripped (json/json5 quoted keys, yaml quoted scalars).
structure_key_text :: proc(key: Node, source: string, a := context.allocator) -> string {
	text := strings.trim_space(node_text(key, source))
	if len(text) >= 2 {
		first := text[0]
		last := text[len(text) - 1]
		if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
			text = text[1 : len(text) - 1]
		}
	}
	return strings.clone(text, a)
}

// structure_items collects a sequence's entries: array values, yaml
// block_sequence_item / wrapper children (unwrapped), or a stream's
// documents.
structure_items :: proc(n: Node, source: string, a := context.allocator) -> []Node {
	out := make([dynamic]Node, 0, 8, a)
	count := node_named_child_count(n)
	for i := u32(0); i < count; i += 1 {
		c := node_named_child(n, i)
		t := cstring_to_string(node_type(c))
		if t == "comment" {
			continue
		}
		if t == "block_sequence_item" {
			// The item's content sits in a block_node/flow_node child.
			inner := structure_first_meaningful_child(c, source)
			if !node_is_null(inner) {
				c = inner
			}
		} else if t == "document" || t == "file" {
			// A stream's items are documents; index into their content.
			inner := structure_first_meaningful_child(c, source)
			if !node_is_null(inner) {
				c = inner
			}
		} else if structure_is_wrapper(c) {
			v, _ := structure_unwrap(c, source)
			if !node_is_null(v) {
				c = v
			}
		}
		append(&out, c)
	}
	return out[:]
}

// structure_span_lines maps a node's point span to whole 0-based lines. A
// node ending at column 0 of the next line owns up to the line before.
structure_span_lines :: proc(n: Node) -> (start: int, end: int) {
	sp := node_start_point(n)
	ep := node_end_point(n)
	start = int(sp.row)
	end = int(ep.row)
	if end > start && ep.col == 0 {
		end -= 1
	}
	if end < start {
		end = start
	}
	return
}

// ---------------------------------------------------------------------------
// Outline rendering
// ---------------------------------------------------------------------------

Structure_State :: struct {
	b:         ^strings.Builder,
	opts:      Structure_Options,
	used:      int,
	truncated: bool,
	allocator: runtime.Allocator,
}

structure_state_init :: proc(b: ^strings.Builder, opts: Structure_Options, a := context.allocator) -> (st: Structure_State) {
	st = {b = b, opts = opts, allocator = a}
	if st.opts.preview_runes <= 0 {
		st.opts.preview_runes = STRUCTURE_PREVIEW_RUNES
	}
	if st.opts.max_array_items <= 0 {
		st.opts.max_array_items = STRUCTURE_MAX_ARRAY_ITEMS
	}
	return
}

// structure_write_line appends one rendered line (newline included) under
// the byte budget; an over-budget line is dropped whole and marks the
// answer truncated.
structure_write_line :: proc(st: ^Structure_State, indent: int, text: string) {
	line_len := 2 * indent + len(text) + 1
	if st.opts.max_chars > 0 && st.used + line_len > st.opts.max_chars {
		st.truncated = true
		return
	}
	for _ in 0..<indent {
		strings.write_string(st.b, "  ")
	}
	strings.write_string(st.b, text)
	strings.write_byte(st.b, '\n')
	st.used += line_len
}

structure_span_label :: proc(n: Node, a := context.allocator) -> string {
	start, end := structure_span_lines(n)
	if start == end {
		return fmt.aprintf("(L%d)", start, allocator = a)
	}
	return fmt.aprintf("(L%d-L%d)", start, end, allocator = a)
}

structure_render_root :: proc(st: ^Structure_State, root: Node, source: string) {
	if cstring_to_string(node_type(root)) == "stream" && node_named_child_count(root) > 1 {
		// Multi-document stream: one doc[i] entry per document.
		count := node_named_child_count(root)
		for i := u32(0); i < count; i += 1 {
			doc := node_named_child(root, i)
			value := structure_first_meaningful_child(doc, source)
			if node_is_null(value) {
				value = doc
			}
			text := strings.concatenate({
				fmt.aprintf("doc[%d]: ", i, allocator = st.allocator),
				structure_head(value, source, st),
				" ", structure_span_label(value, st.allocator),
			}, st.allocator)
			structure_write_line(st, 0, text)
			structure_render_value(st, value, source, 1)
		}
		return
	}
	node := structure_root_value(root, source)
	text := strings.concatenate({
		structure_head(node, source, st),
		" ", structure_span_label(node, st.allocator),
	}, st.allocator)
	structure_write_line(st, 0, text)
	structure_render_value(st, node, source, 1)
}

// structure_head renders the inline shape marker for a value: `{}` for
// objects, `[N]` with the item count for arrays, the clamped preview
// otherwise.
structure_head :: proc(n: Node, source: string, st: ^Structure_State) -> string {
	if structure_is_object(n) {
		return "{}"
	}
	if structure_is_array(n) {
		return fmt.aprintf("[%d]", len(structure_items(n, source, st.allocator)), allocator = st.allocator)
	}
	preview := structure_preview(n, source, st.opts.preview_runes, st.allocator)
	if structure_is_alias(n) {
		return strings.concatenate({preview, " (alias)"}, st.allocator)
	}
	return preview
}

structure_render_value :: proc(st: ^Structure_State, n: Node, source: string, depth: int) {
	if depth >= STRUCTURE_MAX_DEPTH {
		structure_write_line(st, depth, "… (max depth)")
		return
	}
	if structure_is_object(n) {
		for pair in structure_pairs(n, source, st.allocator) {
			structure_render_entry(st, pair.key, pair.value, pair.anchor, source, depth)
		}
		return
	}
	if structure_is_array(n) {
		items := structure_items(n, source, st.allocator)
		for item, i in items {
			if i >= st.opts.max_array_items {
				structure_write_line(st, depth, fmt.aprintf("… +%d more", len(items) - i, allocator = st.allocator))
				return
			}
			structure_render_entry(st, fmt.aprintf("[%d]", i, allocator = st.allocator), item, "", source, depth)
		}
		return
	}
}

// structure_render_entry writes one labeled child (object pair or array
// item) and recurses into containers.
structure_render_entry :: proc(st: ^Structure_State, label: string, value: Node, anchor: string, source: string, depth: int) {
	text := strings.concatenate({
		label, ": ", structure_head(value, source, st),
		" ", structure_span_label(value, st.allocator),
	}, st.allocator)
	if anchor != "" {
		text = strings.concatenate({text, " &", anchor}, st.allocator)
	}
	structure_write_line(st, depth, text)
	structure_render_value(st, value, source, depth + 1)
}

// structure_preview clamps a scalar's source text to whole runes, folds
// newlines to ⏎, and trims surrounding whitespace.
structure_preview :: proc(n: Node, source: string, runes: int, a := context.allocator) -> string {
	text := strings.trim_space(node_text(n, source))
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

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

Structure_Segment_Kind :: enum {
	Field,
	Index,
}

Structure_Segment :: struct {
	kind:  Structure_Segment_Kind,
	field: string, // Field
	index: int, // Index (negative = from the end, jq-style)
	label: string, // rendering in error prefixes
}

structure_parse_path :: proc(path: string, a := context.allocator) -> (segs: []Structure_Segment, want_keys: bool, iterate_last: bool, err: string) {
	p := strings.trim_space(path)
	want_keys = false
	iterate_last = false
	if bar := structure_last_operator_bar(p); bar >= 0 {
		tail := strings.trim_space(p[bar + 1:])
		if tail == "keys" {
			want_keys = true
			p = strings.trim_space(p[:bar])
		} else if tail == "" {
			return nil, false, false, "invalid path: dangling '|'"
		} else {
			return nil, false, false, strings.concatenate({
				"invalid path: unsupported operator | ", tail,
			}, a)
		}
	}
	out := make([dynamic]Structure_Segment, 0, 4, a)
	i := 0
	if i < len(p) && p[i] == '.' {
		i += 1
	}
	if i >= len(p) {
		return out[:], want_keys, iterate_last, ""
	}
	for i < len(p) {
		if p[i] == '[' {
			close := structure_bracket_close(p, i)
			if close < 0 {
				return nil, false, false, "invalid path: unterminated '['"
			}
			inner := strings.trim_space(p[i + 1 : close])
			if inner == "" {
				if want_keys {
					return nil, false, false, "invalid path: [] cannot combine with | keys"
				}
				iterate_last = true
			} else if inner[0] == '"' {
				// jq's string subscript: ["key"]. The quoted span must be
				// the whole subscript — trailing text after the closing
				// quote is malformed, not a key.
				field, next, ok := structure_unquote(inner, 0, a)
				if !ok || next != len(inner) {
					return nil, false, false, strings.concatenate({
						"invalid path: bad subscript [", inner, "]",
					}, a)
				}
				append(&out, Structure_Segment{
					kind = .Field,
					field = field,
					label = fmt.aprintf("[%s]", inner, allocator = a),
				})
			} else {
				idx, ok := parse_index(inner)
				if !ok {
					return nil, false, false, strings.concatenate({
						"invalid path: bad index [", inner,
						"]; string keys need quotes: [\"", inner, "\"]",
					}, a)
				}
				append(&out, Structure_Segment{
					kind = .Index,
					index = idx,
					label = fmt.aprintf("[%s]", inner, allocator = a),
				})
			}
			i = close + 1
			if iterate_last && i < len(p) {
				return nil, false, false, "invalid path: [] must be the last segment"
			}
		} else {
			field, ni, ferr := structure_scan_field(p, i, a)
			if ferr != "" {
				return nil, false, false, ferr
			}
			append(&out, Structure_Segment{
				kind = .Field,
				field = field,
				label = fmt.aprintf(".%s", field, allocator = a),
			})
			i = ni
		}
		if i >= len(p) {
			break
		}
		if p[i] == '.' {
			i += 1
			if i >= len(p) {
				return nil, false, false, "invalid path: trailing '.'"
			}
			continue
		}
		if p[i] != '[' {
			return nil, false, false, strings.concatenate({
				"invalid path: unexpected '", p[i : i + 1], "'",
			}, a)
		}
	}
	return out[:], want_keys, iterate_last, ""
}

// structure_last_operator_bar finds the last '|' outside quoted field
// spans — a bar inside `."a|b"` is field text, not the keys operator.
// -1 when no operator bar exists.
structure_last_operator_bar :: proc(p: string) -> int {
	bar := -1
	in_quote := false
	escaped := false
	for i := 0; i < len(p); i += 1 {
		c := p[i]
		if escaped {
			escaped = false
		} else if in_quote && c == '\\' {
			escaped = true
		} else if c == '"' {
			in_quote = !in_quote
		} else if !in_quote && c == '|' {
			bar = i
		}
	}
	return bar
}

// structure_bracket_close finds the ']' closing the subscript opened at
// p[start] == '[', skipping double-quoted spans — a ']' inside a quoted
// key is key text, not the subscript's end. -1 when unterminated.
structure_bracket_close :: proc(p: string, start: int) -> int {
	in_quote := false
	escaped := false
	for j := start + 1; j < len(p); j += 1 {
		c := p[j]
		if escaped {
			escaped = false
		} else if in_quote && c == '\\' {
			escaped = true
		} else if c == '"' {
			in_quote = !in_quote
		} else if !in_quote && c == ']' {
			return j
		}
	}
	return -1
}

// structure_scan_field reads one field name: a bare run up to the next
// '.' or '[', or a double-quoted string with \" and \\ escapes.
structure_scan_field :: proc(p: string, i: int, a := context.allocator) -> (field: string, next: int, err: string) {
	if i < len(p) && p[i] == '"' {
		text, end, ok := structure_unquote(p, i, a)
		if !ok {
			return "", 0, "invalid path: unterminated quoted field"
		}
		return text, end, ""
	}
	j := i
	for j < len(p) && p[j] != '.' && p[j] != '[' {
		j += 1
	}
	if j == i {
		return "", 0, "invalid path: expected a field name or index"
	}
	return p[i:j], j, ""
}

// structure_unquote decodes one double-quoted span starting at p[i] (the
// opening '"'), passing the byte after a backslash through verbatim (the
// \" and \\ escapes; anything else stays literal). It returns the decoded
// text and the offset just past the closing quote. One decoder serves
// both the ."key" and ["key"] subscript forms. ok=false when the span
// never closes.
structure_unquote :: proc(p: string, i: int, a := context.allocator) -> (text: string, next: int, ok: bool) {
	b := strings.builder_make_len_cap(0, 8, a)
	defer strings.builder_destroy(&b)
	j := i + 1
	for j < len(p) {
		switch p[j] {
		case '\\':
			if j + 1 < len(p) {
				strings.write_byte(&b, p[j + 1])
			}
			j += 2
		case '"':
			return strings.clone(strings.to_string(b), a), j + 1, true
		case:
			strings.write_byte(&b, p[j])
			j += 1
		}
	}
	return "", 0, false
}

parse_index :: proc(s: string) -> (int, bool) {
	if s == "" {
		return 0, false
	}
	v := 0
	neg := false
	i := 0
	if s[0] == '-' {
		neg = true
		i = 1
	}
	if i >= len(s) {
		return 0, false
	}
	for c in s[i:] {
		if c < '0' || c > '9' {
			return 0, false
		}
		d := int(c - '0')
		// Overflow guard: a wrapped accumulation would silently resolve a
		// real array item (the bounds check cannot tell 2^64+1 from 1), so
		// digit runs that cannot fit the integer are rejected as paths.
		if v > (9223372036854775807 - d) / 10 {
			return 0, false
		}
		v = v * 10 + d
	}
	if neg {
		v = -v
	}
	return v, true
}

// structure_step advances one segment; the boolean reports success only —
// the error text is shaped by structure_step_error, which needs the node
// the step failed at.
structure_step :: proc(node: Node, source: string, seg: Structure_Segment, a := context.allocator) -> (next: Node, ok: bool) {
	switch seg.kind {
	case .Field:
		if !structure_is_object(node) {
			return {}, false
		}
		for pair in structure_pairs(node, source, a) {
			if pair.key == seg.field {
				return pair.value, true
			}
		}
		return {}, false
	case .Index:
		if !structure_is_seq(node) {
			return {}, false
		}
		items := structure_items(node, source, a)
		idx := seg.index
		if idx < 0 {
			idx += len(items)
		}
		if idx < 0 || idx >= len(items) {
			return {}, false
		}
		return items[idx], true
	}
	return {}, false
}

structure_step_error :: proc(node: Node, source: string, seg: Structure_Segment, prefix: string, a := context.allocator) -> string {
	at := "the root"
	if prefix != "" {
		at = strings.concatenate({"path ", prefix}, a)
	}
	switch seg.kind {
	case .Field:
		if structure_is_seq(node) {
			return strings.concatenate({
				at, " is an array; use [index] or [] instead of a field name",
			}, a)
		}
		if !structure_is_object(node) {
			return strings.concatenate({
				at, " is a scalar; the path cannot descend into it",
			}, a)
		}
		pairs := structure_pairs(node, source, a)
		avail := make([dynamic]string, 0, len(pairs), a)
		for pair in pairs {
			if len(avail) >= STRUCTURE_MAX_KEYS_LISTED {
				append(&avail, fmt.aprintf("… (+%d more)", len(pairs) - len(avail), allocator = a))
				break
			}
			append(&avail, pair.key)
		}
		joined, _ := strings.join(avail[:], ", ", a)
		return strings.concatenate({
			"unknown field \"", seg.field, "\" at ", at,
			"; available: ", joined,
		}, a)
	case .Index:
		if structure_is_object(node) {
			return strings.concatenate({
				at, " is an object; use a field name instead of [index]",
			}, a)
		}
		if !structure_is_seq(node) {
			return strings.concatenate({
				at, " is a scalar; the path cannot descend into it",
			}, a)
		}
		return strings.concatenate({
			"index ", fmt.aprintf("%d", seg.index, allocator = a),
			" out of range at ", at,
			" (", fmt.aprintf("%d", len(structure_items(node, source, a)), allocator = a), " items)",
		}, a)
	}
	return "unreachable segment kind"
}

structure_render_keys :: proc(node: Node, source: string, max_chars: int, a := context.allocator) -> Structure_Path_Result {
	start, end := structure_span_lines(node)
	b := strings.builder_make_len_cap(0, 128, a)
	defer strings.builder_destroy(&b)
	used := 0
	truncated := false
	for pair in structure_pairs(node, source, a) {
		line := fmt.aprintf("%s (L%d)\n", pair.key, pair.key_row, allocator = a)
		if max_chars > 0 && used + len(line) > max_chars {
			truncated = true
			break
		}
		strings.write_string(&b, line)
		used += len(line)
	}
	return {
		kind = .Keys,
		content = strings.clone(strings.to_string(b), a),
		start_line = start,
		end_line = end,
		truncated = truncated,
	}
}

structure_render_items :: proc(node: Node, source: string, max_chars: int, a := context.allocator) -> Structure_Path_Result {
	start, end := structure_span_lines(node)
	items := structure_items(node, source, a)
	b := strings.builder_make_len_cap(0, 128, a)
	defer strings.builder_destroy(&b)
	used := 0
	truncated := false
	for item, i in items {
		is_, ie := structure_span_lines(item)
		head := fmt.aprintf("[%d] (L%d-L%d):\n", i, is_, ie, allocator = a)
		if max_chars > 0 && used + len(head) > max_chars {
			truncated = true
			break
		}
		strings.write_string(&b, head)
		used += len(head)
		for line in strings.split(node_text(item, source), "\n", a) {
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
	}
	return {
		kind = .Iterated,
		content = strings.clone(strings.to_string(b), a),
		start_line = start,
		end_line = end,
		truncated = truncated,
	}
}

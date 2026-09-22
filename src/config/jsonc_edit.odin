// Format-preserving JSONC editor for client config files (zcode config.json,
// opencode opencode.json): targeted member insertion that keeps every byte
// outside the splice untouched — comments, key order, and spacing survive.
// The scanner mirrors strip_jsonc's string/comment state machine but works
// on raw offsets (strip_jsonc output positions do not map back to the input:
// a block comment collapses to a single space), so edits splice into the
// original text. Writers must not leave trailing commas behind: these files
// are plain JSON for the clients that read them.
package config

import "core:mem"
import "core:strings"

import "src:jsonutil"

Value_Kind :: enum {
	Object,
	Array,
	String,
	Other,
}

Member_Info :: struct {
	name:        string,    // decoded key
	name_start:  int,       // raw offset of the key's opening quote
	value_start: int,       // raw offset of the value's first byte
	value_end:   int,       // raw offset just past the value's last byte
	kind:        Value_Kind,
}

Obj_Info :: struct {
	open:    int, // offset of '{'
	close:   int, // offset of the matching '}'
	members: [dynamic]Member_Info,
}

// skip_blank advances i past whitespace and //... and /*...*/ comments.
skip_blank :: proc(data: []u8, i: int) -> int {
	p := i
	for p < len(data) {
		c := data[p]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			p += 1
		} else if c == '/' && p + 1 < len(data) && data[p + 1] == '/' {
			p += 2
			for p < len(data) && data[p] != '\n' {
				p += 1
			}
		} else if c == '/' && p + 1 < len(data) && data[p + 1] == '*' {
			p += 2
			for p + 1 < len(data) && !(data[p] == '*' && data[p + 1] == '/') {
				p += 1
			}
			p += 2
			if p > len(data) {
				p = len(data)
			}
		} else {
			break
		}
	}
	return p
}

// skip_string expects data[i] == '"' and returns the offset just past the
// closing quote (escape-aware).
skip_string :: proc(data: []u8, i: int) -> int {
	p := i + 1
	for p < len(data) {
		switch data[p] {
		case '\\':
			p += 2
		case '"':
			return p + 1
		case:
			p += 1
		}
	}
	return len(data)
}

// match_bracket expects data[i] == '{' or '[' and returns the offset of the
// matching closing bracket, skipping strings and comments on the way.
match_bracket :: proc(data: []u8, i: int) -> (int, bool) {
	close_byte: u8
	switch data[i] {
	case '{':
		close_byte = '}'
	case '[':
		close_byte = ']'
	case:
		return len(data), false
	}
	depth := 0
	j := i
	for j < len(data) {
		c := data[j]
		if c == '"' {
			j = skip_string(data, j)
			continue
		}
		if c == '/' && j + 1 < len(data) && (data[j + 1] == '/' || data[j + 1] == '*') {
			j = skip_blank(data, j)
			continue
		}
		if c == data[i] {
			depth += 1
		} else if c == close_byte {
			depth -= 1
			if depth == 0 {
				return j, true
			}
		}
		j += 1
	}
	return len(data), false
}

// scan_value returns the exclusive end offset and kind of the value starting
// at data[i].
scan_value :: proc(data: []u8, i: int) -> (end: int, kind: Value_Kind, ok: bool) {
	if i >= len(data) {
		return i, .Other, false
	}
	switch data[i] {
	case '{':
		// match_bracket returns the closing bracket's own offset; the value
		// end is exclusive (one past it).
		end, ok = match_bracket(data, i)
		return end + 1, .Object, ok
	case '[':
		end, ok = match_bracket(data, i)
		return end + 1, .Array, ok
	case '"':
		return skip_string(data, i), .String, true
	case:
		// number / true / false / null: runs to the next separator
		j := i
		for j < len(data) {
			c := data[j]
			if c == ',' || c == '}' || c == ']' || c == ' ' || c == '\t' ||
				c == '\n' || c == '\r' || c == '/' {
				break
			}
			j += 1
		}
		return j, .Other, j > i
	}
}

// object_info walks the object whose '{' sits at data[open_off] and records
// each member's decoded key and value extent. ok == false means the body is
// malformed; members seen before the fault are still recorded.
object_info :: proc(data: []u8, open_off: int, a := context.allocator) -> (info: Obj_Info, ok: bool) {
	if open_off < 0 || open_off >= len(data) || data[open_off] != '{' {
		return info, false
	}
	close_off, matched := match_bracket(data, open_off)
	if !matched {
		return info, false
	}
	info = {open = open_off, close = close_off}
	info.members = make([dynamic]Member_Info, 0, 8, a)

	i := skip_blank(data, open_off + 1)
	for i < close_off {
		if data[i] == ',' {
			i = skip_blank(data, i + 1)
			continue
		}
		if data[i] != '"' {
			return info, false
		}
		key_start := i
		key_end := skip_string(data, i)
		raw_key := string(data[i:key_end])
		i = skip_blank(data, key_end)
		if i >= len(data) || data[i] != ':' {
			return info, false
		}
		i = skip_blank(data, i + 1)
		value_end, kind, vok := scan_value(data, i)
		if !vok {
			return info, false
		}
		append(&info.members, Member_Info{
			name        = decode_key(raw_key, a),
			name_start  = key_start,
			value_start = i,
			value_end   = value_end,
			kind        = kind,
		})
		i = skip_blank(data, value_end)
	}
	return info, true
}

// decode_key unquotes a raw JSON string token. Only backslash escapes are
// handled (enough for config keys); anything exotic keeps its bytes — keys
// are compared after the same decoding on both sides, so lookups stay
// consistent.
decode_key :: proc(raw: string, a := context.allocator) -> string {
	if len(raw) < 2 || raw[0] != '"' {
		return strings.clone(raw, a)
	}
	body := raw[1:len(raw) - 1]
	if !strings.contains(body, "\\") {
		return strings.clone(body, a)
	}
	out := make([dynamic]u8, 0, len(body), a)
	i := 0
	for i < len(body) {
		if body[i] == '\\' && i + 1 < len(body) {
			i += 1
		}
		append(&out, body[i])
		i += 1
	}
	return string(out[:])
}

// find_member returns the index of the named member, or -1.
find_member :: proc(info: ^Obj_Info, name: string) -> int {
	for m, i in info.members {
		if m.name == name {
			return i
		}
	}
	return -1
}

// detect_newline returns the file's dominant line separator: inserts
// adopt it so an aubade-driven edit never mixes endings in a CRLF file
// (Windows editors). CRLF wins only on a strict majority.
detect_newline :: proc(data: []u8) -> string {
	crlf := 0
	lf := 0
	for i := 0; i < len(data); i += 1 {
		if data[i] == '\n' {
			if i > 0 && data[i - 1] == '\r' {
				crlf += 1
			} else {
				lf += 1
			}
		}
	}
	if crlf > lf {
		return "\r\n"
	}
	return "\n"
}

// detect_indent returns the file's indentation unit: the whitespace run
// after the first newline that introduces a member line. Falls back to four
// spaces (what the fresh-file writer emits). The result borrows `data`.
detect_indent :: proc(data: []u8) -> string {
	i := 0
	for i < len(data) {
		if data[i] != '\n' {
			i += 1
			continue
		}
		j := i + 1
		for j < len(data) && (data[j] == ' ' || data[j] == '\t') {
			j += 1
		}
		if j > i + 1 && j < len(data) && data[j] == '"' {
			return string(data[i + 1:j])
		}
		next := i + 1
		if j > next {
			next = j
		}
		i = next
	}
	return "    "
}

// line_indent returns the whitespace prefix of pos's line when the line
// holds nothing but whitespace before pos (the value starts its own line),
// and "" otherwise. Borrows `data`.
line_indent :: proc(data: []u8, pos: int) -> string {
	start := pos
	for start > 0 && data[start - 1] != '\n' {
		start -= 1
	}
	j := start
	for j < pos && (data[j] == ' ' || data[j] == '\t') {
		j += 1
	}
	if j != pos {
		return ""
	}
	return string(data[start:pos])
}

// indent_repeat builds `depth` copies of the unit.
indent_repeat :: proc(unit: string, depth: int, a := context.allocator) -> string {
	if depth <= 0 || len(unit) == 0 {
		return ""
	}
	buf := make([]u8, len(unit) * depth, a)
	for i in 0..<len(buf) {
		buf[i] = unit[i % len(unit)]
	}
	return string(buf)
}

contains_newline :: proc(bs: []u8) -> bool {
	for c in bs {
		if c == '\n' {
			return true
		}
	}
	return false
}

// splice returns data[:at] ++ mid ++ data[at:], allocated from `a`.
splice :: proc(data: []u8, at: int, mid: string, a := context.allocator) -> []u8 {
	out := make([]u8, len(data) + len(mid), a)
	copy_bytes(out[:at], data[:at])
	mid_bytes := transmute([]u8)mid
	copy_bytes(out[at:at + len(mid)], mid_bytes)
	copy_bytes(out[at + len(mid):], data[at:])
	return out
}

// splice_span returns data[:start] ++ mid ++ data[end:], allocated from
// `a` (the span replacement counterpart of splice).
splice_span :: proc(data: []u8, start: int, end: int, mid: string, a := context.allocator) -> []u8 {
	out := make([]u8, len(data) - (end - start) + len(mid), a)
	copy_bytes(out[:start], data[:start])
	mid_bytes := transmute([]u8)mid
	copy_bytes(out[start:start + len(mid)], mid_bytes)
	copy_bytes(out[start + len(mid):], data[end:])
	return out
}

// copy_bytes copies src into dst (len(dst) >= len(src) by construction);
// mem.copy is rawptr-based, which does not fit sliced byte ranges.
copy_bytes :: proc(dst, src: []u8) {
	for i in 0..<len(src) {
		dst[i] = src[i]
	}
}

// insert_member splices `"name": value_text` into the object as its last
// member, reusing the file's own newlines and separators so the closing
// brace keeps its line: pretty-printed objects gain one clean member line,
// compact ones get a formatted block. The comma logic never produces a
// trailing comma. Spliced separators adopt the file's dominant newline
// (detect_newline), so a CRLF file stays CRLF throughout.
insert_member :: proc(
	data: []u8,
	info: ^Obj_Info,
	name:                string,
	value_text:          string,
	member_indent:       string,
	close_indent:        string,
	a:                   mem.Allocator,
) -> []u8 {
	quoted := json_quote(name, context.temp_allocator)
	nl := detect_newline(data)
	if len(info.members) == 0 {
		body_start := info.open + 1
		if contains_newline(data[body_start:info.close]) {
			return splice(
				data, body_start,
				strings.concatenate({nl, member_indent, quoted, ": ", value_text}, context.temp_allocator),
				a,
			)
		}
		return splice(
			data, info.close,
			strings.concatenate({nl, member_indent, quoted, ": ", value_text, nl, close_indent}, context.temp_allocator),
			a,
		)
	}

	last := info.members[len(info.members) - 1]
	j := skip_blank(data, last.value_end)
	if j < info.close && data[j] == ',' {
		// An explicit separator already exists: attach the member right
		// after it and let the pre-existing newline close the object.
		return splice(
			data, j + 1,
			strings.concatenate({nl, member_indent, quoted, ": ", value_text}, context.temp_allocator),
			a,
		)
	}
	if contains_newline(data[last.value_end:info.close]) {
		return splice(
			data, last.value_end,
			strings.concatenate({",", nl, member_indent, quoted, ": ", value_text}, context.temp_allocator),
			a,
		)
	}
	return splice(
		data, last.value_end,
		strings.concatenate({",", nl, member_indent, quoted, ": ", value_text, nl, close_indent}, context.temp_allocator),
		a,
	)
}

// edit_ensure_object descends `path` from the root object, creating missing
// objects as empty `{}` members with detected indentation. Returns the
// updated text plus the offset of the final object's '{' (valid until the
// next edit). ok == false: the root is not an object, the text is malformed,
// or a path element exists as a non-object.
edit_ensure_object :: proc(
	data: []u8,
	path:     []string,
	a:        mem.Allocator,
) -> (out: []u8, obj_off: int, changed: bool, ok: bool) {
	work := data
	cur := skip_blank(work, 0)
	if cur >= len(work) || work[cur] != '{' {
		return work, -1, false, false
	}
	unit := detect_indent(work)
	did_change := false
	for key, depth in path {
		info, iok := object_info(work, cur, context.temp_allocator)
		if !iok {
			return work, -1, did_change, false
		}
		m := find_member(&info, key)
		if m >= 0 {
			if info.members[m].kind != .Object {
				return work, -1, did_change, false
			}
			cur = info.members[m].value_start
			continue
		}
		mi := indent_repeat(unit, depth + 1, context.temp_allocator)
		ci := indent_repeat(unit, depth, context.temp_allocator)
		work = insert_member(work, &info, key, "{}", mi, ci, a)
		did_change = true
		info2, iok2 := object_info(work, cur, context.temp_allocator)
		if !iok2 {
			return work, -1, did_change, false
		}
		m2 := find_member(&info2, key)
		if m2 < 0 {
			return work, -1, did_change, false
		}
		cur = info2.members[m2].value_start
	}
	return work, cur, did_change, true
}

// Edit_Action tells setup callers which splice happened, so their
// messages can tell a first registration from a repair of a stale one.
Edit_Action :: enum {
	Unchanged, // an equal member is already present; the file stays as-is
	Inserted,  // the member was added
	Replaced,  // a same-named member existed with a different value
}

// edit_upsert_member inserts the member or, when a same-named member
// exists, replaces its value when the two differ semantically and leaves
// the file untouched when they are equal. Setup must be able to repair a
// stale registration (a renamed flag, a moved binary): presence alone
// must not pin an outdated entry in place. The comparison is semantic
// because the fresh-file writer and the splice writer format the same
// entry differently, and a byte comparison would rewrite every file on
// every run.
edit_upsert_member :: proc(
	data:       []u8,
	path:       []string,
	name:       string,
	value_text: string,
	a:          mem.Allocator,
) -> (out: []u8, action: Edit_Action, ok: bool) {
	cur_data, obj_off, _, eok := edit_ensure_object(data, path, a)
	if !eok {
		return cur_data, .Unchanged, false
	}
	info, iok := object_info(cur_data, obj_off, context.temp_allocator)
	if !iok {
		return cur_data, .Unchanged, false
	}
	idx := find_member(&info, name)
	if idx < 0 {
		unit := detect_indent(cur_data)
		mi := ""
		ci := line_indent(cur_data, info.close)
		if len(info.members) > 0 {
			mi = line_indent(cur_data, info.members[len(info.members) - 1].value_start)
		}
		if mi == "" {
			mi = indent_repeat(unit, len(path) + 1, context.temp_allocator)
		}
		if ci == "" {
			ci = indent_repeat(unit, len(path), context.temp_allocator)
		}
		out = insert_member(cur_data, &info, name, value_text, mi, ci, a)
		return out, .Inserted, true
	}
	m := info.members[idx]
	if member_values_equal(cur_data, m, value_text) {
		return cur_data, .Unchanged, true
	}
	key_end := skip_string(cur_data, m.name_start)
	mid := strings.concatenate({
		string(cur_data[m.name_start:key_end]),
		": ",
		value_text,
	}, context.temp_allocator)
	out = splice_span(cur_data, m.name_start, m.value_end, mid, a)
	return out, .Replaced, true
}

// edit_remove_member deletes one member — key, value, one adjoining
// comma, and the member's own annotation comments (a trailing line
// comment on the value's line, plus the comment-only lines directly above
// when the member's whole line collapses) — while preserving the rest of
// the formatting. Unlike the insert/upsert pair it never creates missing
// path objects: an absent path member or an absent name is a no-op
// (removed = false, ok = true), so a removal cannot mutate the file into
// existence. Pathological layouts (a comma parked after a line comment on
// the next line) can still leave invalid syntax behind — the caller
// validates the edited bytes before writing them out.
edit_remove_member :: proc(
	data: []u8,
	path: []string,
	name: string,
	a:          mem.Allocator,
) -> (out: []u8, removed: bool, ok: bool) {
	work := data
	cur := skip_blank(work, 0)
	if cur >= len(work) || work[cur] != '{' {
		return work, false, false
	}
	for key in path {
		info, iok := object_info(work, cur, context.temp_allocator)
		if !iok {
			return work, false, false
		}
		m := find_member(&info, key)
		if m < 0 {
			return work, false, true
		}
		if info.members[m].kind != .Object {
			return work, false, false
		}
		cur = info.members[m].value_start
	}
	info, iok := object_info(work, cur, context.temp_allocator)
	if !iok {
		return work, false, false
	}
	idx := find_member(&info, name)
	if idx < 0 {
		return work, false, true
	}
	m := info.members[idx]
	start := m.name_start
	end := m.value_end

	// One adjoining comma goes with the member: prefer the one after the
	// value (same line, horizontal whitespace between), else the one
	// before it (any whitespace between) — deleting the last member must
	// not leave a trailing comma behind.
	p := end
	for p < len(work) && (work[p] == ' ' || work[p] == '\t') {
		p += 1
	}
	if p < len(work) && work[p] == ',' {
		end = p + 1
	} else {
		q := start
		for q > 0 && is_jsonc_whitespace(work[q - 1]) {
			q -= 1
		}
		if q > 0 && work[q - 1] == ',' {
			start = q - 1
		}
	}

	// A line comment trailing the value on the same line belongs to the
	// member and goes with it.
	tc := end
	for tc < len(work) && (work[tc] == ' ' || work[tc] == '\t') {
		tc += 1
	}
	if tc + 1 < len(work) && work[tc] == '/' && work[tc + 1] == '/' {
		for tc < len(work) && work[tc] != '\n' {
			tc += 1
		}
		if tc < len(work) {
			tc += 1
		}
		end = tc
	}

	// Collapse the member's line when the span covers the whole of it.
	for start > 0 && (work[start - 1] == ' ' || work[start - 1] == '\t') {
		start -= 1
	}
	alone := start == 0 || work[start - 1] == '\n'
	if alone {
		e := end
		for e < len(work) && (work[e] == ' ' || work[e] == '\t') {
			e += 1
		}
		if e < len(work) && work[e] == '\n' {
			end = e + 1
		}
	}

	// When the member's whole line goes, the comment-only lines directly
	// above it (the scaffold annotates every key) go with it — a blank
	// line, another member, or the object's opening brace stops the walk.
	if alone {
		limit := info.open
		if idx > 0 {
			limit = info.members[idx - 1].value_end
		}
		for start - 1 > limit && work[start - 1] == '\n' {
			ps := start - 1
			for ps > limit && work[ps - 1] != '\n' {
				ps -= 1
			}
			j := ps
			for j < start - 1 && (work[j] == ' ' || work[j] == '\t') {
				j += 1
			}
			if !(j + 1 < start - 1 && work[j] == '/' && work[j + 1] == '/') {
				break
			}
			start = ps
		}
	}

	out = splice_span(work, start, end, "", a)
	return out, true, true
}

is_jsonc_whitespace :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// member_values_equal compares a member's raw value bytes with a rendered
// replacement as parsed JSON. A value that does not parse counts as
// different, forcing a rewrite.
member_values_equal :: proc(data: []u8, m: Member_Info, value_text: string) -> bool {
	existing, eerr := jsonc_parse(data[m.value_start:m.value_end], context.temp_allocator)
	if eerr != nil {
		return false
	}
	fresh, ferr := jsonc_parse(transmute([]u8)value_text, context.temp_allocator)
	if ferr != nil {
		return false
	}
	return jsonutil.values_equal(existing, fresh)
}

// render_inline_array renders `["a", "b"]` with each item quoted.
render_inline_array :: proc(items: []string, a := context.allocator) -> string {
	quoted := make([]string, len(items), context.temp_allocator)
	for s, i in items {
		quoted[i] = json_quote(s, context.temp_allocator)
	}
	joined := join_strings(quoted, ", ", context.temp_allocator)
	return strings.concatenate({"[", joined, "]"}, a)
}

// render_multiline_object renders:
//
//	{
//	<member_indent><fragments joined by ",<nl><member_indent>">
//	<close_indent>}
//
// Fragments are pre-rendered `"key": value` pieces; `nl` is the target
// file's line separator so the rendered block matches its convention.
render_multiline_object :: proc(
	fragments:     []string,
	member_indent: string,
	close_indent:  string,
	nl:            string,
	a:             mem.Allocator,
) -> string {
	sep := strings.concatenate({",", nl, member_indent}, context.temp_allocator)
	joined := join_strings(fragments, sep, context.temp_allocator)
	return strings.concatenate({
		"{", nl, member_indent, joined, nl, close_indent, "}",
	}, a)
}

// join_strings concatenates with a separator (strings.join returns an
// optional allocator error, which callers here never branch on).
join_strings :: proc(parts: []string, sep: string, a := context.allocator) -> string {
	if len(parts) == 0 {
		return ""
	}
	seps := len(parts) - 1
	if seps < 0 {
		seps = 0
	}
	total := len(sep) * seps
	for p in parts {
		total += len(p)
	}
	buf := make([dynamic]u8, 0, total, a)
	for p, i in parts {
		if i > 0 {
			append(&buf, sep)
		}
		append(&buf, p)
	}
	return string(buf[:])
}

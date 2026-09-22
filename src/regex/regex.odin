// Regex wrapper over vendored PCRE2 (8-bit + JIT), API-pinned to the
// reference textutils: compile variants with the same (?sm:...) flag
// wrapping and 4096-byte pattern cap, leftmost-first matching, capture
// groups, and $!N backreference expansion in the content replacer.
// Patterns operate byte-wise by default (no PCRE2_UTF): the ASCII regex
// subset — the only dialect the codebase feeds this wrapper — behaves
// identically to the RE2-lineage engine it replaces. compile_utf_regex is
// the explicit rune-semantics variant for character-meaning wildcards
// (pathspec). A compiled Regex belongs to the thread
// that uses it (PCRE2 compiled code is thread-safe to match concurrently,
// but the match_data is not); release with regex_destroy.
package regex

import "core:strings"
import "src:platform"
import "src:util"

Regex :: struct {
	code:       rawptr, // pcre2_code (freed in regex_destroy)
	match_data: rawptr, // per-pattern match data (freed in regex_destroy)
	mcontext:   rawptr, // match budget: match_limit + depth_limit (freed in regex_destroy)
	// Set when a match call returned one of the budget-exhaustion codes —
	// callers that report "no match" should surface this instead, so the
	// model can self-correct a pathological pattern. A Regex belongs to
	// one thread, so the flag needs no locking.
	limit_hit:  bool,
}

MAX_PATTERN_LEN :: 4096

// Match budget: bounded backtracking for model-authored patterns. The
// stock PCRE2 budget (10M) lets a catastrophic pattern run for minutes;
// 1M steps is far beyond any legitimate match in this codebase and still
// returns from the pathological shapes in milliseconds (JIT).
MATCH_LIMIT :: u32(1_000_000)
DEPTH_LIMIT :: u32(10_000)

compile_regex :: proc(pattern: string, a := context.allocator) -> (re: Regex, err: platform.Err) {
	return compile_wrapped(pattern, "", a)
}

// compile_multiline_regex wraps with (?sm) — dot-all + multiline — the mode
// replace_content needs.
compile_multiline_regex :: proc(pattern: string, a := context.allocator) -> (re: Regex, err: platform.Err) {
	return compile_wrapped(pattern, "sm", a)
}

// compile_dotall_regex wraps with (?s) only: ^ and $ keep whole-string
// semantics (the file_search mode).
compile_dotall_regex :: proc(pattern: string, a := context.allocator) -> (re: Regex, err: platform.Err) {
	return compile_wrapped(pattern, "s", a)
}

// compile_regex_with_flags wraps with caller-provided flag characters
// (inserted verbatim into the "(?FLAGS:" prefix — only valid flag letters
// should be provided).
compile_regex_with_flags :: proc(
	pattern: string,
	flags:   string,
	a := context.allocator,
) -> (re: Regex, err: platform.Err) {
	return compile_wrapped(pattern, flags, a)
}

// compile_utf_regex compiles in UTF mode (PCRE2_UTF plus
// MATCH_INVALID_UTF, so non-UTF-8 sequences in subjects simply fail to
// match instead of erroring): character classes, bracket ranges, and
// single-character wildcards operate on characters — what path globs mean
// by `?` and [...]. The ASCII dialect the other variants feed this
// wrapper stays byte-wise.
compile_utf_regex :: proc(pattern: string, a := context.allocator) -> (re: Regex, err: platform.Err) {
	return compile_wrapped_opts(pattern, "", PCRE2_COMPILE_UTF | PCRE2_COMPILE_MATCH_INVALID_UTF, a)
}

compile_wrapped :: proc(pattern: string, flags: string, a := context.allocator) -> (re: Regex, err: platform.Err) {
	return compile_wrapped_opts(pattern, flags, 0, a)
}

compile_wrapped_opts :: proc(pattern: string, flags: string, opts: u32, a := context.allocator) -> (re: Regex, err: platform.Err) {
	if len(pattern) > MAX_PATTERN_LEN {
		return {}, platform.Wrapped{
			kind = .Invalid,
			msg  = strings.concatenate({
				"regex pattern length ", util.int_to_dec(len(pattern), context.temp_allocator),
				" exceeds maximum of ", util.int_to_dec(MAX_PATTERN_LEN, context.temp_allocator),
			}, context.temp_allocator),
		}
	}
	wrapped := pattern
	if flags != "" {
		wrapped = strings.concatenate(
			{"(?", flags, ":", pattern, ")"}, context.temp_allocator,
		)
	}

	errorcode := i32(0)
	erroroffset := uint(0)
	code := pcre2_compile_8(
		str_ptr(wrapped),
		uint(len(wrapped)),
		opts,
		&errorcode,
		&erroroffset,
		nil,
	)
	if code == nil {
		return {}, platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate({
				"invalid regex: compile error ", util.int_to_dec(int(errorcode), context.temp_allocator),
				" at offset ", util.int_to_dec(int(erroroffset), context.temp_allocator),
			}, context.temp_allocator),
		}
	}
	// JIT is best-effort: a non-zero return just means this platform or
	// pattern does not accelerate (the interpreter still matches).
	_ = pcre2_jit_compile_8(code, PCRE2_JIT_COMPLETE)

	match_data := pcre2_match_data_create_from_pattern_8(code, nil)
	if match_data == nil {
		pcre2_code_free_8(code)
		return {}, platform.Wrapped{kind = .Internal, msg = "regex: cannot allocate match data"}
	}
	// The match budget bounds backtracking for pathological patterns —
	// see the MATCH_LIMIT comment; without it a short evil pattern can
	// hang the calling worker thread indefinitely.
	mcontext := pcre2_match_context_create_8(nil)
	if mcontext == nil {
		pcre2_match_data_free_8(match_data)
		pcre2_code_free_8(code)
		return {}, platform.Wrapped{kind = .Internal, msg = "regex: cannot allocate match context"}
	}
	_ = pcre2_set_match_limit_8(mcontext, MATCH_LIMIT)
	_ = pcre2_set_depth_limit_8(mcontext, DEPTH_LIMIT)
	return {code = code, match_data = match_data, mcontext = mcontext}, nil
}

regex_destroy :: proc(re: ^Regex) {
	if re.match_data != nil {
		pcre2_match_data_free_8(re.match_data)
		re.match_data = nil
	}
	if re.mcontext != nil {
		pcre2_match_context_free_8(re.mcontext)
		re.mcontext = nil
	}
	if re.code != nil {
		pcre2_code_free_8(re.code)
		re.code = nil
	}
}

// match_call runs one bounded pcre2 match — the mcontext carries the match
// budget — and records budget exhaustion on the Regex so callers can tell
// "no match" apart from "the pattern ran out of budget on this subject".
match_call :: proc(re: ^Regex, subject: string, start: int) -> i32 {
	rc := pcre2_match_8(
		re.code,
		str_ptr(subject),
		uint(len(subject)),
		uint(start),
		0,
		re.match_data,
		re.mcontext,
	)
	if rc == PCRE2_ERROR_MATCHLIMIT || rc == PCRE2_ERROR_DEPTHLIMIT || rc == PCRE2_ERROR_JIT_STACKLIMIT {
		re.limit_hit = true
	}
	return rc
}

// regex_match reports whether the pattern matches anywhere in subject.
regex_match :: proc(re: ^Regex, subject: string) -> bool {
	return regex_match_at(re, subject, 0)
}

// regex_match_at reports whether the pattern matches anywhere at or after
// `start` bytes into subject (the no-copy equivalent of matching a
// substring from start on).
regex_match_at :: proc(re: ^Regex, subject: string, start: int) -> bool {
	if re.code == nil {
		return false
	}
	if start < 0 || start > len(subject) {
		return false
	}
	return match_call(re, subject, start) >= 0
}

// regex_match_local is regex_match through a call-local match buffer: the
// Regex's own match_data may serve one thread at a time (PCRE2), so a
// Regex shared across threads — the outliner caches — must match through
// a buffer created and freed within the call. The compiled pattern and
// the immutable match context are safe to share; only the match data is
// not. Budget exhaustion is not recorded on the Regex here (limit_hit is
// shared mutable state — callers that need it own their Regex's thread).
regex_match_local :: proc(re: ^Regex, subject: string) -> bool {
	if re.code == nil {
		return false
	}
	md := pcre2_match_data_create_from_pattern_8(re.code, nil)
	if md == nil {
		return false
	}
	rc := pcre2_match_8(
		re.code,
		str_ptr(subject),
		uint(len(subject)),
		0,
		0,
		md,
		re.mcontext,
	)
	pcre2_match_data_free_8(md)
	return rc >= 0
}

// str_ptr hands PCRE2 a pointer into a string's bytes; empty strings pass
// nil (PCRE2 with length 0 does not read the pointer).
str_ptr :: proc(s: string) -> ^u8 {
	bytes := transmute([]u8)s
	if len(bytes) == 0 {
		return nil
	}
	return &bytes[0]
}

Match_Range :: struct {
	start: int,
	end:   int,
}

// regex_find_all returns every non-overlapping match range (leftmost
// first), advancing one byte past zero-length matches to guarantee
// termination. The result is allocated on `a` and owned by the caller
// (delete(result, a), or let the owning arena die).
regex_find_all :: proc(re: ^Regex, subject: string, a := context.allocator) -> []Match_Range {
	ranges: [dynamic]Match_Range = make([dynamic]Match_Range, 0, 8, a)
	pos := 0
	for pos <= len(subject) {
		start, end, ok := regex_match_range_at(re, subject, pos)
		if !ok {
			break
		}
		append(&ranges, Match_Range{start = start, end = end})
		if end == start {
			pos = end + 1
		} else {
			pos = end
		}
	}
	res := ranges[:]
	ranges = nil // the backing is now owned by the result on `a`
	return res
}

// regex_match_range_at finds the leftmost match at or after `start` and
// returns its extent.
regex_match_range_at :: proc(re: ^Regex, subject: string, start: int) -> (ms: int, me: int, ok: bool) {
	if re.code == nil || start < 0 || start > len(subject) {
		return 0, 0, false
	}
	rc := match_call(re, subject, start)
	if rc < 0 {
		return 0, 0, false
	}
	ovector := pcre2_get_ovector_pointer_8(re.match_data)
	if ovector == nil {
		return 0, 0, false
	}
	return int(ovector[0]), int(ovector[1]), true
}

// regex_captures_at returns the capture-group ranges for the leftmost match
// at or after `start` (index 0 is the whole match). Unset groups carry
// start = end = -1. The result is allocated on `a` and owned by the caller.
// This matches through the Regex's own match_data — use it for a regex
// owned by the calling thread or serialized behind a mutex (the redactor
// holds its mutex across the whole pass); a regex shared across threads
// goes through captures_at_md with a call-local buffer.
regex_captures_at :: proc(re: ^Regex, subject: string, start: int, a := context.allocator) -> []Match_Range {
	empty: [dynamic]Match_Range = make([dynamic]Match_Range, 0, 0, a)
	rc := match_call(re, subject, start)
	if rc < 0 {
		res := empty[:]
		empty = nil // the backing is now owned by the result on `a`
		return res
	}
	return ranges_from_md(re.match_data, rc, a)
}

// captures_at_md is the capture extraction against an explicit match
// buffer: a Regex shared across threads must match through a buffer
// created and freed within the call (the regex_match_local contract — the
// compiled pattern and the immutable match context are shareable, the
// match data is not). Budget exhaustion is not recorded on the Regex
// (limit_hit is shared mutable state; thread-owned callers use
// regex_captures_at).
captures_at_md :: proc(re: ^Regex, subject: string, start: int, md: rawptr, a := context.allocator) -> []Match_Range {
	if re.code == nil || start < 0 || start > len(subject) {
		return nil
	}
	rc := pcre2_match_8(
		re.code,
		str_ptr(subject),
		uint(len(subject)),
		uint(start),
		0,
		md,
		re.mcontext,
	)
	if rc < 0 {
		return nil
	}
	return ranges_from_md(md, rc, a)
}

// ranges_from_md reads the match buffer's ovector into owned Match_Ranges
// (index 0 = whole match; unset groups carry start = end = -1).
ranges_from_md :: proc(md: rawptr, rc: i32, a := context.allocator) -> []Match_Range {
	count := pcre2_get_ovector_count_8(md)
	n := rc
	if i32(count) < n {
		n = i32(count)
	}
	groups := int(n)
	out := make([dynamic]Match_Range, 0, groups, a)
	ovector := pcre2_get_ovector_pointer_8(md)
	for i in 0..<groups {
		s, e := ovector[i * 2], ovector[i * 2 + 1]
		if s == PCRE2_UNSET || e == PCRE2_UNSET {
			append(&out, Match_Range{start = -1, end = -1})
		} else {
			append(&out, Match_Range{start = int(s), end = int(e)})
		}
	}
	res := out[:]
	out = nil // the backing is now owned by the result on `a`
	return res
}

// quote_meta escapes the regex metacharacters in a literal. Byte-indexed:
// the default case copies non-ASCII bytes verbatim (rune iteration would
// truncate them to one byte). The result is allocated on `a` and owned by
// the caller (delete(result, a), or let the owning arena die).
quote_meta :: proc(literal: string, a := context.allocator) -> string {
	buf := make([dynamic]u8, 0, len(literal) + 8, a)
	for i in 0..<len(literal) {
		switch literal[i] {
		case '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '\\':
			append(&buf, '\\')
			append(&buf, literal[i])
		case:
			append(&buf, literal[i])
		}
	}
	res := string(buf[:])
	buf = nil // the bytes are now owned by the result on `a`
	return res
}

// --- content replacer --------------------------------------------------------

Replace_Mode :: enum {
	Literal,
	Regex,
}

// REPLACE_MODE_NAMES is the one spelling table for Replace_Mode: the
// schema enum hints, the svc-side validation, and the editor-side parse
// all derive from it.
REPLACE_MODE_NAMES :: []string{"literal", "regex"}

// replace_mode_from_string parses one mode spelling by traversing the
// names table (the from_string half of the single declaration).
replace_mode_from_string :: proc(s: string) -> (mode: Replace_Mode, ok: bool) {
	names := REPLACE_MODE_NAMES
	for m in Replace_Mode {
		if names[cast(int)m] == s {
			return m, true
		}
	}
	return .Literal, false
}

// replace_mode_string renders one mode spelling from the same table.
replace_mode_string :: proc(m: Replace_Mode) -> string {
	names := REPLACE_MODE_NAMES
	return names[cast(int)m]
}

Content_Replacer :: struct {
	mode:            Replace_Mode,
	allow_multiple:  bool,
}

content_replacer_init :: proc(cr: ^Content_Replacer, mode: Replace_Mode, allow_multiple: bool) {
	cr^ = {mode = mode, allow_multiple = allow_multiple}
}

// content_replace performs the replacement of needle by repl in content
// (multiline (?sm) matching, $!N backreferences from capture groups). The
// error strings surface verbatim in tool errors, so their wording is
// user-visible. The result is allocated on `a` and owned by the caller
// (delete(result, a),
// or let the owning arena die).
content_replace :: proc(
	cr:      ^Content_Replacer,
	content: string,
	needle:  string,
	repl:    string,
	a := context.allocator,
) -> (result: string, err: platform.Err) {
	regex_str := needle
	switch cr.mode {
	case .Literal:
		regex_str = quote_meta(needle, context.temp_allocator)
	case .Regex:
		// the needle is the pattern as given
	case: // an out-of-vocabulary value can only arrive through a bad cast
		return "", platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate({
				"invalid mode: ", util.int_to_dec(cast(int)cr.mode, context.temp_allocator),
				", expected 'literal' or 'regex'",
			}, context.temp_allocator),
		}
	}

	re, cerr := compile_multiline_regex(regex_str, context.temp_allocator)
	if cerr != nil {
		// The compile reason rides along: it is the caller's only
		// material for self-correcting a bad pattern.
		return "", platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate(
				{"invalid regex: ", platform.err_message(cerr, context.temp_allocator)},
				context.temp_allocator,
			),
		}
	}
	defer regex_destroy(&re)

	matches := regex_find_all(&re, content, context.temp_allocator)
	// A budget hit means find_all stopped early: the "no match" verdict
	// would be a lie, and the model can self-correct a simpler pattern.
	if re.limit_hit {
		return "", platform.Wrapped{
			kind = .Invalid,
			msg  = "regex match limit exceeded: the pattern's backtracking ran out of budget for this content; simplify the pattern (e.g. drop nested unbounded quantifiers)",
		}
	}
	if len(matches) == 0 {
		return "", platform.Wrapped{kind = .NotFound, msg = "needle not found in content"}
	}
	if !cr.allow_multiple && len(matches) > 1 {
		return "", platform.Wrapped{
			kind = .Invalid,
			msg = strings.concatenate({
				"found ", util.int_to_dec(len(matches), context.temp_allocator),
				" occurrences; use allow_multiple_occurrences or a more specific pattern",
			}, context.temp_allocator),
		}
	}

	for m in matches {
		matched := content[m.start:m.end]
		if strings.contains(matched, "\n") && regex_match_at(&re, matched, 1) {
			return "", platform.Wrapped{
				kind = .Invalid,
				msg = "match is ambiguous: the search pattern matches multiple overlapping occurrences. " +
					"Please revise the search pattern to be more specific to avoid ambiguity, " +
					"e.g. by matching specific context after the match, or try using the literal mode",
			}
		}
	}

	out := make([dynamic]u8, 0, len(content) + len(repl) + 16, a)
	prev := 0
	for m in matches {
		append(&out, content[prev:m.start])
		// Expand $!N from the capture groups of this very match.
		captures := regex_captures_at(&re, content, m.start, context.temp_allocator)
		expand_backreferences(&out, repl, content, captures)
		prev = m.end
	}
	append(&out, content[prev:])
	res := string(out[:])
	out = nil // the bytes are now owned by the result on `a`
	return res, nil
}

// expand_backreferences rewrites $!1..$!N placeholders using the capture
// group text (unset groups expand to the empty string).
expand_backreferences :: proc(
	out:       ^[dynamic]u8,
	repl:      string,
	content:   string,
	captures:  []Match_Range,
) {
	i := 0
	for i < len(repl) {
		if repl[i] == '$' && i + 2 < len(repl) && repl[i + 1] == '!' &&
			repl[i + 2] >= '1' && repl[i + 2] <= '9' {
			group := int(repl[i + 2] - '0')
			if group < len(captures) {
				c := captures[group]
				if c.start >= 0 && c.end >= c.start {
					append(out, content[c.start:c.end])
				}
				i += 3
				continue
			}
		}
		append(out, repl[i])
		i += 1
	}
}



// regex_replace_all substitutes every non-overlapping match of `re` in
// `subject` with `replacement`, expanding $1..$9 group references from
// each match's captures ($1 is the first capture group). Literal '$' must
// be written as $$. The result is allocated on `a` and owned by the
// caller (delete(result, a), or let the owning arena die).
//
// The whole call matches through ONE call-local match buffer, not the
// Regex's own: replace is used on regexes shared across threads (the
// daemon fetcher's post-processing patterns run on the concurrent web
// pool), and a Regex's match_data serves one thread at a time.
regex_replace_all :: proc(re: ^Regex, subject, replacement: string, a := context.allocator) -> string {
	if re.code == nil {
		return strings.clone(subject, a)
	}
	md := pcre2_match_data_create_from_pattern_8(re.code, nil)
	if md == nil {
		return strings.clone(subject, a)
	}
	defer pcre2_match_data_free_8(md)
	out := make([dynamic]u8, 0, len(subject) + 64, a)
	pos := 0
	for pos <= len(subject) {
		caps := captures_at_md(re, subject, pos, md, context.temp_allocator)
		if len(caps) == 0 || caps[0].start < 0 {
			break
		}
		m := caps[0]
		if m.start > pos {
			append(&out, subject[pos:m.start])
		}
		append_expansion(&out, replacement, subject, caps[:])
		if m.end == m.start {
			if m.end < len(subject) {
				append(&out, subject[m.end])
			}
			pos = m.end + 1
		} else {
			pos = m.end
		}
	}
	if pos < len(subject) {
		append(&out, subject[pos:])
	}
	res := string(out[:])
	out = nil // the bytes are now owned by the result on `a`
	return res
}

append_expansion :: proc(out: ^[dynamic]u8, replacement: string, subject: string, caps: []Match_Range) {
	i := 0
	for i < len(replacement) {
		c := replacement[i]
		if c == '$' && i + 1 < len(replacement) {
			next := replacement[i + 1]
			if next == '$' {
				append(out, '$')
				i += 2
				continue
			}
			if next >= '1' && next <= '9' {
				// $N addresses capture group N ($1 is the FIRST group;
				// the whole match, caps[0], is deliberately not
				// addressable — the PCRE2 convention, matching the
				// $!N expansion in expand_backreferences).
				g := int(next - '0')
				if g < len(caps) && caps[g].start >= 0 {
					for j := caps[g].start; j < caps[g].end; j += 1 {
						append(out, subject[j])
					}
				}
				i += 2
				continue
			}
		}
		append(out, c)
		i += 1
	}
}

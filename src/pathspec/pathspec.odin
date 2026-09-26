// gitignore-compatible pattern matching for file path filtering. The
// package is pure logic: patterns compile to regexes (PCRE2 through the
// regex wrapper), matching is last-match-wins, and the gitignore line
// adjustment (per-file rel_dir rebasing) works on content strings —
// filesystem walking belongs to the consumers that collect ignore specs.
//
// Paths are forward-slash relative paths by convention; callers normalize
// separators at their boundary.
package pathspec

import "base:runtime"
import "core:fmt"
import "core:strings"
import "src:regex"

// The reference reads gitignore files through a line scanner with a 1 MiB
// buffer; a longer line is an error, and patterns collected before it stay.
MAX_LINE_BYTES :: 1 << 20

Pattern :: struct {
	re:       ^regex.Regex,
	negate:   bool,
	// Literal fast path: most gitignore lines are wildcard-free path
	// literals ("vendor/", "/build", "pkg/gen"), and the stack matcher
	// runs every pattern against every walked entry — an equality or
	// prefix memcmp replaces the PCRE2 call that otherwise dominates the
	// matcher. `literal` is the pattern core (negation and both slash
	// markers stripped), cloned in the spec's allocator; "" means the
	// pattern has wildcards and must go through the regex. lit_exact is
	// the `^lit$` flavor (anchored, no trailing slash — the entry itself,
	// not its subtree); otherwise the flavor is `^lit(/.*)?$`.
	literal:    string,
	lit_exact:  bool,
}

// Path_Spec is immutable after construction; from_lines and
// from_lines_with_errors are the only constructors.
Path_Spec :: struct {
	patterns:  [dynamic]Pattern,
	allocator: runtime.Allocator,
}

// from_lines builds a PathSpec, skipping blank lines, comments, and
// patterns that fail to compile.
from_lines :: proc(lines: []string, a := context.allocator) -> ^Path_Spec {
	ps, _ := from_lines_with_errors(lines, a)
	return ps
}

// from_lines_with_errors builds a PathSpec and reports the patterns that
// failed to compile. The returned spec is usable even when err is non-nil
// (it contains every successfully compiled pattern); the error string is
// temp-allocator scratch the caller consumes immediately.
from_lines_with_errors :: proc(lines: []string, a := context.allocator) -> (ps: ^Path_Spec, err: string) {
	ps = new(Path_Spec, a)
	ps^ = {patterns = make([dynamic]Pattern, 0, len(lines), a), allocator = a}

	invalid := make([dynamic]string, 0, 4, context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") {
			continue
		}
		pat, ok := compile_pattern(trimmed, a)
		if !ok {
			append(&invalid, strings.clone(trimmed, context.temp_allocator))
			continue
		}
		append(&ps.patterns, pat)
	}
	if len(invalid) > 0 {
		joined, _ := strings.join(invalid[:], ", ", context.temp_allocator)
		err = strings.concatenate(
			{"invalid ignore patterns (silently skipped): ", joined},
			context.temp_allocator,
		)
	}
	return ps, err
}

pathspec_destroy :: proc(ps: ^Path_Spec) {
	if ps == nil {
		return
	}
	for i in 0..<len(ps.patterns) {
		if ps.patterns[i].literal != "" {
			delete(ps.patterns[i].literal, ps.allocator)
		}
		regex.regex_destroy(ps.patterns[i].re)
		free(ps.patterns[i].re, ps.allocator)
	}
	delete(ps.patterns)
	a := ps.allocator
	free(ps, a)
}

// pathspec_match_file reports whether a path matches any pattern.
// Last-match-wins: a later negation pattern (!) un-matches an earlier
// positive pattern, and vice versa.
pathspec_match_file :: proc(ps: ^Path_Spec, path: string) -> bool {
	matched := false
	for i in 0..<len(ps.patterns) {
		if pattern_matches(&ps.patterns[i], path) {
			matched = !ps.patterns[i].negate
		}
	}
	return matched
}

// pattern_matches reports whether one pattern matches a path: the literal
// fast path when the pattern classifies as one (see Pattern), the compiled
// regex otherwise. The literal checks restate the two regex flavors the
// translator emits for wildcard-free patterns — `^lit$` (lit_exact) and
// `^lit(/.*)?$` (subtree) — byte for byte on every valid UTF-8 path; a
// path carrying invalid UTF-8 bytes matches the literal path where the
// UTF-compiled regex no-matches.
pattern_matches :: proc(p: ^Pattern, path: string) -> bool {
	if p.literal == "" {
		return regex.regex_match(p.re, path)
	}
	if p.lit_exact {
		return path == p.literal
	}
	if path == p.literal {
		return true
	}
	return len(path) > len(p.literal) &&
		path[len(p.literal)] == '/' &&
		strings.has_prefix(path, p.literal)
}

// pathspec_match_path matches a relative path (file or directory) against
// the spec; a nil spec matches nothing. There is deliberately no
// trailing-slash retry: dir_only patterns already match the bare
// directory through the `(/.*)?$` suffix, and a retry with "path/" is
// exactly what made a trailing `**` pattern ("build/**") match the bare
// directory — git leaves `build` itself unignored by that pattern, so
// the directory stays walkable and a later negation ("!build/keep")
// can re-include paths under it.
pathspec_match_path :: proc(path: string, ps: ^Path_Spec) -> bool {
	if ps == nil {
		return false
	}
	return pathspec_match_file(ps, path)
}

compile_pattern :: proc(pattern_in: string, a := context.allocator) -> (pat: Pattern, ok: bool) {
	pattern := pattern_in // parameters are immutable; mutate a local copy
	dir_only := false
	negate := false

	if strings.has_prefix(pattern, "!") {
		negate = true
		pattern = pattern[1:]
	}
	if strings.has_suffix(pattern, "/") {
		dir_only = true
		pattern = pattern[:len(pattern) - 1]
	}
	if pattern == "" {
		return {}, false
	}

	// Literal classification: a pattern with no wildcard bytes translates
	// to one of two plain anchored flavors (see Pattern). The leading "/"
	// still rides `pattern` here (glob_to_regex consumes it) — strip it
	// for the core, and remember the anchored-without-dir-slash shape.
	literal := ""
	lit_exact := false
	is_literal := true
	for i := 0; i < len(pattern); i += 1 {
		switch pattern[i] {
		case '*', '?', '[', ']', '\\':
			is_literal = false
		case:
		}
		if !is_literal {
			break
		}
	}
	if is_literal {
		core := pattern
		anchored := strings.has_prefix(core, "/")
		if anchored {
			core = core[1:]
		}
		if core != "" {
			literal = strings.clone(core, a)
			lit_exact = anchored && !dir_only
		}
	}

	// UTF mode: `?` and bracket classes must match one character, not one
	// byte — a `?` has to cover a CJK directory name.
	compiled, cerr := regex.compile_utf_regex(glob_to_regex(pattern, dir_only), context.temp_allocator)
	if cerr != nil {
		if literal != "" {
			delete(literal, a)
		}
		return {}, false
	}
	re := new(regex.Regex, a)
	re^ = compiled
	return {re = re, negate = negate, literal = literal, lit_exact = lit_exact}, true
}

// glob_to_regex translates a gitignore glob pattern into an anchored
// regex. dir_only marks a pattern that carried a trailing "/" in the
// original gitignore. The result is scratch (temp allocator).
glob_to_regex :: proc(pattern_in: string, dir_only: bool, a := context.temp_allocator) -> string {
	pattern := pattern_in // parameters are immutable; mutate a local copy
	b := strings.builder_make(a)
	strings.write_string(&b, "^")

	anchored := strings.has_prefix(pattern, "/")
	if anchored {
		pattern = pattern[1:]
	}

	// Walk the '/'-separated segments without materializing a segment
	// list; empty segments translate to empty fragments, exactly like a
	// naive split.
	seg_start := 0
	prev_was_double_star := false
	first := true
	for i := 0; i <= len(pattern); i += 1 {
		if i < len(pattern) && pattern[i] != '/' {
			continue
		}
		segment := pattern[seg_start:i]
		if !first && !prev_was_double_star {
			strings.write_string(&b, "/")
		}
		first = false
		if segment == "**" {
			is_last := i >= len(pattern)
			if is_last {
				// A trailing ** covers everything strictly INSIDE the
				// directory — git leaves the bare directory (and its
				// trailing-slash spelling) unignored by "dir/**", so the
				// separator plus at least one non-empty remainder is
				// required. `.+` spans further separators.
				strings.write_string(&b, ".+")
			} else {
				strings.write_string(&b, "(.+/)?")
			}
			prev_was_double_star = true
		} else {
			glob_segment_to_regex(segment, &b)
			prev_was_double_star = false
		}
		seg_start = i + 1
	}

	if anchored && !dir_only {
		strings.write_string(&b, "$")
	} else {
		strings.write_string(&b, "(/.*)?$")
	}
	return strings.to_string(b)
}

// glob_segment_to_regex translates one path segment (between slashes) from
// gitignore glob syntax into a regex fragment appended to b.
glob_segment_to_regex :: proc(segment: string, out: ^strings.Builder) {
	for i := 0; i < len(segment); i += 1 {
		c := segment[i]
		switch c {
		case '[':
			close_idx := strings.index_byte(segment[i:], ']')
			if close_idx >= 0 {
				class := segment[i : i + close_idx + 1]
				if len(class) > 1 && class[1] == '!' {
					strings.write_string(out, "[^")
					strings.write_string(out, class[2:])
				} else {
					strings.write_string(out, class)
				}
				i += close_idx
			} else {
				strings.write_string(out, "\\[")
			}
		case ']':
			strings.write_string(out, "\\]")
		case '*':
			if i + 1 < len(segment) && segment[i + 1] == '*' {
				strings.write_string(out, ".*")
				i += 1
			} else {
				strings.write_string(out, "[^/]*")
			}
		case '?':
			strings.write_string(out, "[^/]")
		case '.', '+', '(', ')', '{', '}', '^', '$', '|':
			strings.write_byte(out, '\\')
			strings.write_byte(out, c)
		case '\\':
			if i + 1 < len(segment) {
				i += 1
				next := segment[i]
				switch next {
				case '.', '+', '(', ')', '{', '}', '^', '$', '|', '\\', '[', ']', '*', '?':
					strings.write_byte(out, '\\')
					strings.write_byte(out, next)
				case:
					strings.write_byte(out, next)
				}
			} else {
				strings.write_string(out, "\\\\")
			}
		case:
			strings.write_byte(out, c)
		}
	}
}

// gitignore_patterns_from_content translates .gitignore content into
// adjusted pattern strings rebased for the file's directory relative to
// the project root ("" or "." for the root itself). A line longer than
// 1 MiB is an error; patterns collected before it are still returned.
// The returned strings are cloned in `a`.
gitignore_patterns_from_content :: proc(
	content: string,
	rel_dir: string,
	a := context.allocator,
) -> (patterns: []string, err: string) {
	dir := rel_dir // parameters are immutable; mutate a local copy
	if dir == "." {
		dir = ""
	}
	dyn := make([dynamic]string, 0, 8, a)

	line_start := 0
	for line_start <= len(content) {
		nl := strings.index_byte(content[line_start:], '\n')
		raw: string
		if nl < 0 {
			raw = content[line_start:]
			line_start = len(content) + 1
		} else {
			raw = content[line_start:line_start + nl]
			line_start += nl + 1
		}
		// The reference's line scanner drops a trailing \r with the \n.
		if len(raw) > 0 && raw[len(raw) - 1] == '\r' {
			raw = raw[:len(raw) - 1]
		}
		if len(raw) > MAX_LINE_BYTES {
			return dyn[:], fmt.aprintf(
				"gitignore line is too large (%d bytes); maximum is %d bytes",
				len(raw), MAX_LINE_BYTES, allocator = context.temp_allocator,
			)
		}
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			if nl < 0 {
				break
			}
			continue
		}
		is_negation := strings.has_prefix(line, "!")
		if is_negation {
			line = line[1:]
		}
		line = strings.trim_space(line)
		if line == "" {
			if nl < 0 {
				break
			}
			continue
		}
		if strings.has_prefix(line, "\\#") || strings.has_prefix(line, "\\!") {
			line = line[1:]
		}
		is_anchored := strings.has_prefix(line, "/")
		if is_anchored {
			line = line[1:]
		}
		// git's separator rule: a separator at the beginning or middle of a
		// pattern anchors it to the .gitignore's own directory, while a
		// pattern with no separator at all matches at any level below it.
		// The trailing slash is a directory marker, not an anchor — judge
		// the rule on the core with the marker stripped.
		core := line
		if strings.has_suffix(core, "/") {
			core = core[:len(core) - 1]
		}
		has_separator := strings.contains(core, "/")

		adjusted: string
		if dir != "" {
			if is_anchored || has_separator {
				adjusted = join_slash(dir, line, context.temp_allocator)
			} else {
				adjusted = join_slash(dir, strings.concatenate({"**/", line}, context.temp_allocator), context.temp_allocator)
			}
		} else if is_anchored {
			adjusted = strings.concatenate({"/", line}, context.temp_allocator)
		} else if has_separator {
			adjusted = line
		} else {
			adjusted = strings.concatenate({"**/", line}, context.temp_allocator)
		}
		if is_negation {
			adjusted = strings.concatenate({"!", adjusted}, context.temp_allocator)
		}
		append(&dyn, strings.clone(adjusted, a))
		if nl < 0 {
			break
		}
	}
	return dyn[:], ""
}

join_slash :: proc(x: string, y: string, a := context.temp_allocator) -> string {
	return strings.concatenate({x, "/", y}, a)
}

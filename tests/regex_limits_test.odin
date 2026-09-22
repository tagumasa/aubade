// The match budget: a short catastrophic-backtracking pattern against a
// long non-matching subject must return (as a typed, self-correctable
// error — never a hang), and legitimate patterns must not notice the
// budget. Before the mcontext limits, (a+)+$ on tens of KB of input ran
// unbounded and hung the calling worker thread.
package tests

import "core:testing"
import "src:platform"
import "src:regex"

evil_subject :: proc(len: int, a := context.allocator) -> string {
	buf := make([]u8, len, a)
	for i in 0..<len - 1 {
		buf[i] = u8('a')
	}
	buf[len - 1] = u8('b')
	return string(buf)
}

@(test)
regex_match_limit_bounds_catastrophic_backtracking :: proc(t: ^testing.T) {
	re, cerr := regex.compile_regex("(a+)+$", context.allocator)
	testing.expectf(t, cerr == nil, "compile: %v", cerr)
	if cerr != nil {
		return
	}
	defer regex.regex_destroy(&re)

	subject := evil_subject(40_000)
	defer delete(subject, context.allocator)

	matched := regex.regex_match_at(&re, subject, 0)
	testing.expect_value(t, matched, false)
	testing.expect_value(t, re.limit_hit, true)
}

@(test)
regex_budget_error_surfaces_through_content_replace :: proc(t: ^testing.T) {
	cr: regex.Content_Replacer
	regex.content_replacer_init(&cr, .Regex, false)
	content := evil_subject(40_000)
	defer delete(content, context.allocator)

	_, err := regex.content_replace(&cr, content, "(a+)+$", "x", context.allocator)
	testing.expect_value(t, err != nil, true)
	if err == nil {
		return
	}
	testing.expect_value(t, platform.err_kind(err) == .Invalid, true)
}

@(test)
regex_legitimate_patterns_run_under_the_budget :: proc(t: ^testing.T) {
	patterns: []string = {
		"func \\w+\\(",
		"\\bTODO\\b.*",
		"[A-Z][a-z]+",
		"a[^b]*b",
	}
	subject := "func main() { x := aaaaab TODO fixme Alpha\n}"
	for p in patterns {
		re, cerr := regex.compile_regex(p, context.allocator)
		testing.expectf(t, cerr == nil, "compile %s: %v", p, cerr)
		if cerr != nil {
			continue
		}
		matched := regex.regex_match_at(&re, subject, 0)
		testing.expectf(t, matched, "expected a match for %s", p)
		testing.expect_value(t, re.limit_hit, false)
		regex.regex_destroy(&re)
	}
}

// Tests for src/regex: the PCRE2 wrapper API (compile variants, matcher,
// content replacer with $!N, brace/glob translation, bounded glob cache).
package tests

import "core:mem"
import "core:strings"
import "core:testing"
import "src:platform"
import "src:regex"
import "src:util"

@(test)
regex_compile_and_match :: proc(t: ^testing.T) {
	re, err := regex.compile_regex("h(el)+o", context.temp_allocator)
	testing.expect(t, err == nil, "compile must succeed")
	defer regex.regex_destroy(&re)
	testing.expect(t, regex.regex_match(&re, "say helo!"))
	testing.expect(t, regex.regex_match(&re, "say helelo!"))
	testing.expect(t, !regex.regex_match(&re, "say hello!"))

	// Flags: (?sm wraps for multiline, (?s) alone keeps ^ whole-string.
	re_m, err_m := regex.compile_multiline_regex("^x", context.temp_allocator)
	testing.expect(t, err_m == nil)
	defer regex.regex_destroy(&re_m)
	testing.expect(t, regex.regex_match(&re_m, "a\nx"))

	re_s, err_s := regex.compile_dotall_regex("^x", context.temp_allocator)
	testing.expect(t, err_s == nil)
	defer regex.regex_destroy(&re_s)
	testing.expect(t, !regex.regex_match(&re_s, "a\nx"))
	testing.expect(t, regex.regex_match(&re_s, "x"))

	re_i, err_i := regex.compile_regex_with_flags("case", "i", context.temp_allocator)
	testing.expect(t, err_i == nil)
	defer regex.regex_destroy(&re_i)
	testing.expect(t, regex.regex_match(&re_i, "MiXeD CaSe"))
}

@(test)
regex_compile_errors :: proc(t: ^testing.T) {
	_, err := regex.compile_regex("[unclosed", context.temp_allocator)
	testing.expect(t, err != nil, "unclosed class must fail")

	long := strings.clone(regex_strings_repeat("a", 5000), context.temp_allocator)
	_, err2 := regex.compile_regex(long, context.temp_allocator)
	testing.expect(t, err2 != nil, "oversized pattern must fail")
	testing.expect(t, strings.contains(err_msg(err2), "exceeds maximum"))
}

@(test)
regex_find_all_and_captures :: proc(t: ^testing.T) {
	re, err := regex.compile_regex(`(\w+)@(\w+)`, context.temp_allocator)
	testing.expect(t, err == nil)
	defer regex.regex_destroy(&re)

	subject := "a@b xx c@d"
	ranges := regex.regex_find_all(&re, subject, context.temp_allocator)
	testing.expect_value(t, len(ranges), 2)
	testing.expect_value(t, ranges[0].start, 0)
	testing.expect_value(t, ranges[0].end, 3)
	testing.expect_value(t, ranges[1].start, 7)
	testing.expect_value(t, ranges[1].end, 10)

	caps := regex.regex_captures_at(&re, subject, 0, context.temp_allocator)
	testing.expect_value(t, len(caps), 3)
	testing.expect(t, string(subject[caps[1].start:caps[1].end]) == "a")
	testing.expect(t, string(subject[caps[2].start:caps[2].end]) == "b")

	// Unset optional group carries the -1 sentinel.
	re_o, err_o := regex.compile_regex("(x)|(y)", context.temp_allocator)
	testing.expect(t, err_o == nil)
	defer regex.regex_destroy(&re_o)
	caps2 := regex.regex_captures_at(&re_o, "y", 0, context.temp_allocator)
	testing.expect_value(t, len(caps2), 3)
	testing.expect_value(t, caps2[1].start, -1)
	testing.expect_value(t, caps2[2].start, 0)
}

err_msg :: proc(err: platform.Err) -> string {
	#partial switch e in err {
	case platform.Wrapped:
		return e.msg
	case:
		return ""
	}
}

@(test)
regex_quote_meta :: proc(t: ^testing.T) {
	testing.expect_value(t, regex.quote_meta("a.b*c", context.temp_allocator), `a\.b\*c`)
	testing.expect(t, regex.quote_meta("(x)+?$^[]{}|", context.temp_allocator) == `\(x\)\+\?\$\^\[\]\{\}\|`)
}

@(test)
regex_content_replacer :: proc(t: ^testing.T) {
	cr: regex.Content_Replacer

	regex.content_replacer_init(&cr, .Literal, false)
	out, err := regex.content_replace(&cr, "hello world", "world", "Aubade", context.temp_allocator)
	testing.expect(t, err == nil, "literal replace must succeed")
	testing.expect_value(t, out, "hello Aubade")

	_, err = regex.content_replace(&cr, "hello world", "missing", "x", context.temp_allocator)
	testing.expect(t, err != nil, "missing needle must error")

	_, err = regex.content_replace(&cr, "aaa", "a", "b", context.temp_allocator)
	testing.expect(t, err != nil, "multiple occurrences must error without the flag")

	regex.content_replacer_init(&cr, .Literal, true)
	out, err = regex.content_replace(&cr, "aaa", "a", "b", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, out, "bbb")

	regex.content_replacer_init(&cr, .Regex, false)
	out, err = regex.content_replace(&cr, "hello world", "w.rld", "Aubade", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, out, "hello Aubade")

	out, err = regex.content_replace(&cr, "hello world", "(hello) (world)", "$!2 $!1", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, out, "world hello")

	out, err = regex.content_replace(&cr, "line1\nline2\nline3", "line1.*?line3", "REPLACED", context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, out, "REPLACED")
}

// Diagnostics must carry the material for self-correction: a bad pattern
// surfaces the compile reason, an invalid mode surfaces its value.
@(test)
regex_content_replacer_diagnostics :: proc(t: ^testing.T) {
	cr: regex.Content_Replacer

	regex.content_replacer_init(&cr, .Regex, false)
	_, err := regex.content_replace(&cr, "hello", "[unclosed", "x", context.temp_allocator)
	testing.expect(t, err != nil, "a bad pattern must error")
	if err != nil {
		msg := platform.err_message(err, context.temp_allocator)
		testing.expect(t, strings.contains(msg, "invalid regex:"), "the failure names the regex stage: %s", msg)
		testing.expect(t, len(msg) > len("invalid regex: "), "the compile reason rides along: %s", msg)
	}

	regex.content_replacer_init(&cr, cast(regex.Replace_Mode)7, false)
	_, err = regex.content_replace(&cr, "hello", "h", "x", context.temp_allocator)
	testing.expect(t, err != nil, "an invalid mode must error")
	if err != nil {
		msg := platform.err_message(err, context.temp_allocator)
		testing.expect(t, strings.contains(msg, "invalid mode: 7"), "the mode value rides along: %s", msg)
		testing.expect(t, strings.contains(msg, "expected 'literal' or 'regex'"), msg)
	}
}

@(test)
regex_expand_braces :: proc(t: ^testing.T) {
	one := regex.expand_braces("*.{js,ts,go}")
	testing.expect_value(t, len(one), 3)
	found_js, found_ts, found_go := false, false, false
	for p in one {
		if p == "*.js" { found_js = true }
		if p == "*.ts" { found_ts = true }
		if p == "*.go" { found_go = true }
	}
	testing.expect(t, found_js && found_ts && found_go)

	nested := regex.expand_braces("{a,b}.{js,ts}")
	testing.expect_value(t, len(nested), 4)

	none := regex.expand_braces("*.go")
	testing.expect_value(t, len(none), 1)
	testing.expect_value(t, none[0], "*.go")
}

@(test)
regex_glob_to_regex_goldens :: proc(t: ^testing.T) {
	testing.expect_value(t, regex.glob_to_regex("*.go", context.temp_allocator), `[^/]*\.go`)
	// Unclosed bracket/brace degrade to literals.
	testing.expect_value(t, regex.glob_to_regex("[abc", context.temp_allocator), `\[abc`)
	testing.expect(t, regex.glob_to_regex("{js,ts", context.temp_allocator) == `\{js,ts`)
	testing.expect_value(t, regex.glob_to_regex("[abc]", context.temp_allocator), "[abc]")
	testing.expect_value(t, regex.glob_to_regex("**/x", context.temp_allocator), `(?:.*/)?x`)
}

@(test)
regex_glob_match :: proc(t: ^testing.T) {
	testing.expect(t, regex.glob_match("*.go", "main.go", nil))
	testing.expect(t, !regex.glob_match("*.go", "main.py", nil))
	testing.expect(t, regex.glob_match("src/**/*.go", "src/pkg/main.go", nil))
	testing.expect(t, regex.glob_match("src/**/*.go", "src/main.go", nil))
	testing.expect(t, regex.glob_match("*.{js,ts}", "main.js", nil))
	testing.expect(t, regex.glob_match("*.{js,ts}", "main.ts", nil))
	testing.expect(t, !regex.glob_match("*.{js,ts}", "main.go", nil))
	testing.expect(t, regex.glob_match("[abc].go", "a.go", nil))
	testing.expect(t, regex.glob_match("[a-z].go", "m.go", nil))
	testing.expect(t, !regex.glob_match("[a-z].go", "A.go", nil))
	testing.expect(t, regex.glob_match("[!x].go", "a.go", nil))
	testing.expect(t, !regex.glob_match("[!x].go", "x.go", nil))
	// Windows-style separators normalize.
	testing.expect(t, regex.glob_match("src/*.go", `src\main.go`, nil))
}

@(test)
regex_glob_cache_bounds_and_release :: proc(t: ^testing.T) {
	cache: util.Bounded_Cache(string, regex.Regex)
	util.cache_init(&cache, 2, context.allocator, regex.regex_cache_release)
	defer util.cache_destroy(&cache)

	testing.expect(t, regex.glob_match("*.go", "main.go", &cache))
	testing.expect(t, regex.glob_match("*.py", "main.py", &cache))
	testing.expect(t, regex.glob_match("*.rs", "main.rs", &cache))
	// *.go was evicted by the 2-entry cap; matching still works (recompile
	// on miss), and the eviction released the old compiled regex.
	testing.expect(t, regex.glob_match("*.go", "other.go", &cache))

	// The cap still holds after the re-match: the two most recent patterns
	// (*.rs, then the re-compiled *.go) stay cached, and the re-put evicted
	// *.py. Asserted unconditionally — an if-ok wrapper around an ok
	// assert can never fail.
	re_rs, ok_rs := util.cache_get(&cache, "*.rs")
	testing.expect(t, ok_rs, "*.rs must still be cached")
	if ok_rs {
		testing.expect(t, regex.regex_match(&re_rs, "x.rs"))
	}
	_, ok_go := util.cache_get(&cache, "*.go")
	testing.expect(t, ok_go, "*.go must be cached after its re-match")
	_, ok_py := util.cache_get(&cache, "*.py")
	testing.expect(t, !ok_py, "*.py must have been evicted by the re-put")
}

@(test)
util_bounded_cache_lru :: proc(t: ^testing.T) {
	cache: util.Bounded_Cache(string, int)
	util.cache_init(&cache, 2, context.temp_allocator)
	defer util.cache_destroy(&cache)

	util.cache_put(&cache, "a", 1)
	util.cache_put(&cache, "b", 2)
	// Touch "a" so "b" becomes the least recently used. The hits are
	// asserted unconditionally before their value checks — an if-ok
	// wrapper alone can never fail (the eviction test pins the rule).
	v_a, a_ok := util.cache_get(&cache, "a")
	testing.expect(t, a_ok, "a must be cached before the touch")
	if a_ok {
		testing.expect_value(t, v_a, 1)
	}
	util.cache_put(&cache, "c", 3)
	_, b_ok := util.cache_get(&cache, "b")
	testing.expect(t, !b_ok, "b must have been evicted")
	v_a2, a_ok2 := util.cache_get(&cache, "a")
	testing.expect(t, a_ok2, "a must survive as the recently used entry")
	if a_ok2 {
		testing.expect_value(t, v_a2, 1)
	}
	v_c, c_ok := util.cache_get(&cache, "c")
	testing.expect(t, c_ok, "c must be cached after its put")
	if c_ok {
		testing.expect_value(t, v_c, 3)
	}
	// Overwrite in place.
	util.cache_put(&cache, "a", 10)
	v_a3, a_ok3 := util.cache_get(&cache, "a")
	testing.expect(t, a_ok3, "a must be cached after the overwrite")
	if a_ok3 {
		testing.expect_value(t, v_a3, 10)
	}
}

regex_strings_repeat :: proc(s: string, n: int) -> string {
	out := make([dynamic]u8, 0, len(s) * n, context.temp_allocator)
	for _ in 0..<n {
		append(&out, s)
	}
	return string(out[:])
}

// quote_meta copies non-ASCII bytes verbatim (rune iteration truncated
// them to one byte, silently compiling a different pattern).
@(test)
regex_quote_meta_non_ascii :: proc(t: ^testing.T) {
	testing.expect_value(t, regex.quote_meta("日本語.zip", context.temp_allocator), `日本語\.zip`)
	needle := regex.quote_meta("café*", context.temp_allocator)
	re, err := regex.compile_regex(needle, context.temp_allocator)
	testing.expect(t, err == nil)
	if err == nil {
		defer regex.regex_destroy(&re)
		testing.expect(t, regex.regex_match(&re, "tag café* here"))
		testing.expect(t, !regex.regex_match(&re, "tag café here"))
	}
}

@(test)
regex_replace_all_group_references :: proc(t: ^testing.T) {
	// $N addresses capture group N ($1 is the FIRST group — the whole
	// match, caps[0], is not addressable), matching the $!N expansion.
	re, err := regex.compile_regex(`(\w+)@(\w+)`, context.temp_allocator)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer regex.regex_destroy(&re)
	out := regex.regex_replace_all(&re, "a@b c@d", "$2:$1", context.temp_allocator)
	testing.expect_value(t, out, "b:a d:c")

	// The shape the web post-process uses: strip one leading whitespace
	// character and keep the character after it (an off-by-one here kept
	// the whitespace and ate the following character instead).
	lead, lerr := regex.compile_regex(`(?m)^([ \t])([^ \t\n])`, context.temp_allocator)
	testing.expect(t, lerr == nil)
	if lerr != nil {
		return
	}
	defer regex.regex_destroy(&lead)
	stripped := regex.regex_replace_all(&lead, " foo\n bar", "$2", context.temp_allocator)
	testing.expect_value(t, stripped, "foo\nbar")
}

@(test)
regex_match_local_parity :: proc(t: ^testing.T) {
	// The shared-Regex match: results must equal regex_match while never
	// touching the Regex's own match_data (the outliner caches share one
	// compiled pattern across request threads).
	re, err := regex.compile_regex(`^a+b$`, context.temp_allocator)
	testing.expect(t, err == nil)
	if err != nil {
		return
	}
	defer regex.regex_destroy(&re)
	testing.expect(t, regex.regex_match_local(&re, "aaab"))
	testing.expect(t, !regex.regex_match_local(&re, "ba"))
	testing.expect(t, !regex.regex_match_local(&re, ""))
}

@(test)
glob_cache_entries_survive_a_scratch_reset :: proc(t: ^testing.T) {
	// A cached compiled glob belongs to the cache for its lifetime: the
	// compile must ride the cache's allocator, so the entry still matches
	// after the calling thread's scratch dies. A temp-backed entry reads
	// freed memory once the reset lands — the scribble makes that visible.
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)

	cache: util.Bounded_Cache(string, regex.Regex)
	regex.glob_cache_init(&cache, 64, mem.dynamic_arena_allocator(&arena))

	testing.expect(t, regex.glob_match("src/**/*.go", "src/pkg/main.go", &cache))

	mem.free_all(context.temp_allocator)
	noise := make([]u8, 1 << 20, context.temp_allocator)
	for i in 0..<len(noise) {
		noise[i] = 0xAA
	}

	testing.expect(t, regex.glob_match("src/**/*.go", "src/other.go", &cache), "cached entry matches after the scratch reset")

	delete(noise, context.temp_allocator)
}

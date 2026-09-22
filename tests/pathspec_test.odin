// Tests for src/pathspec: gitignore-style matching (last-match-wins),
// directory-suffix handling, the glob->regex translation tables, error
// reporting for invalid patterns, and the gitignore line adjustment.
package tests

import "core:strings"
import "core:testing"
import "src:pathspec"
import "src:regex"

@(test)
pathspec_match_file_table :: proc(t: ^testing.T) {
	cases := []struct {
		patterns: []string,
		path:     string,
		want:     bool,
	}{
		{{"foo.go"}, "foo.go", true},
		{{"foo.go"}, "bar.go", false},
		{{"*.go"}, "foo.go", true},
		{{"*.go"}, "foo.py", false},
		{{"vendor/"}, "vendor/foo.go", true},
		{{"vendor/"}, "src/foo.go", false},
		{{"**/test"}, "foo/test", true},
		{{"**/test"}, "foo/bar/test", true},
		{{"/foo.go"}, "foo.go", true},
		{{"/foo.go"}, "bar/foo.go", false},
		{{"*.go", "!important.go"}, "important.go", false},
		{{"*.go", "!important.go"}, "other.go", true},
		{{"# comment", "*.go"}, "foo.go", true},
		{{"", "*.go"}, "foo.go", true},
		{{"build/"}, "build/output/main", true},
		{{"file?.go"}, "file1.go", true},
		{{"file?.go"}, "file12.go", false},
	}
	for c in cases {
		ps := pathspec.from_lines(c.patterns, context.allocator)
		defer pathspec.pathspec_destroy(ps)
		got := pathspec.pathspec_match_file(ps, c.path)
		testing.expectf(t, got == c.want, "patterns=%v path=%s got=%v want=%v", c.patterns, c.path, got, c.want)
	}
}

@(test)
pathspec_match_file_dir_suffix :: proc(t: ^testing.T) {
	ps := pathspec.from_lines({"build"}, context.allocator)
	defer pathspec.pathspec_destroy(ps)
	testing.expect(t, pathspec.pathspec_match_file(ps, "build"))
	testing.expect(t, pathspec.pathspec_match_file(ps, "build/"))
	testing.expect(t, !pathspec.pathspec_match_file(ps, "buildtools"))
}

// `?` and bracket classes match one character, not one byte — a CJK
// name is one character — and non-UTF-8 bytes in the subject degrade to
// no-match instead of erroring.
@(test)
pathspec_rune_wildcards :: proc(t: ^testing.T) {
	ps := pathspec.from_lines({"src/?/x.go"}, context.allocator)
	defer pathspec.pathspec_destroy(ps)
	testing.expect(t, pathspec.pathspec_match_file(ps, "src/日/x.go"))
	testing.expect(t, !pathspec.pathspec_match_file(ps, "src/ab/x.go"))

	ps2 := pathspec.from_lines({"file?.go"}, context.allocator)
	defer pathspec.pathspec_destroy(ps2)
	testing.expect(t, pathspec.pathspec_match_file(ps2, "file日.go"))
	// An invalid UTF-8 byte in the subject is a clean no-match.
	bad_path := "file\xFF.go"
	testing.expect(t, !pathspec.pathspec_match_file(ps2, bad_path))

	// `*` spans multi-byte characters on valid names.
	ps3 := pathspec.from_lines({"*.go"}, context.allocator)
	defer pathspec.pathspec_destroy(ps3)
	testing.expect(t, pathspec.pathspec_match_file(ps3, "日本語.go"))
}

@(test)
pathspec_match_path :: proc(t: ^testing.T) {
	ps := pathspec.from_lines({"*.go", "vendor/", "**/test"}, context.allocator)
	defer pathspec.pathspec_destroy(ps)

	testing.expect(t, pathspec.pathspec_match_path("main.go", ps))
	testing.expect(t, pathspec.pathspec_match_path("vendor/lib/foo.go", ps))
	testing.expect(t, pathspec.pathspec_match_path("pkg/test/main.go", ps))
	testing.expect(t, !pathspec.pathspec_match_path("main.py", ps))
	testing.expect(t, !pathspec.pathspec_match_path("src/main.go", ps))

	// A nil spec matches nothing.
	testing.expect(t, !pathspec.pathspec_match_path("foo.go", nil))
}

@(test)
pathspec_glob_to_regex_table :: proc(t: ^testing.T) {
	cases := []struct {
		pattern: string,
		dir:     bool,
		path:    string,
		want:    bool,
	}{
		{"foo.go", false, "foo.go", true},
		{"foo.go", false, "foo.go/bar", true},
		{"foo.go", false, "bar", false},
		{"vendor", true, "vendor", true},
		{"vendor", true, "vendor/foo", true},
		{"vendor", true, "vendorfoo", false},
		{"/foo.go", false, "foo.go", true},
		{"/foo.go", false, "bar/foo.go", false},
		{"/vendor", true, "vendor", true},
		{"/vendor", true, "vendor/foo", true},
		{"src/**", false, "src", false},
		{"src/**", false, "src/", false},
		{"src/**", false, "src/a/b", true},
		{"src/**/test", false, "src/test", true},
		{"src/**/test", false, "src/a/test", true},
	}
	for c in cases {
		re_src := pathspec.glob_to_regex(c.pattern, c.dir)
		re, err := regex.compile_regex(re_src, context.temp_allocator)
		testing.expectf(t, err == nil, "compile %q: %v", re_src, err)
		if err != nil {
			continue
		}
		got := regex.regex_match(&re, c.path)
		testing.expectf(t, got == c.want, "regex %s vs path %s got=%v want=%v", re_src, c.path, got, c.want)
	}

	// dirOnly non-anchored must not match unrelated prefixes.
	re_src := pathspec.glob_to_regex("vendor", true)
	re, err := regex.compile_regex(re_src, context.temp_allocator)
	testing.expectf(t, err == nil, "compile %q: %v", re_src, err)
	if err == nil {
		testing.expect(t, !regex.regex_match(&re, "vendor_x"))
	}

	// ']' outside a character class compiles and matches literally.
	re_src = pathspec.glob_to_regex("foo]bar", false)
	re, err = regex.compile_regex(re_src, context.temp_allocator)
	testing.expectf(t, err == nil, "compile %q: %v", re_src, err)
	if err == nil {
		testing.expect(t, regex.regex_match(&re, "foo]bar"))
	}
}

@(test)
pathspec_glob_segment_table :: proc(t: ^testing.T) {
	cases := []struct {
		segment: string,
		path:    string,
		want:    bool,
	}{
		{"foo", "foo", true},
		{"foo", "bar", false},
		{"*.go", "main.go", true},
		{"*.go", "main.py", false},
		{"file?", "file1", true},
		{"file?", "file", false},
		{"[abc]", "a", true},
		{"[abc]", "d", false},
		{"[!abc]", "d", true},
		{"[!abc]", "a", false},
		{"foo.bar", "foo.bar", true},
		{"foo.bar", "fooXbar", false},
	}
	for c in cases {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "^")
		pathspec.glob_segment_to_regex(c.segment, &b)
		strings.write_string(&b, "$")
		re_src := strings.to_string(b)
		re, err := regex.compile_regex(re_src, context.temp_allocator)
		testing.expectf(t, err == nil, "compile %q: %v", re_src, err)
		if err != nil {
			continue
		}
		got := regex.regex_match(&re, c.path)
		testing.expectf(t, got == c.want, "segment %s vs %s got=%v want=%v", c.segment, c.path, got, c.want)
	}

	// An unclosed bracket is a literal.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "^")
	pathspec.glob_segment_to_regex("foo[bar", &b)
	strings.write_string(&b, "$")
	re, err := regex.compile_regex(strings.to_string(b), context.temp_allocator)
	testing.expectf(t, err == nil, "compile: %v", err)
	if err == nil {
		testing.expect(t, regex.regex_match(&re, "foo[bar"))
	}
}

@(test)
pathspec_from_lines_with_errors :: proc(t: ^testing.T) {
	ps, err := pathspec.from_lines_with_errors({"*.go", "vendor/", "# comment"}, context.allocator)
	defer pathspec.pathspec_destroy(ps)
	testing.expectf(t, err == "", "unexpected error: %s", err)
	testing.expect(t, pathspec.pathspec_match_file(ps, "main.go"))
	testing.expect(t, pathspec.pathspec_match_file(ps, "vendor/lib"))

	ps2, err2 := pathspec.from_lines_with_errors({"*.go", "!"}, context.allocator)
	defer pathspec.pathspec_destroy(ps2)
	testing.expect(t, err2 != "")
	testing.expect(t, strings.contains(err2, "!"))
	testing.expect(t, pathspec.pathspec_match_file(ps2, "main.go"))

	// from_lines skips invalid patterns without failing the valid ones.
	ps3 := pathspec.from_lines({"*.go", "!", "vendor/"}, context.allocator)
	defer pathspec.pathspec_destroy(ps3)
	testing.expect(t, pathspec.pathspec_match_file(ps3, "main.go"))
	testing.expect(t, pathspec.pathspec_match_file(ps3, "vendor/lib"))
}

@(test)
pathspec_gitignore_content_adjustment :: proc(t: ^testing.T) {
	// Root file: no-separator patterns span depth (**/ prefix), negations
	// and dir markers ride along.
	patterns, err := pathspec.gitignore_patterns_from_content(
		"# comment\n*.log\nbuild/\n!important.log\n", "", context.allocator,
	)
	testing.expectf(t, err == "", "unexpected error: %s", err)
	defer if patterns != nil {
		for i in 0..<len(patterns) {
			delete(patterns[i])
		}
		delete(patterns)
	}
	testing.expect_value(t, len(patterns), 3)
	if len(patterns) == 3 {
		testing.expect_value(t, patterns[0], "**/*.log")
		testing.expect_value(t, patterns[1], "**/build/")
		testing.expect_value(t, patterns[2], "!**/important.log")
	}

	// Nested file: patterns rebase under the file's directory.
	nested, err2 := pathspec.gitignore_patterns_from_content("*.tmp\n", "sub/deep", context.allocator)
	testing.expectf(t, err2 == "", "unexpected error: %s", err2)
	defer if nested != nil {
		for i in 0..<len(nested) {
			delete(nested[i])
		}
		delete(nested)
	}
	testing.expect_value(t, len(nested), 1)
	if len(nested) == 1 {
		testing.expect_value(t, nested[0], "sub/deep/**/*.tmp")
	}

	// Escaped # and ! prefixes lose their backslash; anchored patterns
	// keep the anchor.
	escaped, err3 := pathspec.gitignore_patterns_from_content(
		"\\#file\n\\!keep\n/root.txt\n", "sub", context.allocator,
	)
	testing.expectf(t, err3 == "", "unexpected error: %s", err3)
	defer if escaped != nil {
		for i in 0..<len(escaped) {
			delete(escaped[i])
		}
		delete(escaped)
	}
	testing.expect_value(t, len(escaped), 3)
	if len(escaped) == 3 {
		testing.expect_value(t, escaped[0], "sub/**/#file")
		testing.expect_value(t, escaped[1], "sub/**/!keep")
		testing.expect_value(t, escaped[2], "sub/root.txt")
	}
}

// git's separator rule, verified against `git check-ignore` (git 2.43):
// a pattern with no separator matches at any level below its .gitignore's
// directory — root "*.log" ignores a/b/x.log and a root negation
// re-includes at depth — while a middle separator anchors the pattern to
// that directory: sub/.gitignore's "deep/x.txt" ignores sub/deep/x.txt but
// NOT sub/other/deep/x.txt. The trailing slash is a dir marker, not an
// anchor: root "target/" prunes sub/target too.
@(test)
pathspec_gitignore_depth_semantics :: proc(t: ^testing.T) {
	patterns, err := pathspec.gitignore_patterns_from_content(
		"*.log\ntarget/\n!keep.log\n/rooted\nmid/fix\n", "", context.allocator,
	)
	testing.expectf(t, err == "", "unexpected error: %s", err)
	defer if patterns != nil {
		for i in 0..<len(patterns) {
			delete(patterns[i])
		}
		delete(patterns)
	}
	ps := pathspec.from_lines(patterns, context.allocator)
	defer pathspec.pathspec_destroy(ps)

	root_cases := []struct {
		path: string,
		want: bool,
	}{
		{"x.log", true},
		{"a/x.log", true},
		{"a/b/x.log", true},
		{"keep.log", false},
		{"a/keep.log", false},
		{"target", true},
		{"sub/target", true},
		{"sub/target/f", true},
		{"rooted", true},
		{"sub/rooted", false},
		{"mid/fix", true},
		{"mid/fix/x", true},
		{"sub/mid/fix", false},
	}
	for c in root_cases {
		got := pathspec.pathspec_match_path(c.path, ps)
		testing.expectf(t, got == c.want, "root-spec path %s: got %v, want %v", c.path, got, c.want)
	}

	sub, err2 := pathspec.gitignore_patterns_from_content("*.tmp\ndeep/x.txt\n", "sub", context.allocator)
	testing.expectf(t, err2 == "", "unexpected error: %s", err2)
	defer if sub != nil {
		for i in 0..<len(sub) {
			delete(sub[i])
		}
		delete(sub)
	}
	ps2 := pathspec.from_lines(sub, context.allocator)
	defer pathspec.pathspec_destroy(ps2)

	sub_cases := []struct {
		path: string,
		want: bool,
	}{
		{"sub/a.tmp", true},
		{"sub/deep/c.tmp", true},
		{"a.tmp", false},
		{"sub/deep/x.txt", true},
		{"sub/other/deep/x.txt", false},
		{"deep/x.txt", false},
	}
	for c in sub_cases {
		got := pathspec.pathspec_match_path(c.path, ps2)
		testing.expectf(t, got == c.want, "sub-spec path %s: got %v, want %v", c.path, got, c.want)
	}
}

@(test)
pathspec_gitignore_long_line :: proc(t: ^testing.T) {
	// A line beyond the 1 MiB scanner bound errors, but patterns collected
	// before it are still returned.
	// Temp scratch, never delete()d: delete frees through
	// context.allocator, mismatching the temp arena.
	long := strings.repeat("a", 1_100_000, context.temp_allocator)
	content := strings.concatenate({"*.log\n", long, "\nbuild/\n"}, context.temp_allocator)

	patterns, err := pathspec.gitignore_patterns_from_content(content, "", context.allocator)
	testing.expect(t, err != "")
	defer if patterns != nil {
		for i in 0..<len(patterns) {
			delete(patterns[i])
		}
		delete(patterns)
	}
	testing.expect_value(t, len(patterns), 1)
	if len(patterns) == 1 {
		testing.expect_value(t, patterns[0], "**/*.log")
	}
}

@(test)
pathspec_literal_fast_path_shapes :: proc(t: ^testing.T) {
	// Hand-checked expectations for the literal fast path's two flavors:
	// subtree (`^lit(/.*)?$`: "vendor", "vendor/", "pkg/gen",
	// "node_modules/") and exact entry (`^lit$`: "/build"). Wildcard
	// patterns still take the regex — same expectations as before.
	cases := []struct {
		patterns: []string,
		path:     string,
		match:    bool,
	}{
		{{"vendor"}, "vendor", true},
		{{"vendor"}, "vendor/", true},
		{{"vendor"}, "vendor/x/y", true},
		{{"vendor"}, "vendors", false},
		{{"vendor"}, "x/vendor", false},
		{{"vendor/"}, "vendor/a", true},
		{{"/build"}, "build", true},
		{{"/build"}, "build/x", false},
		{{"/build"}, "sub/build", false},
		{{"/build/"}, "build", true},
		{{"/build/"}, "build/x", true},
		{{"pkg/gen"}, "pkg/gen", true},
		{{"pkg/gen"}, "pkg/gen/y", true},
		{{"pkg/gen"}, "pkg", false},
		{{"pkg/gen"}, "x/pkg/gen", false},
		{{"*.log"}, "a.log", true},
		{{"*.log"}, "x/y.log", false}, // raw spec: unanchored single-segment stays top-level ("**/*.log" spans depth)
		{{"**/*.log"}, "x/y.log", true},
		{{"*.log"}, "log", false},
		{{"node_modules/"}, "node_modules/a/b", true},
		{{"node_modules/"}, "node_modulesx", false},
		{{"*.tmp", "!keep.tmp"}, "keep.tmp", false},
		{{"*.tmp", "!keep.tmp"}, "gone.tmp", true},
		// Trailing `**` matches only paths INSIDE the directory — git
		// leaves the bare directory unignored (verified against
		// `git check-ignore`): the directory stays walkable and a later
		// negation can re-include paths under it. The old trailing-slash
		// retry made "build" match "build/**".
		{{"build/**"}, "build", false},
		{{"build/**"}, "build/", false},
		{{"build/**"}, "build/a/b", true},
		{{"build/**"}, "buildx", false},
		{{"build/**"}, "buildx/a", false},
		{{"build/**", "!build/keep"}, "build/keep", false},
		{{"build/**", "!build/keep"}, "build/gone", true},
	}
	for c in cases {
		ps := pathspec.from_lines(c.patterns, context.temp_allocator)
		defer pathspec.pathspec_destroy(ps)
		got := pathspec.pathspec_match_path(c.path, ps)
		testing.expectf(
			t, got == c.match,
			"patterns %v path %q: got %v, expected %v", c.patterns, c.path, got, c.match,
		)
	}
}

// Tests for the platform's path-identity helpers (path_equal,
// path_prefix_equal, strip_root_prefix, path_fold): every comparison
// carries the filesystem's case-sensitivity switch, and separator
// spelling never decides a prefix match.
package tests

import "core:testing"
import "src:platform"

@(test)
path_identity_carries_fs_case :: proc(t: ^testing.T) {
	if platform.case_insensitive_fs() {
		testing.expect(t, platform.path_equal("/a/B.odin", "/A/b.odin"))
		testing.expect(t, platform.path_prefix_equal("/A/b/c", "/a/B"))
		rel, ok := platform.strip_root_prefix("/A/b/c.go", "/a/b")
		testing.expect(t, ok)
		testing.expect_value(t, rel, "c.go")
	} else {
		// Distinct spellings are distinct files: no over-matching.
		testing.expect(t, !platform.path_equal("/a/B.odin", "/A/b.odin"))
		testing.expect(t, !platform.path_prefix_equal("/A/b/c", "/a/b"))
		_, ok := platform.strip_root_prefix("/A/b/c.go", "/a/b")
		testing.expect(t, !ok)
		// Exact spellings still match on case-sensitive filesystems.
		rel, exact := platform.strip_root_prefix("/a/b/c.go", "/a/b")
		testing.expect(t, exact)
		testing.expect_value(t, rel, "c.go")
	}
}

@(test)
path_prefix_separator_tolerance :: proc(t: ^testing.T) {
	// Separator tolerance is a Windows-build concern: platform roots
	// arrive backslashed there while decoded URIs are forward-slashed,
	// so the prefix compare converts both spellings; other platforms
	// see '/' only and a backslash spelling is a different string.
	when ODIN_OS == .Windows {
		rel, wok := platform.strip_root_prefix("/home/u/proj/a.go", "\\home\\u\\proj")
		testing.expect(t, wok)
		testing.expect_value(t, rel, "a.go")
	} else {
		_, nok := platform.strip_root_prefix("/home/u/proj/a.go", "\\home\\u\\proj")
		testing.expect(t, !nok)
	}

	// The boundary must land on a separator: /home/ux is not under /home/u.
	_, ok := platform.strip_root_prefix("/home/ux/a.go", "/home/u")
	testing.expect(t, !ok)
}

@(test)
path_fold_is_canonical_key :: proc(t: ^testing.T) {
	key1 := platform.path_fold("/A/b", context.temp_allocator)
	key2 := platform.path_fold("/a/B", context.temp_allocator)
	if platform.case_insensitive_fs() {
		// Every spelling of one path folds to one key.
		testing.expect_value(t, key1, key2)
	} else {
		// Case-sensitive filesystems keep the spelling (a view — nothing
		// to fold).
		testing.expect_value(t, key1, "/A/b")
		testing.expect_value(t, key2, "/a/B")
	}
}

@(test)
path_fold_basis_is_ascii :: proc(t: ^testing.T) {
	// The fold basis is ASCII-only by design — one basis shared with
	// path_equal and every path-identity consumer (the daemon project id,
	// editor buffer keys, root dedup). A non-ASCII case pair is therefore
	// NOT one path on any platform: folding such a pair would split the
	// key regime from path_equal and over-dedup distinct directories.
	// The é bytes below are the two UTF-8 spellings é (U+00E9) and É
	// (U+00C9).
	cafe_lower := "/proj/caf\xc3\xa9"
	cafe_upper := "/proj/caf\xc3\x89"
	key_lower := platform.path_fold(cafe_lower, context.temp_allocator)
	key_upper := platform.path_fold(cafe_upper, context.temp_allocator)
	testing.expect(t, key_lower != key_upper)
	testing.expect(t, !platform.path_equal(cafe_lower, cafe_upper))
	// The ASCII pairs still fold when the filesystem does.
	if platform.case_insensitive_fs() {
		testing.expect(t, platform.path_fold("/Caf\xc3\xa9/A", context.temp_allocator) ==
			platform.path_fold("/caf\xc3\xa9/a", context.temp_allocator))
	}
}

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

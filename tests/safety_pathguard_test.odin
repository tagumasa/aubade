// Tests for src/safety/pathguard.odin.
// Uses a real temp directory for symlink tests; lexical cases are pure.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "src:safety"

@(test)
path_escapes_root_double_dot :: proc(t: ^testing.T) {
	testing.expect(t, safety.pathguard_escapes_root(".."))
	testing.expect(t, safety.pathguard_escapes_root("../foo"))
	testing.expect(t, safety.pathguard_escapes_root("../../foo"))
}

@(test)
path_escapes_root_absolute :: proc(t: ^testing.T) {
	testing.expect(t, safety.pathguard_escapes_root("/etc/passwd"))
}

@(test)
path_escapes_root_safe :: proc(t: ^testing.T) {
	testing.expect(t, !safety.pathguard_escapes_root("foo"))
	testing.expect(t, !safety.pathguard_escapes_root("foo/bar"))
	testing.expect(t, !safety.pathguard_escapes_root("..foo")) // dotfile, not traversal
	testing.expect(t, !safety.pathguard_escapes_root("foo..bar"))
	testing.expect(t, !safety.pathguard_escapes_root("foo/..bar"))
}

@(test)
validate_contained_relative :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		got, err := safety.pathguard_validate_contained("C:\\project", "src/main.go", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		rel, rel_err := filepath.rel("C:\\project", got, context.temp_allocator)
		testing.expect(t, rel_err == filepath.Relative_Error.None)
		testing.expect(t, !safety.pathguard_escapes_root(rel))
	} else {
		got, err := safety.pathguard_validate_contained("/project", "src/main.go", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		rel, rel_err := filepath.rel("/project", got, context.temp_allocator)
		testing.expect(t, rel_err == filepath.Relative_Error.None)
		testing.expect(t, !safety.pathguard_escapes_root(rel))
	}
}

@(test)
validate_contained_traversal :: proc(t: ^testing.T) {
	_, err := safety.pathguard_validate_contained("/project", "../escape", context.temp_allocator)
	testing.expect(t, err.reason != "")
}

@(test)
validate_contained_relative_traversal_rejected :: proc(t: ^testing.T) {
	// Traversal up is rejected regardless of any subsequent component.
	_, err := safety.pathguard_validate_contained("/project", "../../etc/passwd", context.temp_allocator)
	testing.expect(t, err.reason != "")

	_, err = safety.pathguard_validate_contained("/project", "foo/../../escape", context.temp_allocator)
	testing.expect(t, err.reason != "")
}

@(test)
validate_contained_empty_rejected :: proc(t: ^testing.T) {
	_, err := safety.pathguard_validate_contained("/project", "", context.temp_allocator)
	testing.expect(t, err.reason != "")

	_, err = safety.pathguard_validate_contained("/project", ".", context.temp_allocator)
	testing.expect(t, err.reason != "")
}

@(test)
validate_contained_nonexistent_path :: proc(t: ^testing.T) {
	// Path does not exist on disk: lexical check is sufficient.
	got, err := safety.pathguard_validate_contained("/project", "new/sub/file.txt", context.temp_allocator)
	testing.expect_value(t, err.reason, "")
	testing.expect(t, len(got) > 0)
}

@(test)
validate_contained_dot_dot_filename_safe :: proc(t: ^testing.T) {
	// Filenames like "..foo" or "foo..bar" are not traversal.
	got, err := safety.pathguard_validate_contained("/project", "..foo", context.temp_allocator)
	testing.expect_value(t, err.reason, "")
	got, err = safety.pathguard_validate_contained("/project", "foo..bar", context.temp_allocator)
	testing.expect_value(t, err.reason, "")
}

@(test)
validate_session_id_safe :: proc(t: ^testing.T) {
	ok, _ := safety.pathguard_validate_session_id("abc123")
	testing.expect(t, ok)

	ok, _ = safety.pathguard_validate_session_id("session-001")
	testing.expect(t, ok)
}

@(test)
validate_session_id_empty :: proc(t: ^testing.T) {
	ok, reason := safety.pathguard_validate_session_id("")
	testing.expect(t, !ok)
	testing.expect(t, len(reason) > 0)
}

@(test)
validate_session_id_traversal :: proc(t: ^testing.T) {
	ok, _ := safety.pathguard_validate_session_id("..")
	testing.expect(t, !ok)

	ok, _ = safety.pathguard_validate_session_id("../escape")
	testing.expect(t, !ok)
}

@(test)
validate_session_id_separator :: proc(t: ^testing.T) {
	ok, _ := safety.pathguard_validate_session_id("foo/bar")
	testing.expect(t, !ok)

	ok, _ = safety.pathguard_validate_session_id("foo\\bar")
	testing.expect(t, !ok)
}

@(test)
validate_session_id_too_long :: proc(t: ^testing.T) {
	long_id := strings_repeat("a", 257)
	ok, _ := safety.pathguard_validate_session_id(long_id)
	testing.expect(t, !ok)
}

@(test)
validate_session_id_control_char :: proc(t: ^testing.T) {
	bad_chars := []u8{0x00, 0x01, 0x1F, 0x7F}
	for ch in bad_chars {
		id: [1]u8 = {ch}
		ok, _ := safety.pathguard_validate_session_id(string(id[:]))
		_ = ch
		testing.expectf(t, !ok, "control char 0x%02x rejected", ch)
	}
}

@(test)
validate_contained_symlink_inside :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Creating symlinks on Windows requires elevated privileges.
		return
	}
	// Create a real temp directory with a symlink that points back inside
	// the project. The validator must accept it.
	tmp, mk_err := os.make_directory_temp("", "pathguard_test_", context.temp_allocator)
	if mk_err != nil {
		testing.fail(t)
		return
	}
	defer {
		// The dir holds real files at exit: remove (non-empty) would
		// silently no-op and strand the temp tree.
		_ = os.remove_all(tmp)
		delete(tmp, context.temp_allocator) // make_directory_temp's owned clone
	}

	target, _ := filepath.join({tmp, "real.txt"}, context.temp_allocator)
	link,   _ := filepath.join({tmp, "link.txt"}, context.temp_allocator)
	f, werr := os.create(target)
	if werr != nil {
		testing.fail(t)
		return
	}
	os.close(f)
	link_err := os.symlink(target, link)
	if link_err != nil {
		testing.fail(t)
		return
	}

	got, verr := safety.pathguard_validate_contained(tmp, "link.txt", context.temp_allocator)
	testing.expect_value(t, verr.reason, "")
	// The link must resolve to the real file's location. On macOS the
	// temp tree sits behind the /var -> /private/var symlink, so the
	// resolved spelling legitimately differs from the unresolved `tmp`
	// prefix — compare against the directly-addressed file's resolved
	// path instead of a raw prefix check.
	direct, _ := safety.pathguard_validate_contained(tmp, "real.txt", context.temp_allocator)
	testing.expect_value(t, got, direct)
}

strings_repeat :: proc(s: string, n: int) -> string {
	buf := make([dynamic]u8, 0, len(s) * n, context.temp_allocator)
	for _ in 0 ..< n {
		for c in s {
			append(&buf, u8(c))
		}
	}
	return string(buf[:])
}

@(test)
validate_contained_symlink_escape_rejected :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Creating symlinks on Windows requires elevated privileges.
		return
	}
	// A link inside the project pointing outside must be rejected — both
	// for an existing target read through the link and for a new file
	// written through a linked directory.
	tmp, mk_err := os.make_directory_temp("", "pathguard_esc_", context.temp_allocator)
	if mk_err != nil {
		testing.fail(t)
		return
	}
	defer os.remove_all(tmp)

	parent := filepath.dir(tmp)
	outside, _ := filepath.join({parent, "pathguard_esc_outside"}, context.temp_allocator)
	defer os.remove(outside)
	f, werr := os.create(outside)
	if werr != nil {
		testing.fail(t)
		return
	}
	os.close(f)

	link, _ := filepath.join({tmp, "link.txt"}, context.temp_allocator)
	if os.symlink(outside, link) != nil {
		testing.fail(t)
		return
	}
	_, err := safety.pathguard_validate_contained(tmp, "link.txt", context.temp_allocator)
	testing.expect_value(t, err.reason, "symlink target escapes root")

	// New file through a linked directory that points outside: same verdict
	// (the old whole-path lstat never noticed the linked parent here).
	dir_out, _ := filepath.join({tmp, "dir_out"}, context.temp_allocator)
	if os.symlink(outside, dir_out) != nil {
		testing.fail(t)
		return
	}
	_, err = safety.pathguard_validate_contained(tmp, "dir_out/new.txt", context.temp_allocator)
	testing.expect_value(t, err.reason, "symlink target escapes root")
}

@(test)
validate_contained_new_file_through_inside_symlink :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Creating symlinks on Windows requires elevated privileges.
		return
	}
	// A new file under a symlinked directory that stays inside the project
	// is accepted and resolved to the real directory — fail-open applies
	// only to the missing tail.
	tmp, mk_err := os.make_directory_temp("", "pathguard_new_", context.temp_allocator)
	if mk_err != nil {
		testing.fail(t)
		return
	}
	defer os.remove_all(tmp)

	real_dir, _ := filepath.join({tmp, "real"}, context.temp_allocator)
	if os.make_directory(real_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		testing.fail(t)
		return
	}
	link_dir, _ := filepath.join({tmp, "linkdir"}, context.temp_allocator)
	if os.symlink(real_dir, link_dir) != nil {
		testing.fail(t)
		return
	}

	got, err := safety.pathguard_validate_contained(tmp, "linkdir/new.txt", context.temp_allocator)
	testing.expect_value(t, err.reason, "")
	// Fail-open must still resolve through the link: the returned path is
	// inside the real directory (spelling canonicalized like above — a
	// raw join onto the unresolved temp spelling would differ on macOS).
	want, _ := safety.pathguard_validate_contained(tmp, "real/new.txt", context.temp_allocator)
	testing.expect_value(t, got, want)
}

@(test)
path_escapes_root_backslash_traversal :: proc(t: ^testing.T) {
	testing.expect(t, safety.pathguard_escapes_root("..\\evil"))
	testing.expect(t, safety.pathguard_escapes_root("..\\..\\evil"))
	// Forward-separator traversal keeps working; a dotfile still isn't one.
	testing.expect(t, safety.pathguard_escapes_root("../evil"))
	testing.expect(t, !safety.pathguard_escapes_root("..foo"))
	// Lexically the whole validator closes too: on Linux the backslash
	// survives join/clean as a plain character, so this used to slip
	// through the fail-open missing-tail branch.
	_, err := safety.pathguard_validate_contained("/project", "..\\evil", context.temp_allocator)
	testing.expect(t, err.reason != "")
}

@(test)
validate_contained_dir_direct :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// On Windows only drive-letter paths are absolute.
		got, err := safety.pathguard_validate_contained_dir("C:\\project", ".", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		testing.expect_value(t, got, "C:\\project")

		got, err = safety.pathguard_validate_contained_dir("C:\\project", "sub", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		testing.expect_value(t, got, "C:\\project\\sub")
		got, err = safety.pathguard_validate_contained_dir("C:\\project", "C:\\project\\sub\\deep", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		testing.expect_value(t, got, "C:\\project\\sub\\deep")

		// Outside by absolute path, by plain parent, and by mixed traversal.
		_, err = safety.pathguard_validate_contained_dir("C:\\project", "C:\\Windows", context.temp_allocator)
		testing.expect(t, err.reason != "")
		_, err = safety.pathguard_validate_contained_dir("C:\\project", "..", context.temp_allocator)
		testing.expect(t, err.reason != "")
		_, err = safety.pathguard_validate_contained_dir("C:\\project", "sub/../../x", context.temp_allocator)
		testing.expect(t, err.reason != "")
	} else {
		// The root itself is allowed (a cwd of exactly the project root is
		// legitimate) and comes back cleaned.
		got, err := safety.pathguard_validate_contained_dir("/project", ".", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		testing.expect_value(t, got, "/project")

		// Relative and absolute requests inside the root.
		got, err = safety.pathguard_validate_contained_dir("/project", "sub", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		testing.expect_value(t, got, "/project/sub")
		got, err = safety.pathguard_validate_contained_dir("/project", "/project/sub/deep", context.temp_allocator)
		testing.expect_value(t, err.reason, "")
		testing.expect_value(t, got, "/project/sub/deep")

		// Outside by absolute path, by plain parent, and by mixed traversal.
		_, err = safety.pathguard_validate_contained_dir("/project", "/etc", context.temp_allocator)
		testing.expect(t, err.reason != "")
		_, err = safety.pathguard_validate_contained_dir("/project", "..", context.temp_allocator)
		testing.expect(t, err.reason != "")
		_, err = safety.pathguard_validate_contained_dir("/project", "sub/../../x", context.temp_allocator)
		testing.expect(t, err.reason != "")
	}
}

@(test)
validate_contained_dir_root_symlink_resolved :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Creating symlinks on Windows requires elevated privileges.
		return
	}
	tmp, mk_err := os.make_directory_temp("", "pathguard_dir_", context.temp_allocator)
	if mk_err != nil {
		testing.fail(t)
		return
	}
	defer os.remove_all(tmp)

	real_dir, _ := filepath.join({tmp, "real"}, context.temp_allocator)
	if os.make_directory(real_dir, os.Permissions{.Read_User, .Write_User, .Execute_User}) != nil {
		testing.fail(t)
		return
	}
	link_dir, _ := filepath.join({tmp, "linkdir"}, context.temp_allocator)
	if os.symlink(real_dir, link_dir) != nil {
		testing.fail(t)
		return
	}

	// The symlinked root resolves to the real directory for the root
	// request... (canonicalized spelling: on macOS the temp tree sits
	// behind /var -> /private/var, so compare against the resolved
	// location of the real directory, not the raw join.)
	want_root, _ := safety.pathguard_validate_contained_dir(tmp, "real", context.temp_allocator)
	got, err := safety.pathguard_validate_contained_dir(link_dir, ".", context.temp_allocator)
	testing.expect_value(t, err.reason, "")
	testing.expect_value(t, got, want_root)

	// ...and requests through the linked root land in the real one.
	got, err = safety.pathguard_validate_contained_dir(link_dir, "sub", context.temp_allocator)
	testing.expect_value(t, err.reason, "")
	want, _ := safety.pathguard_validate_contained_dir(tmp, "real/sub", context.temp_allocator)
	testing.expect_value(t, got, want)
}

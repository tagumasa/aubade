// atomic_write must publish new content whole (never a torn target), leave
// no temp file behind on success or failure, keep the previous target
// intact when any step fails, and stamp the published file with exactly
// the permissions the caller passed.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:platform"

@(test)
atomic_write_publishes_and_replaces :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-aw-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	path, _ := filepath.join([]string{dir, "out.txt"}, context.allocator)
	defer delete(path, context.allocator)

	first := "v1 — 最初の内容 🌙"
	err := platform.atomic_write(path, transmute([]u8)first, os.Permissions_Default_File)
	testing.expect_value(t, err == nil, true)
	got, rerr := os.read_entire_file_from_path(path, context.allocator)
	defer delete(got)
	testing.expect_value(t, rerr == nil, true)
	testing.expect_value(t, string(got) == first, true)

	second := "v2 — replaced content"
	err = platform.atomic_write(path, transmute([]u8)second, os.Permissions_Default_File)
	testing.expect_value(t, err == nil, true)
	got2, rerr2 := os.read_entire_file_from_path(path, context.allocator)
	defer delete(got2)
	testing.expect_value(t, rerr2 == nil, true)
	testing.expect_value(t, string(got2) == second, true)

	tmp := strings.concatenate({path, ".tmp"}, context.allocator)
	defer delete(tmp, context.allocator)
	testing.expect_value(t, os.exists(tmp), false)
}

@(test)
atomic_write_failure_keeps_target_and_cleans_temp :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-aw-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	// A directory as the rename target fails the publish deterministically
	// on every platform; the failure must leave the target untouched and
	// remove the temp file.
	target, _ := filepath.join([]string{dir, "target"}, context.allocator)
	defer delete(target, context.allocator)
	if merr := os.make_directory(target, os.Permissions{.Read_User, .Write_User, .Execute_User}); merr != nil {
		testing.fail_now(t, "mkdir failed")
	}

	payload := "payload"
	err := platform.atomic_write(target, transmute([]u8)payload, os.Permissions_Default_File)
	testing.expect_value(t, err != nil, true)
	if err == nil {
		return
	}
	testing.expect_value(t, platform.err_kind(err) == .Internal, true)
	testing.expect_value(t, os.is_directory(target), true)

	tmp := strings.concatenate({target, ".tmp"}, context.allocator)
	defer delete(tmp, context.allocator)
	testing.expect_value(t, os.exists(tmp), false)
}

@(test)
atomic_write_publishes_with_requested_permissions :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		// Permission bits are advisory (read-only) on Windows; the mode
		// round-trip is a POSIX property.
	} else {
		dir, derr := os.make_directory_temp("", "aubade-aw-", context.allocator)
		if derr != nil {
			testing.fail_now(t, "temp dir failed")
		}
		defer {
			_ = os.remove_all(dir)
			delete(dir)
		}
		path, _ := filepath.join([]string{dir, "mode.txt"}, context.allocator)
		defer delete(path, context.allocator)

		content := "x"
		err := platform.atomic_write(path, transmute([]u8)content, os.Permissions{.Read_User, .Write_User})
		testing.expect_value(t, err == nil, true)
		info, serr := os.stat(path, context.allocator)
		if serr != nil {
			testing.expect_value(t, serr == nil, true)
			return
		}
		defer os.file_info_delete(info, context.allocator)
		owner_only := info.mode == os.Permissions{.Read_User, .Write_User}
		testing.expect_value(t, owner_only, true)
	}
}

// The util stat helpers: kind/size surface for real paths, ok=false for
// missing ones, and only lstat reports a symlink (stat follows it).
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:util"

@(test)
util_stat_kind_size :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-fs-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	file_path, _ := filepath.join({tmp, "memo.txt"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(file_path, "hello"); werr != nil {
		testing.fail_now(t, "write failed")
	}

	kind, size, ok := util.stat_kind_size(file_path)
	testing.expectf(t, ok, "regular file: ok")
	testing.expectf(t, kind == .Regular, "regular file: kind %v", kind)
	testing.expectf(t, size == 5, "regular file: size %v", size)

	kind, _, ok = util.stat_kind_size(tmp)
	testing.expectf(t, ok && kind == .Directory, "directory: ok=%v kind=%v", ok, kind)

	missing, _ := filepath.join({tmp, "missing"}, context.temp_allocator)
	_, _, ok = util.stat_kind_size(missing)
	testing.expectf(t, !ok, "missing path reports !ok")
}

@(test)
util_lstat_kind_symlink :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-fs2-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	file_path, _ := filepath.join({tmp, "memo.txt"}, context.temp_allocator)
	if werr := os.write_entire_file_from_string(file_path, "hello"); werr != nil {
		testing.fail_now(t, "write failed")
	}
	link_path, _ := filepath.join({tmp, "link"}, context.temp_allocator)
	if lerr := os.symlink(file_path, link_path); lerr != nil {
		// Creating symlinks needs privileges some environments lack; the
		// follow-vs-not distinction cannot be asserted there.
		return
	}

	lkind, lok := util.lstat_kind(link_path)
	testing.expectf(t, lok && lkind == .Symlink, "lstat sees the link: ok=%v kind=%v", lok, lkind)
	skind, _, sok := util.stat_kind_size(link_path)
	testing.expectf(t, sok && skind == .Regular, "stat follows the link: ok=%v kind=%v", sok, skind)
}

// The util filesystem intake: stat helpers (kind/size surface for real
// paths, ok=false for missing ones, only lstat reports a symlink — stat
// follows it) and the bounded whole-file read (budget enforced while
// reading, non-regular nodes refused).
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

@(test)
util_read_bounded_file :: proc(t: ^testing.T) {
	tmp, err := os.make_directory_temp("", "aubade-fs3-", context.allocator)
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

	data, outcome, _ := util.read_bounded_file(file_path, 1024, context.temp_allocator)
	testing.expect_value(t, outcome, util.Read_Outcome.Ok)
	testing.expectf(t, string(data) == "hello", "under budget: %q", string(data))

	// The budget is inclusive: a file exactly at the limit reads whole.
	exact, exact_outcome, _ := util.read_bounded_file(file_path, 5, context.temp_allocator)
	testing.expect_value(t, exact_outcome, util.Read_Outcome.Ok)
	testing.expectf(t, string(exact) == "hello", "exact budget: %q", string(exact))

	big_path, _ := filepath.join({tmp, "big.bin"}, context.temp_allocator)
	big := make([dynamic]u8, 0, 2048, context.temp_allocator)
	for len(big) < 2048 {
		append(&big, 0)
	}
	if werr := os.write_entire_file(big_path, big[:]); werr != nil {
		testing.fail_now(t, "write failed")
	}
	delete(big)
	// The refusal names the bytes it saw: the stat size at the entry
	// rejection (2048), the number a caller reports without re-statting.
	_, over, over_size := util.read_bounded_file(big_path, 1024, context.temp_allocator)
	testing.expect_value(t, over, util.Read_Outcome.Too_Large)
	testing.expect_value(t, over_size, 2048)

	_, dir_outcome, _ := util.read_bounded_file(tmp, 1024, context.temp_allocator)
	testing.expect_value(t, dir_outcome, util.Read_Outcome.Not_Regular)

	missing, _ := filepath.join({tmp, "missing"}, context.temp_allocator)
	_, miss_outcome, _ := util.read_bounded_file(missing, 1024, context.temp_allocator)
	testing.expect_value(t, miss_outcome, util.Read_Outcome.Missing)

	when ODIN_OS == .Linux {
		// procfs stats report size 0 while the read returns real content:
		// the read-time bound, not the stat gate, must refuse it here.
		_, proc_outcome, _ := util.read_bounded_file("/proc/self/status", 64, context.temp_allocator)
		testing.expect_value(t, proc_outcome, util.Read_Outcome.Too_Large)
	}
}

#+build windows

// The Windows-only retry arm of atomic_write: replacing a file is refused
// while a reader holds it without FILE_SHARE_DELETE (core's os.open shares
// read+write only), so a plain os.open is exactly the flake's holder shape
// — the publish must wait the hold out instead of failing the write.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:thread"
import "core:time"

import "src:platform"

Retry_Box :: struct {
	path: string,
	err:  platform.Err,
}

retry_writer_entry :: proc(data: rawptr) {
	b := cast(^Retry_Box)data
	// A typed local, not a literal: transmute refuses untyped string
	// constants, and this file only compiles on the Windows runner.
	payload := "second"
	b.err = platform.atomic_write(b.path, transmute([]u8)payload, os.Permissions_Default_File)
}

@(test)
atomic_write_waits_out_a_reader_holding_the_target :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-awhold-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	path, _ := filepath.join([]string{dir, "held.txt"}, context.allocator)
	defer delete(path, context.allocator)

	seed := "first"
	if err := platform.atomic_write(path, transmute([]u8)seed, os.Permissions_Default_File); err != nil {
		testing.expectf(t, false, "seed write failed")
		return
	}

	holder, herr := os.open(path, {.Read})
	testing.expect_value(t, herr == nil, true)
	if herr != nil {
		return
	}

	box := new(Retry_Box, context.allocator)
	defer free(box, context.allocator)
	box^ = {path = path}
	writer := thread.create_and_start_with_data(box, retry_writer_entry, self_cleanup = false, name = "aw-hold-writer")

	// Hold across at least one failed rename attempt, then release — the
	// writer's bounded retry lands the rename after it. The release is
	// unconditional, so the join is bounded by the retry budget.
	time.sleep(150 * time.Millisecond)
	os.close(holder)

	thread.join(writer)
	free(writer, context.allocator)
	testing.expect_value(t, box.err == nil, true)
	got, rerr := os.read_entire_file_from_path(path, context.allocator)
	defer delete(got)
	testing.expect_value(t, rerr == nil, true)
	testing.expect_value(t, string(got) == "second", true)
}

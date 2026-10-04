#+build windows

// The Windows-only retry arm of atomic_write: replacing a file is refused
// while a reader holds it without FILE_SHARE_DELETE (core's os.open shares
// read+write only), so a plain os.open is exactly the flake's holder shape
// — the publish must wait the hold out instead of failing the write.
package tests

import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "src:platform"

Retry_Box :: struct {
	path:    string,
	err:     platform.Err,
	mu:      sync.Mutex,
	cond:    sync.Cond,
	started: bool,
}

retry_writer_entry :: proc(b: ^Retry_Box) {
	sync.mutex_lock(&b.mu)
	b.started = true
	sync.cond_broadcast(&b.cond)
	sync.mutex_unlock(&b.mu)
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
	writer := thread.create_and_start_with_poly_data(box, retry_writer_entry, self_cleanup = false, name = "aw-hold-writer")

	// Wait until the writer is provably inside atomic_write, then hold
	// across two retry steps so the first rename attempts fail against
	// the held file (the step constant owns the exact spacing). The
	// release is unconditional, so the join stays bounded by the retry
	// budget either way.
	sync.mutex_lock(&box.mu)
	for !box.started {
		sync.cond_wait(&box.cond, &box.mu)
	}
	sync.mutex_unlock(&box.mu)
	time.sleep(time.Duration(platform.RENAME_RETRY_STEP_MS * 2) * time.Millisecond)
	os.close(holder)

	thread.join(writer)
	free(writer, context.allocator)
	testing.expect_value(t, box.err == nil, true)
	got, rerr := os.read_entire_file_from_path(path, context.allocator)
	defer delete(got)
	testing.expect_value(t, rerr == nil, true)
	testing.expect_value(t, string(got) == "second", true)
}

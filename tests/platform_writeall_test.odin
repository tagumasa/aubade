// write_all_with must keep driving the port until every byte is written,
// surface the first port error, and treat a zero-progress port as a stall;
// write_all must persist the whole buffer to a real file.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "src:platform"

one_byte_port :: proc(user: rawptr, data: []u8) -> (int, platform.Err) {
	written := cast(^int)user
	if len(data) == 0 {
		return 0, nil
	}
	(written)^ += 1
	return 1, nil
}

@(test)
write_all_with_drives_short_writes_to_completion :: proc(t: ^testing.T) {
	sample := "abcd"
	written := 0
	err := platform.write_all_with(&written, transmute([]u8)sample, one_byte_port)
	testing.expect_value(t, err == nil, true)
	testing.expect_value(t, written, 4)
}

@(test)
write_all_with_accepts_an_empty_buffer :: proc(t: ^testing.T) {
	empty := ""
	calls := 0
	err := platform.write_all_with(&calls, transmute([]u8)empty, one_byte_port)
	testing.expect_value(t, err == nil, true)
	testing.expect_value(t, calls, 0)
}

fail_after_two_port :: proc(user: rawptr, data: []u8) -> (int, platform.Err) {
	calls := cast(^int)user
	(calls)^ += 1
	if (calls)^ == 2 {
		return 1, .Internal
	}
	return 1, nil
}

@(test)
write_all_with_surfaces_the_first_port_error :: proc(t: ^testing.T) {
	sample := "abcd"
	calls := 0
	err := platform.write_all_with(&calls, transmute([]u8)sample, fail_after_two_port)
	kind, is_kind := err.(platform.Err_Kind)
	testing.expect_value(t, is_kind, true)
	testing.expect_value(t, kind == .Internal, true)
	testing.expect_value(t, calls, 2)
}

stalled_port :: proc(user: rawptr, data: []u8) -> (int, platform.Err) {
	return 0, nil
}

@(test)
write_all_with_fails_a_zero_progress_port :: proc(t: ^testing.T) {
	sample := "abcd"
	err := platform.write_all_with(nil, transmute([]u8)sample, stalled_port)
	kind, is_kind := err.(platform.Err_Kind)
	testing.expect_value(t, is_kind, true)
	testing.expect_value(t, kind == .Internal, true)
}

@(test)
write_all_persists_the_whole_buffer :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-wa-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	path, _ := filepath.join([]string{dir, "out.txt"}, context.allocator)
	defer delete(path, context.allocator)

	sample := "0123456789abcdef"
	f, oerr := os.open(path, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	testing.expect_value(t, oerr == nil, true)
	if oerr != nil {
		return
	}
	werr := platform.write_all(f, transmute([]u8)sample)
	os.close(f)
	testing.expect_value(t, werr == nil, true)

	got, rerr := os.read_entire_file_from_path(path, context.allocator)
	defer delete(got)
	testing.expect_value(t, rerr == nil, true)
	testing.expect_value(t, len(got), 16)
	testing.expect_value(t, string(got) == sample, true)
}

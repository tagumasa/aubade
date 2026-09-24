// The production file-IO port for the editor: the services layer owns
// core:os (the domain editor stays process-free and testable), classifying
// each failure into the editor's closed Editor_Err vocabulary so no string
// matching happens anywhere.
package svc

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"

import "src:editor"
import "src:platform"
import "src:util"

editor_file_read :: proc(user: rawptr, abs_path: string, max_bytes: i64, alloc: runtime.Allocator) -> (data: []u8, err: editor.Editor_Err, msg: string) {
	// The byte budget is enforced at read time by the shared bounded
	// reader (stat size is only a fast path and capacity hint there): a
	// file growing between the stat and the read still surfaces Too_Large
	// instead of an unbounded read, and a FIFO or device node is refused
	// rather than opened.
	read, outcome, refused := util.read_bounded_file(abs_path, max_bytes, alloc)
	if outcome == .Ok {
		return read, .None, ""
	}
	if outcome == .Missing {
		return nil, .NotFound, "file not found"
	}
	if outcome == .Not_Regular {
		return nil, .IO, "not a regular file"
	}
	if outcome == .Too_Large {
		// The bounded reader names the bytes it saw at the refusal — the
		// size the model judges a sliced retry against.
		return nil, .Too_Large, fmt.aprintf("file is too large (%d bytes); maximum is %d bytes", refused, max_bytes, allocator = context.temp_allocator)
	}
	return nil, .IO, "read failed"
}

editor_file_write :: proc(user: rawptr, abs_path: string, data: []u8) -> (err: editor.Editor_Err, msg: string) {
	// The atomic publish renames a temp file over the target, which resets
	// the mode to the temp file's — stat first so an overwrite keeps the
	// current permissions (new files fall back to the default set).
	perms := os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other}
	if info, serr := os.stat(abs_path, context.temp_allocator); serr == nil {
		perms = info.mode
		os.file_info_delete(info, context.temp_allocator)
	}
	if aerr := platform.atomic_write(abs_path, data, perms); aerr != nil {
		return .IO, "write failed"
	}
	return .None, ""
}

editor_file_stat :: proc(user: rawptr, abs_path: string) -> (mtime_ns: i64, size: i64, ok: bool) {
	info, serr := os.stat(abs_path, context.temp_allocator)
	if serr != nil {
		return 0, 0, false
	}
	mtime_ns = time.time_to_unix_nano(info.modification_time)
	size = info.size
	os.file_info_delete(info, context.temp_allocator)
	return mtime_ns, size, true
}

// editor_file_io_port wires the production implementations; the daemon
// hands this to editor_init.
editor_file_io_port :: proc() -> editor.File_IO_Port {
	return {read = editor_file_read, write = editor_file_write, stat = editor_file_stat}
}

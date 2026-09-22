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

editor_file_read :: proc(user: rawptr, abs_path: string, max_bytes: i64, alloc: runtime.Allocator) -> (data: []u8, err: editor.Editor_Err, msg: string) {
	info, serr := os.stat(abs_path, context.temp_allocator)
	if serr != nil {
		return nil, .NotFound, "file not found"
	}
	size := info.size
	os.file_info_delete(info, context.temp_allocator)
	if size > max_bytes {
		return nil, .Too_Large, fmt.aprintf("file is too large (%d bytes); maximum is %d bytes", size, max_bytes, allocator = context.temp_allocator)
	}
	// The bound holds at read time, not just at the stat above: a file
	// growing in between still surfaces Too_Large instead of an unbounded
	// read (read_entire_file would swallow the growth). The chunked loop
	// also serves files whose stat size under-reports their content
	// (procfs-style), which a size-sized buffer would truncate.
	f, oerr := os.open(abs_path, {.Read}, os.Permissions{.Read_User})
	if oerr != nil {
		return nil, .NotFound, "file not found"
	}
	defer os.close(f)
	limit := int(max_bytes)
	cap_hint := int(size) + 1
	if cap_hint > limit {
		cap_hint = limit
	}
	buf := make([dynamic]u8, 0, cap_hint, context.temp_allocator)
	chunk: [64 * 1024]u8
	for {
		n, rerr := os.read(f, chunk[:])
		if rerr != nil {
			// EOF arrives as the error side on this runtime (the count
			// loop in the file face breaks on `n == 0 || rerr != nil`
			// for the same reason); a genuine IO failure is the error it
			// reports.
			if rerr == .EOF {
				break
			}
			delete(buf)
			return nil, .IO, "read failed"
		}
		if n == 0 {
			break
		}
		if len(buf) + n > limit {
			delete(buf)
			return nil, .Too_Large, fmt.aprintf("file is too large (grew while reading); maximum is %d bytes", max_bytes, allocator = context.temp_allocator)
		}
		old := len(buf)
		resize(&buf, old + n)
		copy(buf[old:], chunk[:n])
	}
	out := make([]u8, len(buf), alloc)
	if len(buf) > 0 {
		copy(out, buf[:])
	}
	delete(buf)
	return out, .None, ""
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

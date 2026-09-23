// Stat helpers that keep the core:os ownership rule at arm's length:
// os.stat/os.lstat clone File_Info.fullpath with the allocator the caller
// passes, so a raw stat hands back an owned string the caller must free.
// These wrappers delete the info before returning and expose only the
// fields callers use — the owned clone cannot leak past the call, and the
// allocator argument cannot be dropped by a future caller.
package util

import "core:os"
import "core:time"

// stat_kind_size stats `path` (following symlinks) and returns its type
// and size; ok=false when the path does not exist or is not accessible.
stat_kind_size :: proc(path: string, a := context.temp_allocator) -> (kind: os.File_Type, size: i64, ok: bool) {
	info, err := os.stat(path, a)
	if err != nil {
		return .Undetermined, 0, false
	}
	kind, size = info.type, info.size
	os.file_info_delete(info, a)
	return kind, size, true
}

// stat_kind_size_mtime additionally returns the modification time as
// unix nanoseconds — the disk fingerprint the incremental symbol crawl
// records per file. Wall-clock by necessity (it names the file's own
// mtime, not a deadline), but it is only ever COMPARED against a
// previously recorded fingerprint of the same file, never used as a
// timeout or TTL input.
stat_kind_size_mtime :: proc(path: string, a := context.temp_allocator) -> (kind: os.File_Type, size: i64, mtime_ns: i64, ok: bool) {
	info, err := os.stat(path, a)
	if err != nil {
		return .Undetermined, 0, 0, false
	}
	kind, size = info.type, info.size
	mtime_ns = time.time_to_unix_nano(info.modification_time)
	os.file_info_delete(info, a)
	return kind, size, mtime_ns, true
}

// lstat_kind stats `path` without following symlinks and returns its type
// (the symlink-resolving loops branch on .Symlink); ok=false when the path
// does not exist or is not accessible.
lstat_kind :: proc(path: string, a := context.temp_allocator) -> (kind: os.File_Type, ok: bool) {
	info, err := os.lstat(path, a)
	if err != nil {
		return .Undetermined, false
	}
	kind = info.type
	os.file_info_delete(info, a)
	return kind, true
}

// Read_Gate is the stat-first intake verdict for a file a reader is about
// to read whole: Ok means a regular file within the size budget, and every
// other outcome says why no byte should be read.
Read_Gate :: enum {
	Ok,
	Missing,
	Not_Regular,
	Too_Large,
}

// read_gate answers whether the file at `path` is a regular file of at
// most `max_bytes` BEFORE any byte is read, so a planted FIFO, device, or
// oversized file can neither balloon the reader nor block it. Missing is
// its own outcome — callers apply their own absent-file policy (defaults,
// bootstrap, fallback), same as a failed read.
read_gate :: proc(path: string, max_bytes: i64) -> Read_Gate {
	kind, size, ok := stat_kind_size(path)
	if !ok {
		return .Missing
	}
	if kind != .Regular {
		return .Not_Regular
	}
	if size > max_bytes {
		return .Too_Large
	}
	return .Ok
}

// Read_Outcome is the verdict of a size-budgeted whole-file read: Ok comes
// back with the bytes, and every other member says why no byte array did.
Read_Outcome :: enum {
	Ok,
	Missing,
	Not_Regular,
	Too_Large,
	Unreadable,
}

// read_bounded_file reads one regular file whole under `max_bytes`, the
// bytes owned by `a`. The stat up front is only a fast-path rejection and
// a capacity hint — the chunked loop enforces the byte budget WHILE
// reading, so a file that grows after the stat still surfaces Too_Large
// instead of an unbounded read, and files whose stat size under-reports
// their content (procfs-style) stay bounded too. Non-regular nodes are
// refused rather than opened: a FIFO or device would block or misbehave
// on open, not just over-read. Unreadable means the node existed and was
// regular, but the open or a read still failed (vanished mid-call,
// permissions, IO error).
read_bounded_file :: proc(path: string, max_bytes: i64, a := context.allocator) -> (data: []u8, outcome: Read_Outcome) {
	kind, size, ok := stat_kind_size(path)
	if !ok {
		return nil, .Missing
	}
	if kind != .Regular {
		return nil, .Not_Regular
	}
	if size > max_bytes {
		return nil, .Too_Large
	}
	f, oerr := os.open(path, {.Read}, os.Permissions{.Read_User})
	if oerr != nil {
		return nil, .Unreadable
	}
	defer os.close(f)

	limit := int(max_bytes)
	cap_hint := int(size) + 1
	if cap_hint > limit {
		cap_hint = limit
	}
	buf := make([dynamic]u8, 0, cap_hint, a)
	chunk: [64 * 1024]u8
	for {
		n, rerr := os.read(f, chunk[:])
		if rerr != nil {
			// EOF arrives on the error side of os.read on this runtime; a
			// genuine IO failure is the error it reports.
			if rerr == .EOF {
				break
			}
			delete(buf)
			return nil, .Unreadable
		}
		if n == 0 {
			break
		}
		if len(buf) + n > limit {
			delete(buf)
			return nil, .Too_Large
		}
		old := len(buf)
		resize(&buf, old + n)
		copy(buf[old:], chunk[:n])
	}
	return buf[:], .Ok
}

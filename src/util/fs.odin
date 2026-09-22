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

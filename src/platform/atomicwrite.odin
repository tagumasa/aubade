// Durable file publication: every writer that must never expose a torn
// file goes through here — write to a temp file in the target directory,
// fsync the data, rename over the target, then fsync the directory so the
// rename itself survives a crash.
package platform

import "core:os"
import "core:path/filepath"
import "core:strings"

// atomic_write publishes `data` at `path` durably: until the rename lands,
// the previous content (if any) stays intact, and a crash at any point
// leaves either the old file or the new one — never a half-written target.
// The temp name is stable (not unique), so callers must serialize
// concurrent writes to the same path (a file lock, a package mutex, or
// single-writer ownership all qualify). The published file carries exactly
// `perms` — the rename replaces the target with the temp file's mode, so a
// caller that wants an overwrite to keep the current mode must stat the
// target and pass it through.
atomic_write :: proc(path: string, data: []u8, perms: os.Permissions) -> Err {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	f, oerr := os.open(tmp, {.Write, .Create, .Trunc}, perms)
	if oerr != nil {
		return Wrapped{
			kind = .Internal,
			msg  = strings.concatenate({"atomic write: cannot create temp file: ", path}, context.temp_allocator),
		}
	}
	if werr := write_all(f, data); werr != nil {
		os.close(f)
		os.remove(tmp)
		return Wrapped{
			kind = .Internal,
			msg  = strings.concatenate({"atomic write: write failed: ", path}, context.temp_allocator),
		}
	}
	if serr := os.sync(f); serr != nil {
		os.close(f)
		os.remove(tmp)
		return Wrapped{
			kind = .Internal,
			msg  = strings.concatenate({"atomic write: sync failed: ", path}, context.temp_allocator),
		}
	}
	os.close(f)
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return Wrapped{
			kind = .Internal,
			msg  = strings.concatenate({"atomic write: rename failed: ", path}, context.temp_allocator),
		}
	}
	sync_dir(filepath.dir(path))
	return nil
}

// sync_dir best-effort fsyncs the directory so the rename is durable; the
// file data is already synced, so a failure here loses only the link in
// the instants after publish. Windows cannot sync directory handles — the
// NTFS rename is atomic anyway.
sync_dir :: proc(dir: string) {
	when ODIN_OS == .Windows {
	} else {
		d, derr := os.open(dir, {.Read})
		if derr != nil {
			return
		}
		os.sync(d)
		os.close(d)
	}
}

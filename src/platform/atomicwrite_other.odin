#+build !windows

// The POSIX half of atomic_write's rename step: rename replaces an open
// file, so no hold can make the publish transiently fail — a plain rename
// with no retry (the Windows twin carries the rationale).
package platform

import "core:os"

rename_publish :: proc(tmp, path: string) -> os.Error {
	return os.rename(tmp, path)
}

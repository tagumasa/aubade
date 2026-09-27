#+build windows

// The Windows half of atomic_write's rename step. Replacing a file is
// refused for as long as any handle holds the target without
// FILE_SHARE_DELETE, and core's os.open shares read+write only — so this
// process's own index crawl, an LSP client, or a virus scanner holding a
// just-written file surfaces the rename as Permission_Denied until the
// holder lets go (core folds ERROR_SHARING_VIOLATION and
// ERROR_ACCESS_DENIED into that one value, so it is the only signal
// available). The bounded retry waits the hold out; a permanent refusal
// (read-only target, ACL) still fails once the budget is spent.
package platform

import "core:os"
import "core:time"

RENAME_RETRY_ATTEMPTS :: 40
RENAME_RETRY_STEP_MS  :: 50 // attempts x step ≈ 2 s worst case

rename_publish :: proc(tmp, path: string) -> os.Error {
	rerr := os.rename(tmp, path)
	for attempt := 0; attempt < RENAME_RETRY_ATTEMPTS && rerr == .Permission_Denied; attempt += 1 {
		time.sleep(time.Duration(RENAME_RETRY_STEP_MS) * time.Millisecond)
		rerr = os.rename(tmp, path)
	}
	return rerr
}

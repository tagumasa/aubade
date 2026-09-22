#+build linux, darwin

// The spawn seam (POSIX): pass-through twins. core's os.pipe sets
// FD_CLOEXEC on both ends (pipe2 on Linux, fcntl on the BSDs) and
// os.open defaults to close-on-exec, so a spawned child receives only
// the descriptors core dup2's onto its standard slots — the Windows
// seam's discipline has nothing to enforce here, and the shared names
// keep every caller spelling one spawn path.
package platform

import "core:os"

spawn_pipe :: proc() -> (r, w: ^os.File, err: os.Error) {
	return os.pipe()
}

spawn_start :: proc(desc: os.Process_Desc) -> (os.Process, os.Error) {
	return os.process_start(desc)
}

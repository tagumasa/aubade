#+build linux, darwin

// procrun's stop seam (POSIX): the direct path stops its plain child.
// The stop-job slot is a Windows-only concept — group runs go through
// the proctree seam, never through the direct path here, so the slot is
// always zero and its release has nothing to do.
package platform

import "core:os"

procrun_kill_child :: proc(child: os.Process, stop_job: uintptr) -> os.Error {
	return os.process_kill(child)
}

procrun_release_stop_job :: proc(stop_job: uintptr) {}

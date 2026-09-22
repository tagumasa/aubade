// The Linux arm of the spawn-reap test: a true reap removes the pid
// from /proc entirely (a zombie would keep the entry alive). fmt renders
// the /proc path and lives only in this file, so no other platform ever
// sees the import unused.
#+build linux

package tests

import "core:fmt"
import "core:os"
import "core:testing"

expect_proc_reaped :: proc(t: ^testing.T, pid: int) {
	proc_path := fmt.aprintf("/proc/%d", pid, allocator = context.temp_allocator)
	testing.expect(t, !os.exists(proc_path), "the pid must be reaped, not left as a zombie")
}

// The Windows spawn seam's observable contract: pipes leave the seam
// non-inheritable, so no later child can pick up another call's ends.
// The POSIX twin is a pass-through (core ships CLOEXEC pipes), so only
// the Windows arm asserts — its body lives in the platform-suffixed
// twin file and the branch prunes elsewhere.
package tests

import "core:testing"

@(test)
spawn_pipe_ends_not_inheritable :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		spawn_pipe_flags_checked_on_windows(t)
	}
}

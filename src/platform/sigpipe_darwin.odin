#+build darwin

// SIGPIPE policy for the server processes (darwin half — see
// sigpipe_linux.odin for the rationale).
package platform

import "core:sys/posix"

ignore_sigpipe :: proc() {
	// core:sys/posix exports no SIG_IGN constant; in libc it is the
	// address 1 cast to the handler type.
	act := posix.sigaction_t{
		sa_handler = cast(proc "c" (posix.Signal))rawptr(uintptr(1)),
	}
	_ = posix.sigaction(.SIGPIPE, &act, nil)
}

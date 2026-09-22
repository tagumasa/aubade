#+build darwin

// Stop-signal registration (darwin half — see signal_linux.odin for the
// rationale).
package platform

import "base:intrinsics"
import "core:sys/posix"

signal_register_handlers :: proc() -> bool {
	act := posix.sigaction_t{
		sa_handler = signal_os_handler,
		sa_flags   = {.RESTART},
	}
	ok := true
	if r := posix.sigaction(.SIGINT, &act, nil); r != .OK {
		ok = false
	}
	if r := posix.sigaction(.SIGTERM, &act, nil); r != .OK {
		ok = false
	}
	return ok
}

signal_os_handler :: proc "c" (sig: posix.Signal) {
	_ = sig
	// Async-signal-safe: latch and return.
	intrinsics.atomic_store_explicit(&stop_requested, true, .Release)
}

signal_reset_handlers :: proc() {
	// core:sys/posix exports no SIG_DFL constant; in libc it is the null
	// handler address.
	dfl := posix.sigaction_t{
		sa_handler = cast(proc "c" (posix.Signal))nil,
	}
	_ = posix.sigaction(.SIGINT, &dfl, nil)
	_ = posix.sigaction(.SIGTERM, &dfl, nil)
}

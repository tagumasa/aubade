#+build linux

// Stop-signal registration (Linux half; darwin mirrors this, Windows
// uses the console control handler). SA_RESTART keeps interrupted
// syscalls transparent — the IO loops map EINTR onto hard errors.
package platform

import "base:intrinsics"
import "core:sys/linux"

signal_register_handlers :: proc() -> bool {
	act := linux.Sig_Action{
		handler = signal_os_handler,
		flags   = {.RESTART},
	}
	ok := true
	if linux.rt_sigaction(.SIGINT, &act, nil) != linux.Errno(0) {
		ok = false
	}
	if linux.rt_sigaction(.SIGTERM, &act, nil) != linux.Errno(0) {
		ok = false
	}
	return ok
}

signal_os_handler :: proc "c" (sig: linux.Signal) {
	_ = sig
	// Async-signal-safe: latch and return.
	intrinsics.atomic_store_explicit(&stop_requested, true, .Release)
}

signal_reset_handlers :: proc() {
	dfl := linux.Sig_Action{
		special = .SIG_DFL,
	}
	_ = linux.rt_sigaction(.SIGINT, &dfl, nil)
	_ = linux.rt_sigaction(.SIGTERM, &dfl, nil)
}

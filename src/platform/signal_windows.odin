#+build windows

// Stop-signal registration (Windows half): there is no SIGTERM, so the
// console control handler (Ctrl-C, close, logoff, shutdown) is the
// signal surface — after it latches, the stop order is identical to
// POSIX.
package platform

import "base:intrinsics"
import "core:sys/windows"

signal_register_handlers :: proc() -> bool {
	return windows.SetConsoleCtrlHandler(signal_console_handler, windows.TRUE) != windows.FALSE
}

signal_console_handler :: proc "system" (ctrl_type: windows.DWORD) -> windows.BOOL {
	_ = ctrl_type
	intrinsics.atomic_store_explicit(&stop_requested, true, .Release)
	// Handled: the process stops through its own token, not the default
	// console behavior.
	return windows.TRUE
}

signal_reset_handlers :: proc() {
	// A null routine with Add=FALSE removes the handler this process
	// installed.
	_ = windows.SetConsoleCtrlHandler(nil, windows.FALSE)
}

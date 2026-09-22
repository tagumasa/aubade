#+build linux

// SIGPIPE policy for the server processes (Linux half; darwin mirrors
// this, Windows has no SIGPIPE). Writing to a pipe whose reader died must
// surface as an EPIPE errno, never as a signal that kills the process —
// the language-server stdin pipe is written right up to the moment a
// crashed server's end collapses.
package platform

import "core:sys/linux"

// ignore_sigpipe installs SIG_IGN for SIGPIPE. Idempotent; call at
// startup (or before the first pipe write — the disposition is
// process-wide and inherited across exec).
ignore_sigpipe :: proc() {
	act := linux.Sig_Action{
		special = .SIG_IGN,
	}
	_ = linux.rt_sigaction(.SIGPIPE, &act, nil)
}

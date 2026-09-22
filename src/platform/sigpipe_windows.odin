#+build windows

// SIGPIPE policy (Windows half): pipes are HANDLEs — a dead reader
// surfaces as a write error, there is no signal to ignore.
package platform

ignore_sigpipe :: proc() {}

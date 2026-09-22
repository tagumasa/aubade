// proctree: the shared surface of the POSIX process-tree discipline.
// The per-OS implementations (proctree_linux.odin, proctree_darwin.odin)
// fork and exec the child in its own process group and stop it as a
// group, so a spawned command's whole tree dies with the call that
// spawned it. Windows has no twin here: its group containment is the Job
// object (job_windows.odin), armed from procrun's Windows build.
package platform

import "core:mem"
import "core:os"

// Proctree_Signal selects the kill signal for group/tree stops.
Proctree_Signal :: enum {
	TERM,
	KILL,
}

// proctree_to_cstr clones a string into a NUL-terminated cstring (spawn
// runs on the temp allocator; nothing crosses the fork).
proctree_to_cstr :: proc(s: string, a: mem.Allocator) -> cstring {
	buf := make([dynamic]u8, 0, len(s) + 1, a)
	append(&buf, ..transmute([]u8)s)
	append(&buf, 0)
	return cstring(&buf[0])
}

// proctree_env_cstrings materializes env as the NUL-terminated cstring
// array execve takes (nil = the caller's own environment). The terminator
// is load-bearing: an append-grown array leaves the slot past its last
// entry uninitialized (and an empty override would have no [0] to take),
// so the array is made with length N+1 and the trailing zero-value nil is
// the sentinel. argv and envp share this shape; the lsproc spawn seam
// delegates here too.
proctree_env_cstrings :: proc(env: []string, a: mem.Allocator) -> (envp: [^]cstring, err: Err) {
	// Parameters are immutable; the nil-fallback rebinds a local.
	src := env
	if src == nil {
		environ, eerr := os.environ(a)
		if eerr != nil {
			return nil, Err(.Internal)
		}
		src = environ
	}
	cenv := make([]cstring, len(src) + 1, a)
	for e, i in src {
		cenv[i] = proctree_to_cstr(e, a)
	}
	return &cenv[0], nil
}

// Proctree_Desc describes one own-group child. The pipe write ends are
// ^os.File values the caller drained from os.pipe; the fork child dup2's
// them onto the standard descriptors, so the parent keeps reading through
// the ordinary core:os stream surface.
Proctree_Desc :: struct {
	command:     []string, // argv; command[0] resolved through PATH when bare
	working_dir: string,   // "" = inherit the caller's
	env:         []string, // KEY=VALUE entries; nil = inherit
	stdout_w:    ^os.File, // the child's stdout lands here
	stderr_w:    ^os.File, // nil = the child's stderr goes to the null device
	// Arm the child to die with its parent (Linux: PR_SET_PDEATHSIG).
	// darwin has no equivalent: lsproc arms its death sitter for language
	// servers there, and procrun's tool commands tie their lifetime to
	// the call, so the flag is accepted and ignored.
	pdeathsig: bool,
}

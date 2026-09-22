#+build windows

// The spawn seam (Windows): keeps a child's inheritance to exactly the
// stdio handles it needs. core's os.pipe creates BOTH ends inheritable
// (the child must be able to receive them) and core's _process_start
// calls CreateProcessW with bInheritHandles=true and no handle list, so
// by default every child inherits every pipe end open in the process at
// spawn time — concurrent command runs' capture pipes and every language
// server's pipe set. A strayed write end keeps its pipe off EOF for the
// holder's lifetime (a running shell command would stall a language
// server's stdin-EOF shutdown nudge), so the seam closes the windows in
// which any inheritable handle is observable:
//
//   - spawn_pipe clears INHERIT on both ends at once, inside the seam
//     mutex, so no concurrent CreateProcessW can catch the fresh pair;
//   - spawn_start marks exactly the three stdio handles, runs the spawn,
//     and restores their previous flags, all inside the same mutex — the
//     only inheritable handles visible to the call are the child's own
//     (plus core's transient NUL for unset slots, created inside the
//     same critical section).
//
// Every daemon-side pipe and spawn goes through this seam (procrun,
// lsproc, the parent-daemon spawn, the CLI editor), which is what makes
// the mutex a closure rather than a narrowing: a single spawn discipline
// per process. The mutex is seam state, not application state — the
// handle table it guards is process-wide.
package platform

import "core:os"
import "core:sync"
import "core:sys/windows"

spawn_mu: sync.Mutex // SRWLOCK zero value: valid without init

// spawn_pipe is os.pipe with both ends' inheritance cleared under the
// seam mutex — a concurrent spawn can never observe this pair.
spawn_pipe :: proc() -> (r, w: ^os.File, err: os.Error) {
	sync.mutex_lock(&spawn_mu)
	defer sync.mutex_unlock(&spawn_mu)
	r, w, err = os.pipe()
	if err != nil {
		return nil, nil, err
	}
	spawn_clear_inherit(r)
	spawn_clear_inherit(w)
	return r, w, nil
}

// spawn_start is os.process_start with the child's inheritance narrowed
// to its stdio handles: mark the three, spawn, restore. The previous
// flag state is captured first so shared handles (the caller's own stdio
// in the CLI editor, one NUL file reused for all three slots) come back
// exactly as they were.
spawn_start :: proc(desc: os.Process_Desc) -> (child: os.Process, err: os.Error) {
	sync.mutex_lock(&spawn_mu)
	defer sync.mutex_unlock(&spawn_mu)

	stdio := [3]^os.File{desc.stdin, desc.stdout, desc.stderr}
	saved := [3]bool{}
	for f, i in stdio {
		if f == nil {
			continue
		}
		saved[i] = spawn_inherit_state(f)
		spawn_set_inherit(f, true)
	}
	child, err = os.process_start(desc)
	for f, i in stdio {
		if f == nil {
			continue
		}
		spawn_set_inherit(f, saved[i])
	}
	return child, err
}

spawn_clear_inherit :: proc(f: ^os.File) {
	_ = windows.SetHandleInformation(windows.HANDLE(os.fd(f)), windows.HANDLE_FLAG_INHERIT, 0)
}

spawn_inherit_state :: proc(f: ^os.File) -> bool {
	flags: windows.DWORD = 0
	_ = windows.GetHandleInformation(windows.HANDLE(os.fd(f)), &flags)
	return (flags & windows.HANDLE_FLAG_INHERIT) != 0
}

spawn_set_inherit :: proc(f: ^os.File, inherit: bool) {
	set: windows.DWORD = 0
	if inherit {
		set = windows.HANDLE_FLAG_INHERIT
	}
	_ = windows.SetHandleInformation(windows.HANDLE(os.fd(f)), windows.HANDLE_FLAG_INHERIT, set)
}

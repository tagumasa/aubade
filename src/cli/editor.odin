// open_in_editor: the shared helper behind `config edit`, `context
// create/edit`, `mode create/edit`, and the prompt-override commands.
// The editor is $EDITOR (a single executable) with per-OS fallbacks;
// stdio is inherited so interactive editors work.
package cli

import "core:fmt"
import "core:os"

import "src:platform"

// open_in_editor runs the editor on path and waits for it. Returns false
// when the editor could not start or exited non-zero (the caller prints
// the failure).
open_in_editor :: proc(cmd: string, path: string) -> bool {
	editor := ""
	if e, ok := os.lookup_env_alloc("EDITOR", context.temp_allocator); ok && e != "" {
		editor = e
	} else {
		when ODIN_OS == .Windows {
			editor = "notepad"
		} else when ODIN_OS == .Darwin {
			editor = "open"
		} else {
			editor = "xdg-open"
		}
	}

	argv: [dynamic]string = make([dynamic]string, 0, 3, context.temp_allocator)
	append(&argv, editor)
	// The separator keeps editors from treating a leading-dash path as a
	// flag (not passed on Windows, whose programs do not use it).
	when ODIN_OS != .Windows {
		append(&argv, "--")
	}
	append(&argv, path)

	desc := os.Process_Desc{
		command = argv[:],
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	}
	// The spawn seam keeps the child's inheritance to its stdio (on
	// Windows it marks exactly these three handles for the call and
	// restores them after; the editor's stdio is the point of the
	// inheritance, so it passes through untouched).
	child, err := platform.spawn_start(desc)
	if err != nil {
		fmt.eprintf("aubade %s: cannot start editor %q\n", cmd, editor)
		return false
	}
	state, _ := os.process_wait(child)
	if !state.exited {
		fmt.eprintf("aubade %s: editor %q did not exit cleanly\n", cmd, editor)
		return false
	}
	if state.exit_code != 0 {
		fmt.eprintf("aubade %s: editor %q exited with status %d\n", cmd, editor, state.exit_code)
		return false
	}
	return true
}

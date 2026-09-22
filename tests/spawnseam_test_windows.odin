#+build windows

// The Windows arm of the spawn-seam test: the flag query itself needs
// core:sys/windows, which only this platform-suffixed twin may import.
package tests

import "core:os"
import "core:testing"
import "core:sys/windows"

import "src:platform"

spawn_pipe_flags_checked_on_windows :: proc(t: ^testing.T) {
	r, w, perr := platform.spawn_pipe()
	testing.expect(t, perr == nil)
	if perr != nil {
		return
	}
	defer os.close(r)
	defer os.close(w)

	ends := []^os.File{r, w}
	for f in ends {
		flags: windows.DWORD = 0
		ok := windows.GetHandleInformation(windows.HANDLE(os.fd(f)), &flags)
		testing.expect(t, ok != windows.FALSE)
		testing.expect(t, (flags & windows.HANDLE_FLAG_INHERIT) == 0, "both ends must leave the seam non-inheritable")
	}
}

// Test for the stop-signal bridge: a real SIGTERM delivered to this
// process must latch the flag and fire the bound root token within the
// watch slice. OS-signal latency is inherently real time — no injected
// clock can move it — so the wait polls in short real slices. The
// dispositions are restored afterwards so the shared test runner stays
// killable. Linux only: darwin shares the POSIX shape, Windows reaches
// the same order through the console handler (real-binary E2E covers
// the whole path on each platform).
#+build linux

package tests

import "core:testing"
import "core:time"

import lm "core:sys/linux"

import "src:platform"

@(test)
platform_stop_signal_bridge :: proc(t: ^testing.T) {
	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)
	defer platform.token_destroy(root, context.allocator)
	defer platform.reset_stop_signals()

	ok := platform.install_stop_signals(root, context.allocator)
	testing.expect(t, ok, "handler registration must succeed")
	if !ok {
		return
	}

	lm.kill(lm.getpid(), .SIGTERM)
	fired := false
	deadline := platform.mono_ms() + 2000
	for platform.mono_ms() < deadline {
		if platform.token_is_fired(root) {
			fired = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, fired, "SIGTERM must fire the root token within the watch slice")
}

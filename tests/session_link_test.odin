// Tests for src/session link publication: the parent link (stream, conn,
// reader thread) must publish as one unit under parent_mu, so a shutdown
// that begins mid-connect can never observe a half-published link and free
// it under the live reader.
package tests

import "core:os"
import "core:sync"
import "core:testing"
import "src:platform"
import "src:session"

@(test)
in_process_connect_after_shutdown_leaves_no_link :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "aubade-link-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, false)
	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)

	a := new(session.App, context.allocator)
	a^ = {
		allocator    = context.allocator,
		cancel_alloc = context.allocator,
		home         = tmp,
		clock        = clock,
		root         = root,
	}
	a.cfg = session.default_config()
	a.cfg.project_root = tmp
	a.cfg.is_in_process = true

	// Fire the root first — "shutdown began before the link was built".
	// start_in_process_daemon must refuse to publish anything and retire
	// every resource it created on the way (the tracking allocator flags
	// whatever escapes).
	platform.token_fire(a.root, .Shutdown)
	testing.expect(t, !session.start_in_process_daemon(a), "connect must fail with the root fired")
	testing.expect(t, a.parent == nil, "conn leaked into the app")
	testing.expect(t, a.parent_stream == nil, "stream leaked into the app")
	testing.expect(t, a.parent_reader_thread == nil, "reader thread leaked into the app")
	testing.expect(t, a.daemon == nil && a.daemon_thread == nil, "daemon leaked into the app")
	testing.expect(t, a.parent_endpoint == nil && a.daemon_endpoint == nil, "endpoints leaked into the app")

	// token_destroy frees the token itself; nothing else to release.
	platform.token_destroy(root, context.allocator)
	free(clock, context.allocator)
	_ = os.remove_all(tmp)
	delete(tmp)
	free(a, context.allocator)
}

// GivenUp is a backoff state, not a terminal one: after the parent is lost
// and a reconnect round fails, the heartbeat must skip beats only until the
// backoff elapses, then claim the reconnect again (with the spawn budget
// restored) and return to Live — a daemon that comes back must not leave
// the child stripped of its service-backed tools forever.
@(test)
given_up_state_recovers_after_backoff :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "aubade-givenup-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	// The daemon home is its own temp tree: the shadow snapshot repository
	// must sit outside the project root, exactly like production.
	home, herr := os.make_directory_temp("", "aubade-givenup-home-", context.allocator)
	if herr != nil {
		testing.fail_now(t, "home temp dir failed")
	}

	clock := new(platform.Clock, context.allocator)
	// Real clock by necessity: the jsonrpc pending-wait layer counts
	// deadlines on the process monotonic clock, so a virtual clock makes
	// send_hello time out instantly. The backoff expiry is driven below by
	// editing parent_retry_at, not by sleeping.
	platform.clock_init(clock, false)
	root := new(platform.Cancel_Token, context.allocator)
	platform.token_init_root(root)

	a := new(session.App, context.allocator)
	a^ = {
		allocator    = context.allocator,
		cancel_alloc = context.allocator,
		home         = home,
		clock        = clock,
		root         = root,
	}
	a.cfg = session.default_config()
	a.cfg.project_root = tmp
	a.cfg.is_in_process = true

	if !session.start_in_process_daemon(a) {
		testing.fail_now(t, "in-process daemon failed to start")
	}
	testing.expect(t, a.parent_state == .Live, "expected Live after startup")

	// A failed reconnect round: the link stays published but the state moves
	// to GivenUp with the backoff armed (exactly what mark_given_up does).
	session.mark_given_up(a)
	testing.expect(t, a.parent_state == .GivenUp, "expected GivenUp after a failed round")

	// Within the backoff window a beat must be a no-op.
	session.beat_once(a)
	testing.expect(t, a.parent_state == .GivenUp, "beat during backoff must not reconnect")

	// Past the backoff the same beat claims the reconnect and recovers.
	// Single-threaded here (no heartbeat thread): moving the deadline is
	// the whole concurrency story.
	a.parent_retry_at -= session.PARENT_RETRY_BACKOFF_MS + 1
	session.beat_once(a)
	testing.expect(t, a.parent_state == .Live, "beat after backoff must reconnect")
	testing.expect(t, a.daemon != nil, "reconnect must rebuild the in-process daemon")

	// Shutdown order, as the real shutdown path does it: retire the link
	// first — the daemon does not exit while a child connection is alive —
	// then stop the daemon. The dispatch host's published svc_conn copy
	// must be withdrawn by the same teardown: a dispatch_call whose
	// register lands after the registry drain re-reads that field at task
	// start, and a stale conn pointer is a use-after-free on the link the
	// teardown destroys.
	sync.mutex_lock(&a.dispatch.mu)
	published := a.parent
	a.dispatch.svc_conn = published
	sync.mutex_unlock(&a.dispatch.mu)
	session.teardown_parent_link(a)
	testing.expect(t, a.dispatch.svc_conn == nil, "teardown must withdraw the dispatch svc_conn copy")
	session.stop_in_process_daemon(a)
	platform.token_destroy(root, context.allocator)
	free(clock, context.allocator)
	_ = os.remove_all(tmp)
	delete(tmp)
	_ = os.remove_all(home)
	delete(home)
	free(a, context.allocator)
}

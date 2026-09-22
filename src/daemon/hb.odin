// Heartbeat liveness: the monitor thread ticks on the injected clock (real
// in production, virtual in tests), declares silent children dead after K
// misses, reaps drained ones, and fires the daemon root when no live
// children remain past the grace window. Liveness is entirely in-memory
// plus the svc.ping round trip — no on-disk heartbeat file.
package daemon

import "core:sync"
import "src:jsonrpc"
import "src:platform"

// hb_loop is the monitor thread body: tick, sleep, repeat.
hb_loop :: proc(d: ^Daemon) {
	interval := d.cfg.hb_ping_ms
	if interval <= 0 {
		interval = DEFAULT_PING_MS
	}
	for !platform.token_is_fired(d.root) {
		sleep_interval(d, interval)
		if platform.token_is_fired(d.root) {
			break
		}
		hb_tick(d, platform.clock_now(d.cfg.clock))
	}
}

// sleep_interval waits through the injected clock in short slices: the
// monitor's join sits on the daemon's shutdown path, so a fired root
// must be observed by the next checkpoint instead of after a whole
// interval. The virtual test clock advances time explicitly either way.
sleep_interval :: proc(d: ^Daemon, ms: i64) {
	platform.clock_wait_sliced_until(d.cfg.clock, d.root, platform.clock_now(d.cfg.clock) + ms)
}

// A connection that never completes hello (a spawn probe's dial, a port
// scan) is reaped after this window — a genuine child hellos immediately
// after connect, so the margin is orders of magnitude.
HELLO_WINDOW_MS :: i64(5_000)

// hb_tick is the pure-ish liveness step, directly callable from tests
// (with the virtual clock advanced between calls). Under children_mu it
// only claims state transitions (Live->Draining for the dead, Closed
// leaving the list); the token fires and stream/conn teardown run after
// the unlock, for the same reason as in child_gone: conn_close can wait
// unboundedly on a writer to a dead peer, and children_mu must stay
// quick (every svc handler takes it).
hb_tick :: proc(d: ^Daemon, now_ms: i64) {
	to_close: [dynamic]^Child
	defer delete(to_close)
	to_fire: [dynamic]^Child
	defer delete(to_fire)

	sync.mutex_lock(&d.children_mu)

	// Only authenticated children count toward liveness: a probe dial must
	// neither delay the childless-grace shutdown nor keep the daemon alive.
	live := 0
	i := 0
	for i < len(d.children) {
		if platform.token_is_fired(d.root) {
			break
		}
		child := d.children[i]
		switch child.state {
		case .Live:
			// Dead when EITHER criterion trips: N consecutive missed
			// heartbeats, or the full silence window since the last
			// receive. A tick past the ping interval with no receive
			// counts as one miss; any receive resets the streak.
			idle := now_ms - child.last_seen_ms
			if idle > d.cfg.hb_ping_ms {
				child.misses += 1
			} else {
				child.misses = 0
			}
			if !child.is_hello_seen && idle > HELLO_WINDOW_MS {
				// Never authenticated: a probe, not a session.
				child.state = .Draining
				append(&to_fire, child)
			} else if child.misses >= d.cfg.hb_misses || idle > d.cfg.hb_timeout_ms {
				child.state = .Draining
				append(&to_fire, child)
			}
		case .Draining:
			// Outstanding requests finish on the pool; the last task (or
			// the pump thread at stream end) flips the state to Closed.
		case .Closed:
		}
		if child.state == .Closed {
			// Closed children leave the list here, under children_mu;
			// the teardown itself runs after the unlock — close_child
			// joins the reader/pump threads, whose exit paths take this
			// same mutex and would deadlock against a held lock.
			ordered_remove(&d.children, i)
			append(&to_close, child)
			continue
		}
		if child.is_hello_seen {
			live += 1
		}
		i += 1
	}

	fire_root := false
	if live == 0 && !platform.token_is_fired(d.root) {
		if d.cfg.grace_ms <= 0 {
			// A zero grace window means "no window": shut down on the first
			// childless tick instead of arming a deadline one tick late.
			fire_root = true
		} else if d.grace_deadline_ms == 0 {
			d.grace_deadline_ms = now_ms + d.cfg.grace_ms
		} else if now_ms >= d.grace_deadline_ms {
			fire_root = true
		}
	} else {
		d.grace_deadline_ms = 0
	}

	sync.mutex_unlock(&d.children_mu)

	declare_dead_batch(to_fire[:])
	if fire_root {
		platform.token_fire(d.root, .Shutdown)
	}
	for child in to_close {
		close_child(d, child)
	}
}

// declare_dead_batch fires each child token (.Session_Gone propagates to
// every derived request token), closes the stream to unblock the reader,
// and closes the conn. The Live->Draining claim already happened under
// children_mu (hb_tick); everything here is idempotent, so racing the
// reader thread's child_gone on the same child is safe.
declare_dead_batch :: proc(to_fire: []^Child) {
	for child in to_fire {
		platform.token_fire(child.token, .Session_Gone)
		child.stream.close(child.stream)
		jsonrpc.conn_close(child.conn)
	}
}

// touch_child records a ping. Returns false when the child is unknown or
// no longer live (late pings during Draining are ignored).
touch_child :: proc(d: ^Daemon, conn_id: int, now_ms: i64) -> bool {
	sync.mutex_lock(&d.children_mu)
	for child in d.children {
		if child.id == conn_id {
			if child.state == .Live {
				child.last_seen_ms = now_ms
				child.misses = 0
				sync.mutex_unlock(&d.children_mu)
				return true
			}
			sync.mutex_unlock(&d.children_mu)
			return false
		}
	}
	sync.mutex_unlock(&d.children_mu)
	return false
}

// begin_drain handles svc.bye: no new work, outstanding requests finish.
begin_drain :: proc(d: ^Daemon, conn_id: int) {
	sync.mutex_lock(&d.children_mu)
	for child in d.children {
		if child.id == conn_id && child.state == .Live {
			child.state = .Draining
			break
		}
	}
	sync.mutex_unlock(&d.children_mu)
}

// cancel_call fires the inflight tokens for svc.cancel — every slot
// registered under the id, because a peer reusing one id runs several
// requests under it. The fire happens under the registry mutex and the
// entries are left in place: each request's release path
// (daemon_token_release) removes and destroys its own token, so a fire
// either happens-before that destroy or finds nothing.
cancel_call :: proc(d: ^Daemon, conn_id: int, call_id: i64) {
	child := find_child(d, conn_id)
	if child == nil {
		return
	}
	sync.mutex_lock(&child.mu)
	if entry, found := child.inflight[call_id]; found && entry != nil {
		for token in entry.tokens {
			if token != nil {
				platform.token_fire(token, .Cancelled)
			}
		}
	}
	sync.mutex_unlock(&child.mu)
}

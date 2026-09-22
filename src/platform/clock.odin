// Monotonic time: real clock access + the injectable virtual clock used by
// deterministic tests. Liveness, deadlines, and TTLs only ever see this
// monotonic domain (never wall time).
package platform

import "core:mem"
import "core:sync"
import "core:time"

// Real monotonic milliseconds since an arbitrary epoch (process boot order
// is fine; only differences are meaningful).
mono_ms :: proc() -> i64 {
	return mono_ns() / 1_000_000
}

// Virtual clock: tests advance it explicitly instead of sleeping. The same
// procs serve the production clock, which reads mono_ms().
Clock :: struct {
	now_ms:    i64,           // guarded by mutex
	virtual:   bool,          // true: advance() drives time; false: now() reads the real clock
	mu:        sync.Mutex,
	cond:      sync.Cond,     // virtual only: clock_wait blocks until advance() crosses its target
	timers:    [dynamic]^Timer,
	allocator: mem.Allocator, // timer structs and the timer list (cross-thread)
}

Timer :: struct {
	at_ms:    i64,
	is_armed: bool,
	fire:     proc(data: rawptr),
	data:     rawptr,
}

clock_init :: proc(c: ^Clock, virtual: bool, a := context.allocator) {
	c^ = {virtual = virtual, allocator = a}
}

clock_now :: proc(c: ^Clock) -> i64 {
	if c.virtual {
		sync.mutex_lock(&c.mu)
		n := c.now_ms
		sync.mutex_unlock(&c.mu)
		return n
	}
	return mono_ms()
}

// clock_wait sleeps for ms through the clock: real clocks sleep; virtual
// clocks block until an advance() moves time past the target, so injected-
// clock code paths run unchanged in tests and production.
clock_wait :: proc(c: ^Clock, ms: i64) {
	if ms <= 0 {
		return
	}
	if !c.virtual {
		time.sleep(time.Duration(ms * 1_000_000))
		return
	}
	sync.mutex_lock(&c.mu)
	target := c.now_ms + ms
	for c.now_ms < target {
		sync.cond_wait(&c.cond, &c.mu)
	}
	sync.mutex_unlock(&c.mu)
}

// clock_wait_sliced_until parks until the absolute deadline_ms on the
// clock, waiting in ≤250 ms slices with token checks between them: a
// fired token must be observed by the next checkpoint, not after the
// whole span — the waiting thread's join is typically on a shutdown
// path. Deadline-shaped, not duration-shaped: a clock that jumps forward
// (one big virtual advance, or an NTP step on a real clock) ends the
// wait at the next slice boundary instead of sleeping through time that
// never elapses on its own. Returns true when the deadline was reached,
// false when the token fired first (nil token waits the full span).
WAIT_SLICE_MS :: i64(250)

clock_wait_sliced_until :: proc(c: ^Clock, token: ^Cancel_Token, deadline_ms: i64) -> bool {
	for {
		if token != nil && token_is_fired(token) {
			return false
		}
		now := clock_now(c)
		if now >= deadline_ms {
			return true
		}
		slice := deadline_ms - now
		if slice > WAIT_SLICE_MS {
			slice = WAIT_SLICE_MS
		}
		clock_wait(c, slice)
	}
}

clock_timer_add :: proc(c: ^Clock, at_ms: i64, fire: proc(rawptr), data: rawptr) -> ^Timer {
	t := new(Timer, c.allocator)
	t^ = {at_ms = at_ms, is_armed = true, fire = fire, data = data}
	sync.mutex_lock(&c.mu)
	// The list is made on the clock's allocator at first use and carries it
	// from then on: growth here and the delete in clock_destroy go through
	// the stored allocator, whatever the calling thread's context happens
	// to be.
	if cap(c.timers) == 0 {
		c.timers = make([dynamic]^Timer, 0, 4, c.allocator)
	}
	append(&c.timers, t)
	sync.mutex_unlock(&c.mu)
	return t
}

// Ownership rule: a timer is freed exactly once, by whichever side removes
// it from the timer list — cancel when it finds the timer there, the firing
// side when it detaches the timer into its due list. A cancel that finds
// nothing frees nothing and returns false: a fire pass owns the timer and
// will invoke t.fire after the clock mutex was already released, so callers
// must wait for that fire (e.g. token_wait on the token the timer fires)
// before destroying anything the fire touches — the fire has not
// necessarily started yet when the cancel observes the empty list.
clock_timer_cancel :: proc(c: ^Clock, t: ^Timer) -> (freed: bool) {
	found := false
	sync.mutex_lock(&c.mu)
	for i := 0; i < len(c.timers); i += 1 {
		if c.timers[i] == t {
			ordered_remove(&c.timers, i)
			found = true
			break
		}
	}
	sync.mutex_unlock(&c.mu)
	if found {
		free(t, c.allocator)
	}
	return found
}

// detach_due_locked requires c.mu held; moves due timers out of the
// list, transferring ownership (fire + free) to the caller.
detach_due_locked :: proc(c: ^Clock, now: i64) -> [dynamic]^Timer {
	// Made on the owner allocator so the fire pass that receives the value
	// deletes it through its stored allocator on any thread.
	due := make([dynamic]^Timer, 0, 4, c.allocator)
	for t in c.timers {
		if t.is_armed && t.at_ms <= now {
			t.is_armed = false
			append(&due, t)
		}
	}
	// Disarm before firing so handlers may cancel or re-arm freely.
	for i := 0; i < len(c.timers); {
		if !c.timers[i].is_armed {
			ordered_remove(&c.timers, i)
		} else {
			i += 1
		}
	}
	return due
}

fire_and_free :: proc(c: ^Clock, due: [dynamic]^Timer) {
	for t in due {
		t.fire(t.data)
		free(t, c.allocator)
	}
	delete(due)
}

// Advance the virtual clock by ms and fire due timers on the calling
// thread. No effect on the real clock.
clock_advance :: proc(c: ^Clock, ms: i64) {
	if !c.virtual {
		return
	}
	sync.mutex_lock(&c.mu)
	c.now_ms += ms
	sync.cond_broadcast(&c.cond) // wake clock_wait sleepers whose target passed
	due := detach_due_locked(c, c.now_ms)
	sync.mutex_unlock(&c.mu)
	fire_and_free(c, due)
}

// clock_fire_due fires real-clock timers whose deadline has passed (virtual
// clocks fire through advance() only). Production runs this from a ticker
// thread; the detach rule makes concurrent fire passes safe.
clock_fire_due :: proc(c: ^Clock) {
	if c.virtual {
		return
	}
	now := mono_ms()
	sync.mutex_lock(&c.mu)
	due := detach_due_locked(c, now)
	sync.mutex_unlock(&c.mu)
	fire_and_free(c, due)
}

// Teardown-only, but still under the mutex: nothing may add or detach
// timers while the list is being walked and freed.
clock_destroy :: proc(c: ^Clock) {
	sync.mutex_lock(&c.mu)
	for t in c.timers {
		free(t, c.allocator)
	}
	delete(c.timers)
	sync.mutex_unlock(&c.mu)
	c^ = {}
}

// ---------------------------------------------------------------------------
// Production timer pump. Real-clock timers need a thread that periodically
// fires what came due; virtual clocks (tests) never start one — tests
// advance time themselves.
// ---------------------------------------------------------------------------

Clock_Ticker :: struct {
	clock:   ^Clock,
	token:   ^Cancel_Token,
	tick_ms: i64,
}

// clock_ticker_entry pumps a real clock until the token fires. The clock
// owner starts it on a joinable thread and joins it before clock_destroy.
clock_ticker_entry :: proc(data: rawptr) {
	t := cast(^Clock_Ticker)data
	for !token_is_fired(t.token) {
		clock_fire_due(t.clock)
		clock_wait(t.clock, t.tick_ms)
	}
	clock_fire_due(t.clock)
}

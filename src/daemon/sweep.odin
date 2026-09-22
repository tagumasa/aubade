// Daily symbol-cache hygiene. The design schedule runs sweep_expired at
// parent startup AND once a day on the injected clock — without the
// recurring pass a long-lived daemon never trims expired rows or the
// row cap between restarts. The thread shares the db handle safely
// (transaction spans serialize through the store's transaction mutex —
// the FULLMUTEX open serializes individual C calls only) and its waits
// are sliced so a fired root is observed by the next checkpoint.
package daemon

import "src:platform"
import "src:store"
import "src:util"

SWEEP_INTERVAL_MS :: i64(24 * 60 * 60 * 1000)

// sweep_loop is the sweeper thread body: wait one interval, sweep, repeat.
// is_sweep_armed is set once the first deadline is anchored, so tests can
// advance the virtual clock afterwards without racing the anchor.
sweep_loop :: proc(d: ^Daemon) {
	next := platform.clock_now(d.cfg.clock) + SWEEP_INTERVAL_MS
	d.is_sweep_armed = true
	for !platform.token_is_fired(d.root) {
		if !platform.clock_wait_sliced_until(d.cfg.clock, d.root, next) {
			return
		}
		if platform.token_is_fired(d.root) {
			return
		}
		sweep_tick(d)
		// Loop-iteration temp reset (the dispatch/worker threads' idiom):
		// the sweep calls store, whose error strings are temp scratch —
		// without the reset they would accumulate for the daemon's life.
		free_all(context.temp_allocator)
		next += SWEEP_INTERVAL_MS
	}
}

// sweep_tick is the sweep step on its own, directly callable from tests
// (the virtual clock advances the interval between calls).
sweep_tick :: proc(d: ^Daemon) {
	if d.db == nil {
		return
	}
	_ = store.sweep_expired(d.db, platform.clock_now(d.cfg.clock), store.SYMBOL_CACHE_ROW_CAP)
	if terr := store.freelist_trim(d.db); terr != nil {
		util.log_warning("sweep: freelist trim failed; the next daily tick retries")
	}
}

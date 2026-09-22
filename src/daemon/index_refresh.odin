// Periodic incremental index discovery. Aubade-mediated edits refresh
// rows immediately, but out-of-band changes (an agent's own file writes,
// git checkout, scripts) had no proactive path into the index: new files
// and newly introduced names stayed invisible until some operation lazily
// parsed them. This loop is the hygiene floor of the fix: every interval
// it runs the incremental crawl — an mtime/size fingerprint walk that
// skips unchanged files (store/file_stat.odin), re-indexes changed and
// new ones, and purges vanished paths. The latency-sensitive half is the
// on-miss hook in symbol_find (svc_project.odin), which triggers the same
// walk when an answer would otherwise be empty; with both in place the
// interval is a background floor, and its exact value does not gate
// freshness. Like the sweeper and the warm-up, the thread shares the db
// handle safely (transaction spans serialize through the store's
// transaction mutex).
package daemon

import "base:intrinsics"
import "core:fmt"
import "core:strings"

import "src:platform"
import "src:svc"
import "src:util"

INDEX_REFRESH_INTERVAL_MS :: i64(60_000)

// The on-miss hook's hammer guard: a burst of finds for a name that
// genuinely does not exist triggers at most one walk per window — a
// completed walk means the index already reflects everything observable
// at that moment, so an immediate miss right after it is real.
INDEX_REFRESH_MIN_GAP_MS :: i64(2_000)

index_refresh_thread_entry :: proc(data: rawptr) {
	index_refresh_loop(cast(^Daemon)data)
}

// index_refresh_loop is the discovery thread body: wait one interval,
// walk, repeat — the sweeper's shape. is_index_refresh_armed is set once
// the first deadline is anchored, so tests can advance the virtual clock
// afterwards without racing the anchor.
index_refresh_loop :: proc(d: ^Daemon) {
	next := platform.clock_now(d.cfg.clock) + INDEX_REFRESH_INTERVAL_MS
	d.is_index_refresh_armed = true
	for !platform.token_is_fired(d.root) {
		if !platform.clock_wait_sliced_until(d.cfg.clock, d.root, next) {
			return
		}
		if platform.token_is_fired(d.root) {
			return
		}
		index_refresh_tick(d)
		// Loop-iteration temp reset (the sweeper's idiom): the walk calls
		// store and svc, whose scratch lives on temp — without the reset
		// it would accumulate for the daemon's life.
		free_all(context.temp_allocator)
		next += INDEX_REFRESH_INTERVAL_MS
	}
}

// index_refresh_tick runs one incremental discovery walk, directly
// callable from tests (no clock dependency inside the tick itself).
// Skips entirely when the in-flight claim is held — the on-miss hook may
// already be walking on a request thread.
index_refresh_tick :: proc(d: ^Daemon) {
	if !index_refresh_claim(d) {
		return
	}
	defer index_refresh_release(d)
	index_refresh_walk(d, d.root)
	// Loop-side temp reset (the sweeper's idiom): the walk's scratch dies
	// here instead of accumulating for the daemon's life.
	free_all(context.temp_allocator)
}

// index_refresh_claim acquires the single-walk claim (atomic_exchange:
// only a caller that observed false holds it). The loop takes it without
// a gap check — its deadline IS the gap; the on-miss hook checks
// index_refresh_due first.
index_refresh_claim :: proc(d: ^Daemon) -> bool {
	was := intrinsics.atomic_exchange(&d.index_refresh_in_flight, true)
	return !was
}

index_refresh_release :: proc(d: ^Daemon) {
	// Monotonic timestamp first: a concurrent on-miss caller reading it
	// during the flag's release must see the walk as already finished,
	// never as about-to-finish.
	intrinsics.atomic_store_explicit(&d.index_refresh_last_ms, platform.clock_now(d.cfg.clock), .Release)
	intrinsics.atomic_store_explicit(&d.index_refresh_in_flight, false, .Release)
}

// index_refresh_due reports whether an on-miss walk may start: at least
// MIN_GAP since the last completed walk (monotonic clock), and no walk in
// flight. last_ms == 0 is the never-walked state — a fresh daemon must
// serve its first miss immediately (a virtual test clock sits at 0 until
// advanced, so 0 cannot double as a real timestamp).
index_refresh_due :: proc(d: ^Daemon) -> bool {
	if intrinsics.atomic_load_explicit(&d.index_refresh_in_flight, .Acquire) {
		return false
	}
	last := intrinsics.atomic_load_explicit(&d.index_refresh_last_ms, .Acquire)
	if last == 0 {
		return true
	}
	return platform.clock_now(d.cfg.clock)-last >= INDEX_REFRESH_MIN_GAP_MS
}

// index_refresh_walk is the shared walk body (claim already held): the
// whole-project incremental crawl with the same ignore and deny inputs
// the warm-up uses. Failure is logged, not escalated — the next tick or
// the next on-miss retries. The one-line log fires only when the walk
// changed something, so an idle project stays silent. Scratch lands on
// the CALLER's context.temp_allocator — the walk must never free_all a
// frame it does not own (the loop resets its own; the on-miss caller's
// request arena resets at its normal boundary). `token` is the
// cancellation the walk obeys per entry: the loop's root token, or the
// triggering request's token on the on-miss path (a client that went
// away must not pay for a walk it will never see).
index_refresh_walk :: proc(d: ^Daemon, token: ^platform.Cancel_Token) {
	if d.db == nil || d.ts == nil {
		return
	}
	stats: svc.Crawl_Stats
	ignore := svc.ignore_config_load(d.cfg.project_root, d.cfg.home, context.temp_allocator)
	err := svc.ts_source_crawl(d.ts, "", &stats, ignore, &d.file_safety.deny_list, context.temp_allocator, token)
	// Release before returning: the spec's PCRE2 code lives outside the
	// temp allocator, everything else in it dies wholesale with its
	// owner's reset.
	svc.spec_release_c_side(ignore.extra)
	if err != nil {
		if !stats.cancelled {
			util.log_warning(
				strings.concatenate(
					{"index refresh: crawl failed; retrying on the next tick or miss: ", platform.err_message(err)},
				),
			)
		}
		return
	}
	if stats.files_indexed > 0 || stats.paths_purged > 0 {
		util.log_info(
			fmt.aprintf(
				"index refresh: %d files re-indexed, %d unchanged, %d purged (%d failed)",
				stats.files_indexed,
				stats.files_unchanged,
				stats.paths_purged,
				stats.files_failed,
				allocator = context.temp_allocator,
			),
		)
	}
}

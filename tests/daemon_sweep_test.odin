// The daily symbol-cache sweeper: a minimal daemon (virtual clock, root
// token, db — no sockets, no children) drives the real sweep_loop thread.
// One row written at virtual t=0 expires at t=24h; the loop's first tick
// (SWEEP_INTERVAL_MS) must physically delete it — the count view makes
// the deletion observable, since reads refuse expired rows either way.
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:thread"
import "core:time"

import "src:daemon"
import "src:platform"
import "src:store"

sweep_loop_test_entry :: proc(data: rawptr) {
	d := cast(^daemon.Daemon)data
	daemon.sweep_loop(d)
}

@(test)
daemon_daily_sweep_fires :: proc(t: ^testing.T) {
	tmp, terr := os.make_directory_temp("", "aubade-sweep-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		os.remove_all(tmp)
		delete(tmp, context.allocator)
	}

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true) // virtual: the test advances time
	defer {
		platform.clock_destroy(clock)
		free(clock, context.allocator)
	}

	db_path, _ := filepath.join([]string{tmp, "test.db"}, context.allocator)
	defer delete(db_path, context.allocator)
	// The sweeper thread and this thread both allocate through the db's
	// stored allocator (statement caches, error strings); the raw
	// tracking allocator is single-threaded, so the db rides a wrapped
	// one.
	ma: mem.Mutex_Allocator
	mem.mutex_allocator_init(&ma, context.allocator)
	ca := mem.mutex_allocator(&ma)
	db, oerr := store.db_open(db_path, ca)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	defer store.db_close(db)

	names := []store.Symbol_Name_Row{{name = "S", kind = "Struct", line = 1, parent = ""}}
	werr := store.write_symbol_index(db, "a.go", "h", "go", names, []u8{1}, 0)
	testing.expectf(t, werr == nil, "write: %v", werr)
	count, cerr := store.symbol_cache_count(db)
	testing.expectf(t, cerr == nil && count == 1, "seeded row visible (%v, %d)", cerr, count)

	root: platform.Cancel_Token
	platform.token_init_root(&root)

	d := new(daemon.Daemon, ca)
	defer free(d, ca)
	d^ = {}
	d.cfg = daemon.default_config(tmp, tmp, clock)
	d.root = &root
	d.db = db

	sweeper := thread.create_and_start_with_data(d, sweep_loop_test_entry, self_cleanup = false, name = "sweep-test")
	defer {
		// Fire, then advance: the sweeper waits on the virtual clock's
		// cond in 250 ms slices, and only an advance (not the fire) wakes
		// a cond_wait — without it the join below blocks forever.
		platform.token_fire(&root, .Shutdown)
		platform.clock_advance(clock, daemon.SWEEP_INTERVAL_MS * 2)
		thread.join(sweeper)
		free(sweeper, context.allocator)
	}

	// t=24h+1s: the row's TTL (24h from t=0) has passed AND the loop's
	// first interval is due — the tick must physically drop the row.
	// Wait for the sweeper to anchor its first deadline before advancing
	// (anchoring after the advance would push the sweep a full interval
	// out); the settle poll is the suite's real-clock wait shape.
	armed := false
	for _ in 0..<500 {
		if d.is_sweep_armed {
			armed = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, armed, "sweeper never anchored its first deadline")
	platform.clock_advance(clock, daemon.SWEEP_INTERVAL_MS + 1_000)

	// The sweeper is a real thread settling after the advance.
	gone := false
	for _ in 0..<500 {
		count, cerr = store.symbol_cache_count(db)
		if cerr == nil && count == 0 {
			gone = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, gone, "daily sweep did not drop the expired row")
}

// The store's transaction spans (single-file write, batch write, event
// append) and the sweep's deletes must serialize on one connection:
// SQLite transactions are connection-global, so unserialized spans
// interleave into duplicate-BEGIN errors or one thread's rows committing
// with another's transaction. The hammer drives every span from real
// threads and asserts zero failures plus exact row visibility afterwards.
package tests

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"

import "src:platform"
import "src:store"
import "src:util"

HAMMER_THREADS :: 4
HAMMER_ITERS :: 25

Hammer_Shared :: struct {
	db:      ^store.DB,
	failures: int,
	mu:       sync.Mutex,
}

Hammer_Worker :: struct {
	shared: ^Hammer_Shared,
	idx:    int,
}

hammer_fail :: proc(s: ^Hammer_Shared) {
	sync.mutex_lock(&s.mu)
	s.failures += 1
	sync.mutex_unlock(&s.mu)
}

hammer_worker_entry :: proc(data: rawptr) {
	w := cast(^Hammer_Worker)data
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	aa := context.temp_allocator

	path := strings.concatenate({"src/f", util.int_to_dec(w.idx, aa), ".go"}, aa)
	sym := strings.concatenate({"Sym_", util.int_to_dec(w.idx, aa)}, aa)
	for iter in 0..<HAMMER_ITERS {
		hash := strings.concatenate({"h", util.int_to_dec(iter, aa)}, aa)
		names := [1]store.Symbol_Name_Row{{name = sym, kind = "Struct", line = cast(i64)iter, parent = ""}}
		payload := [3]u8{1, 2, 3}
		if err := store.write_symbol_index(w.shared.db, path, hash, "go", names[:], payload[:], 1000); err != nil {
			hammer_fail(w.shared)
		}

		ba := strings.concatenate({"src/b", util.int_to_dec(w.idx, aa), "a.go"}, aa)
		bb := strings.concatenate({"src/b", util.int_to_dec(w.idx, aa), "b.go"}, aa)
		names_a := [1]store.Symbol_Name_Row{{name = sym, kind = "Method", line = cast(i64)iter, parent = ""}}
		names_b := [1]store.Symbol_Name_Row{{name = sym, kind = "Field", line = cast(i64)iter, parent = ""}}
		writes := [2]store.Symbol_Write{
			{path = ba, hash = hash, language = "go", names = names_a[:], payload = payload[:]},
			{path = bb, hash = hash, language = "go", names = names_b[:], payload = payload[:]},
		}
		if err := store.write_symbol_index_batch(w.shared.db, writes[:], 1000); err != nil {
			hammer_fail(w.shared)
		}

		row: store.Event_Row
		row.uid = strings.concatenate({"uid-", util.int_to_dec(w.idx, aa), "-", util.int_to_dec(iter, aa)}, aa)
		row.ts = 1000
		row.origin = "hammer"
		row.kind = "test"
		row.version = 1
		row.payload = "{}"
		if err := store.events_append(w.shared.db, &row); err != nil {
			hammer_fail(w.shared)
		}
	}
	// now_ms=2000 expires nothing (rows carry the 24 h TTL from t=1000)
	// and max_rows=0 skips the cap: the sweep only exercises its own
	// transaction-serialized statements against the concurrent writers.
	if err := store.sweep_expired(w.shared.db, 2000, 0); err != nil {
		hammer_fail(w.shared)
	}
}

@(test)
store_transaction_spans_serialize :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-hammer-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	defer store.db_close(db)

	shared := new(Hammer_Shared, context.allocator)
	defer free(shared, context.allocator)
	shared^ = {db = db}

	// Fixed stack arrays: the worker pointers handed to the threads must
	// stay put for the join.
	workers: [HAMMER_THREADS]Hammer_Worker
	handles: [HAMMER_THREADS]^thread.Thread
	for i in 0..<HAMMER_THREADS {
		workers[i] = {shared = shared, idx = i}
		handles[i] = thread.create_and_start_with_data(
			&workers[i],
			hammer_worker_entry,
			self_cleanup = false,
			name = "store-hammer",
		)
	}
	for h in handles {
		thread.join(h)
		free(h, context.allocator)
	}

	testing.expect_value(t, shared.failures, 0)

	// One current-hash row per file: three paths per thread.
	count, cerr := store.symbol_cache_count(db)
	testing.expectf(t, cerr == nil, "count: %v", cerr)
	testing.expect_value(t, count, HAMMER_THREADS * 3)

	for i in 0..<HAMMER_THREADS {
		sym := strings.concatenate({"sym_", util.int_to_dec(i, context.temp_allocator)}, context.temp_allocator)
		rows, lerr := store.symbol_names_lookup(db, sym, context.allocator)
		testing.expectf(t, lerr == nil, "lookup %d: %v", i, lerr)
		if lerr != nil {
			continue
		}
		testing.expect_value(t, len(rows), 3)
		store.symbol_names_rows_destroy(rows, context.allocator)
	}
}

// The kv writers serialize against the transaction spans for the same
// reason the spans serialize against each other: an unlocked kv_put
// executes inside whatever transaction is open on the connection, so a
// put that interleaves a doomed events_append is rolled back after
// kv_put already returned success. The rollback racer keeps appending a
// duplicate uid (conflict -> ROLLBACK every time) while the kv racer
// flips a marker; the marker's final read must still show a written
// value, never the pre-seeded one.
KV_RACE_ITERS :: 300

Hammer_Kv_Shared :: struct {
	db:      ^store.DB,
	failures: int,
	mu:       sync.Mutex,
}

kv_race_fail :: proc(s: ^Hammer_Kv_Shared) {
	sync.mutex_lock(&s.mu)
	s.failures += 1
	sync.mutex_unlock(&s.mu)
}

kv_rollback_racer_entry :: proc(data: rawptr) {
	s := cast(^Hammer_Kv_Shared)data
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	row: store.Event_Row
	row.uid = "kv-race-dup"
	row.ts = 1000
	row.origin = "hammer"
	row.kind = "test"
	row.version = 1
	row.payload = "{}"
	for _ in 0..<KV_RACE_ITERS {
		err := store.events_append(s.db, &row)
		// The pre-seeded uid conflicts every time: the typed duplicate
		// rejection (.Invalid is the duplicate vocabulary here) plus the
		// rollback it rides are both expected.
		if err == nil || platform.err_kind(err) != .Invalid {
			kv_race_fail(s)
		}
	}
}

kv_put_racer_entry :: proc(data: rawptr) {
	s := cast(^Hammer_Kv_Shared)data
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	context.temp_allocator = mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	value := "v1"
	for _ in 0..<KV_RACE_ITERS {
		if err := store.kv_put(s.db, "kv-race-marker", value); err != nil {
			kv_race_fail(s)
		}
		if value == "v1" {
			value = "v2"
		} else {
			value = "v1"
		}
	}
}

@(test)
kv_put_survives_concurrent_transaction_rollback :: proc(t: ^testing.T) {
	dir, derr := os.make_directory_temp("", "aubade-kvrace-", context.allocator)
	if derr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	defer store.db_close(db)

	seed: store.Event_Row
	seed.uid = "kv-race-dup"
	seed.ts = 900
	seed.origin = "hammer"
	seed.kind = "test"
	seed.version = 1
	seed.payload = "{}"
	if serr := store.events_append(db, &seed); serr != nil {
		testing.expectf(t, false, "seed append: %v", serr)
		return
	}
	if kerr := store.kv_put(db, "kv-race-marker", "seed"); kerr != nil {
		testing.expectf(t, false, "seed put: %v", kerr)
		return
	}

	shared := new(Hammer_Kv_Shared, context.allocator)
	defer free(shared, context.allocator)
	shared^ = {db = db}

	handles: [2]^thread.Thread
	handles[0] = thread.create_and_start_with_data(
		shared, kv_rollback_racer_entry, self_cleanup = false, name = "kv-race-rollback",
	)
	handles[1] = thread.create_and_start_with_data(
		shared, kv_put_racer_entry, self_cleanup = false, name = "kv-race-put",
	)
	for h in handles {
		thread.join(h)
		free(h, context.allocator)
	}

	testing.expect_value(t, shared.failures, 0)
	value, found, gerr := store.kv_get(db, "kv-race-marker", context.allocator)
	testing.expectf(t, gerr == nil, "kv_get: %v", gerr)
	testing.expect_value(t, found, true)
	// "seed" can only come back if every racer put was rolled back with a
	// doomed transaction — the exact interleaving tx_mu now prevents.
	testing.expectf(t, value == "v1" || value == "v2", "marker lost a written value: %q", value)
	delete(value, context.allocator)
}

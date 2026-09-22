// The out-of-band discovery pass: files created or edited by
// tools outside aubade must become visible to symbol_find — through the
// periodic refresh tick AND, without waiting for any interval, through
// the on-miss walk symbol_find itself triggers on an empty answer. Drives
// the real daemon handler against a minimal daemon (TS source + store db
// + project root — no sockets, no language servers), with the virtual
// clock controlling the loop's interval and the on-miss min-gap.
package tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import "src:daemon"
import "src:jsonutil"
import "src:platform"
import "src:store"
import "src:svc"

Index_Refresh_Fixture :: struct {
	d:     ^daemon.Daemon,
	root:  string,
	clock: ^platform.Clock,
	token: platform.Cancel_Token,
	// The loop test's thread and the main thread both allocate through
	// the db and ts allocators; the raw tracking allocator is
	// single-threaded, so the shared objects ride this wrapped one.
	ma:    mem.Mutex_Allocator,
}

index_refresh_fixture :: proc(t: ^testing.T) -> ^Index_Refresh_Fixture {
	root, rerr := os.make_directory_temp("", "aubade-iref-", context.allocator)
	if rerr != nil {
		testing.fail_now(t, "temp root failed")
	}
	f := new(Index_Refresh_Fixture, context.allocator)
	f.root = root
	mem.mutex_allocator_init(&f.ma, context.allocator)
	ca := mem.mutex_allocator(&f.ma)

	rel := "warm_target.go"
	abs, _ := filepath.join([]string{root, rel}, context.temp_allocator)
	body := "package warm\n\ntype Warm_Target struct{ X int }\n"
	if werr := os.write_entire_file_from_bytes(abs, transmute([]u8)body); werr != nil {
		testing.fail_now(t, "fixture file write failed")
	}

	db_path, _ := filepath.join([]string{root, "test.db"}, context.allocator)
	db, oerr := store.db_open(db_path, ca)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	delete(db_path, context.allocator)

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true) // virtual: the tests advance time

	d := new(daemon.Daemon, ca)
	d^ = {}
	d.cfg = daemon.default_config(root, root, clock)
	d.db = db
	ts := new(svc.TS_Source, ca)
	svc.ts_source_init(ts, root, db, clock, ca)
	d.ts = ts
	platform.token_init_root(&f.token)
	d.root = &f.token
	f.d = d
	f.clock = clock
	return f
}

index_refresh_teardown :: proc(f: ^Index_Refresh_Fixture) {
	ca := mem.mutex_allocator(&f.ma)
	if f.d.ts != nil {
		svc.ts_source_destroy(f.d.ts)
		free(f.d.ts, ca)
	}
	store.db_close(f.d.db)
	platform.clock_destroy(f.clock)
	free(f.clock, context.allocator)
	_ = os.remove_all(f.root)
	delete(f.root, context.allocator)
	free(f.d, ca)
	free(f, context.allocator)
}

refresh_write_external :: proc(t: ^testing.T, f: ^Index_Refresh_Fixture, rel: string, body: string) {
	abs, _ := filepath.join([]string{f.root, rel}, context.temp_allocator)
	if werr := os.write_entire_file_from_bytes(abs, transmute([]u8)body); werr != nil {
		testing.fail_now(t, "external write failed")
	}
}

refresh_ctx :: proc(f: ^Index_Refresh_Fixture, a: mem.Allocator) -> svc.Svc_Ctx {
	return {allocator = a, token = &f.token, user = f.d}
}

refresh_find :: proc(t: ^testing.T, f: ^Index_Refresh_Fixture, name: string, a: mem.Allocator) -> (matches: json.Value, count: int) {
	body := strings.concatenate({"{\"name\": \"", name, "\"}"}, a)
	params, _ := json.parse_bytes(transmute([]u8)body, spec = .JSON, parse_integers = true, allocator = a)
	ctx := refresh_ctx(f, a)
	result, err := daemon.handle_symbol_find(&ctx, params)
	if err != nil {
		return nil, -1
	}
	m, ok := jsonutil.obj_get(result, "matches")
	if !ok {
		return nil, -2
	}
	return m, json_array_len(m)
}

@(test)
refresh_tick_discovers_external_new_file :: proc(t: ^testing.T) {
	f := index_refresh_fixture(t)
	defer index_refresh_teardown(f)

	daemon.index_refresh_tick(f.d)
	warm, _ := store.symbol_names_lookup(f.d.db, "Warm_Target", context.temp_allocator)
	testing.expect(t, len(warm) == 1)
	store.symbol_names_rows_destroy(warm, context.temp_allocator)

	// An external tool creates a brand-new file; the periodic tick must
	// index it (manifestation 1, background path).
	refresh_write_external(t, f, "external.go", "package ext\n\nfunc External_New() {}\n")
	daemon.index_refresh_tick(f.d)

	rows, lerr := store.symbol_names_lookup(f.d.db, "External_New", context.allocator)
	testing.expectf(t, lerr == nil, "lookup: %v", lerr)
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 1)
}

@(test)
refresh_on_miss_discovers_external_new_file :: proc(t: ^testing.T) {
	f := index_refresh_fixture(t)
	defer index_refresh_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	daemon.index_refresh_tick(f.d)

	// External write, then an IMMEDIATE find — no tick, no clock advance:
	// the on-miss walk inside symbol_find must close the gap (manifestation
	// 1, latency path).
	refresh_write_external(t, f, "instant.go", "package instant\n\nfunc Instant_Symbol() {}\n")
	_, count := refresh_find(t, f, "Instant_Symbol", a)
	testing.expectf(t, count == 1, "expected the on-miss walk to find Instant_Symbol, got %d", count)
}

@(test)
refresh_on_miss_discovers_renamed_symbol :: proc(t: ^testing.T) {
	f := index_refresh_fixture(t)
	defer index_refresh_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	refresh_write_external(t, f, "rename_me.go", "package rm\n\nfunc Old_Name() {}\n")
	daemon.index_refresh_tick(f.d)

	// Out-of-band edit renames the symbol: the old name must stop
	// answering and the new one become findable in the same query that
	// first misses (manifestation 2).
	refresh_write_external(t, f, "rename_me.go", "package rm\n\nfunc Brand_New_Name() {}\n")

	_, new_count := refresh_find(t, f, "Brand_New_Name", a)
	testing.expectf(t, new_count == 1, "new name findable via on-miss walk, got %d", new_count)

	_, old_count := refresh_find(t, f, "Old_Name", a)
	testing.expectf(t, old_count == 0, "old name must stop answering, got %d", old_count)
}

@(test)
refresh_min_gap_guards_repeat_misses :: proc(t: ^testing.T) {
	f := index_refresh_fixture(t)
	defer index_refresh_teardown(f)

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	a := mem.dynamic_arena_allocator(&arena)

	// Give the virtual clock real uptime first: a completed walk at t=0
	// would stamp last_ms=0, which the due() sentinel reads as
	// never-walked (a monotonic clock in production is never 0).
	platform.clock_advance(f.clock, 100_000)

	testing.expect(t, daemon.index_refresh_due(f.d), "no walk yet: due")

	// A miss (with a walk) sets the last-walk stamp on the virtual clock.
	_, count := refresh_find(t, f, "Does_Not_Exist", a)
	testing.expect_value(t, count, 0)
	testing.expect(t, !daemon.index_refresh_due(f.d), "min-gap must hold right after a completed walk")

	// The gap is monotonic-clock based: only an advance releases it.
	platform.clock_advance(f.clock, daemon.INDEX_REFRESH_MIN_GAP_MS + 1)
	testing.expect(t, daemon.index_refresh_due(f.d), "gap elapsed: due again")

	// A held claim suppresses a tick entirely: while a walk is in flight,
	// the background tick must not start a second one.
	testing.expect(t, daemon.index_refresh_claim(f.d), "claim from idle")
	testing.expect(t, !daemon.index_refresh_due(f.d), "in-flight walk is not due")
	refresh_write_external(t, f, "claimed.go", "package c\n\nfunc Claimed() {}\n")
	daemon.index_refresh_tick(f.d) // suppressed: claim held
	rows, _ := store.symbol_names_lookup(f.d.db, "Claimed", context.allocator)
	testing.expect_value(t, len(rows), 0)
	store.symbol_names_rows_destroy(rows, context.allocator)

	daemon.index_refresh_release(f.d)
	daemon.index_refresh_tick(f.d)
	rows, _ = store.symbol_names_lookup(f.d.db, "Claimed", context.allocator)
	testing.expect_value(t, len(rows), 1)
	store.symbol_names_rows_destroy(rows, context.allocator)
}

@(test)
refresh_tick_purges_vanished_file :: proc(t: ^testing.T) {
	f := index_refresh_fixture(t)
	defer index_refresh_teardown(f)

	refresh_write_external(t, f, "doomed.go", "package doomed\n\nfunc Doomed() {}\n")
	daemon.index_refresh_tick(f.d)
	rows, _ := store.symbol_names_lookup(f.d.db, "Doomed", context.allocator)
	testing.expect_value(t, len(rows), 1)
	store.symbol_names_rows_destroy(rows, context.allocator)

	gone, _ := filepath.join([]string{f.root, "doomed.go"}, context.temp_allocator)
	_ = os.remove(gone)
	daemon.index_refresh_tick(f.d)

	rows, _ = store.symbol_names_lookup(f.d.db, "Doomed", context.allocator)
	testing.expect_value(t, len(rows), 0)
	store.symbol_names_rows_destroy(rows, context.allocator)
}

index_refresh_loop_test_entry :: proc(data: rawptr) {
	daemon.index_refresh_loop(cast(^daemon.Daemon)data)
}

@(test)
refresh_loop_fires_on_interval :: proc(t: ^testing.T) {
	f := index_refresh_fixture(t)
	defer index_refresh_teardown(f)

	looper := thread.create_and_start_with_data(f.d, index_refresh_loop_test_entry, self_cleanup = false, name = "iref-test")
	defer {
		// Fire, then advance: the loop waits on the virtual clock's cond
		// in slices, and only an advance (not the fire) wakes a cond_wait.
		platform.token_fire(&f.token, .Shutdown)
		platform.clock_advance(f.clock, daemon.INDEX_REFRESH_INTERVAL_MS * 2)
		thread.join(looper)
		free(looper, context.allocator)
	}

	armed := false
	for _ in 0..<500 {
		if f.d.is_index_refresh_armed {
			armed = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, armed, "refresh loop never anchored its first deadline")

	// The file appears AFTER the loop anchored its deadline; the first
	// interval tick must pick it up.
	refresh_write_external(t, f, "looped.go", "package looped\n\nfunc Looped_Symbol() {}\n")
	platform.clock_advance(f.clock, daemon.INDEX_REFRESH_INTERVAL_MS + 1_000)

	found := false
	for _ in 0..<500 {
		rows, lerr := store.symbol_names_lookup(f.d.db, "Looped_Symbol", context.allocator)
		if lerr == nil && len(rows) > 0 {
			store.symbol_names_rows_destroy(rows, context.allocator)
			found = true
			break
		}
		if lerr == nil {
			store.symbol_names_rows_destroy(rows, context.allocator)
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, found, "the interval tick never discovered the external file")
}

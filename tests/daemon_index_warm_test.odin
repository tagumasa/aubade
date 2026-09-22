// The startup index warm-up: a fresh store answers name search empty until
// the crawl populates it (nothing on the daemon side ever ran the
// crawl; the CLI verbs were the only entry points). Drives the real
// warm-up step synchronously against a minimal daemon (TS source + store db
// + project root — no sockets, no language servers).
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import "src:daemon"
import "src:platform"
import "src:store"
import "src:svc"

Index_Warm_Fixture :: struct {
	d:     ^daemon.Daemon,
	root:  string,
	clock: ^platform.Clock,
	token: platform.Cancel_Token,
}

index_warm_fixture :: proc(t: ^testing.T) -> ^Index_Warm_Fixture {
	root, rerr := os.make_directory_temp("", "aubade-warm-", context.allocator)
	if rerr != nil {
		testing.fail_now(t, "temp root failed")
	}
	f := new(Index_Warm_Fixture, context.allocator)
	f.root = root

	rel := "warm_target.go"
	abs, _ := filepath.join([]string{root, rel}, context.temp_allocator)
	body := "package warm\n\ntype Warm_Target struct{ X int }\n\nfunc Warm_Helper() {}\n"
	if werr := os.write_entire_file_from_bytes(abs, transmute([]u8)body); werr != nil {
		testing.fail_now(t, "fixture file write failed")
	}

	db_path, _ := filepath.join([]string{root, "test.db"}, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	delete(db_path, context.allocator)

	clock := new(platform.Clock, context.allocator)
	platform.clock_init(clock, true) // virtual: nothing here waits

	d := new(daemon.Daemon, context.allocator)
	d^ = {}
	d.cfg = daemon.default_config(root, root, clock)
	d.db = db
	ts := new(svc.TS_Source, context.allocator)
	svc.ts_source_init(ts, root, db, clock, context.allocator)
	d.ts = ts
	platform.token_init_root(&f.token)
	d.root = &f.token
	f.d = d
	f.clock = clock
	return f
}

index_warm_teardown :: proc(f: ^Index_Warm_Fixture) {
	if f.d.ts != nil {
		svc.ts_source_destroy(f.d.ts)
		free(f.d.ts, context.allocator)
	}
	store.db_close(f.d.db)
	platform.clock_destroy(f.clock)
	free(f.clock, context.allocator)
	_ = os.remove_all(f.root)
	delete(f.root, context.allocator)
	free(f.d, context.allocator)
	free(f, context.allocator)
}

index_warm_find :: proc(t: ^testing.T, f: ^Index_Warm_Fixture, name: string) -> int {
	rows, lerr := store.symbol_names_lookup(f.d.db, name, context.temp_allocator)
	if lerr != nil {
		return -1
	}
	return len(rows)
}

@(test)
index_warm_populates_cold_store :: proc(t: ^testing.T) {
	f := index_warm_fixture(t)
	defer index_warm_teardown(f)

	count, cerr := store.symbol_cache_count(f.d.db)
	testing.expectf(t, cerr == nil && count == 0, "fresh store starts empty (%v, %d)", cerr, count)

	crawled := daemon.index_warm_run(f.d)
	testing.expect(t, crawled, "cold store must trigger the warm-up crawl")

	count, cerr = store.symbol_cache_count(f.d.db)
	testing.expectf(t, cerr == nil && count > 0, "crawl filled the index (%v, %d)", cerr, count)
	testing.expect(t, index_warm_find(t, f, "Warm_Target") == 1, "untouched file's symbol is findable after warm-up")
	testing.expect(t, index_warm_find(t, f, "Warm_Helper") == 1, "untouched file's second symbol is findable after warm-up")
}

@(test)
index_warm_crawls_partially_touched_store :: proc(t: ^testing.T) {
	f := index_warm_fixture(t)
	defer index_warm_teardown(f)

	// The cold-start shape: symbol_list touched one unrelated file, so the
	// index holds rows but the crawl never ran — most files stay missing.
	names := [1]store.Symbol_Name_Row{{name = "Touched", kind = "Struct", line = 1, parent = ""}}
	werr := store.write_symbol_index(f.d.db, "other.go", "h1", "go", names[:], []u8{1}, 1000)
	testing.expectf(t, werr == nil, "seed: %v", werr)

	crawled := daemon.index_warm_run(f.d)
	testing.expect(t, crawled, "a never-crawled store must warm up despite partial rows")
	testing.expect(t, index_warm_find(t, f, "Warm_Target") == 1, "crawl filled the untouched file")
}

@(test)
index_warm_skips_warmed_store :: proc(t: ^testing.T) {
	f := index_warm_fixture(t)
	defer index_warm_teardown(f)

	testing.expect(t, daemon.index_warm_run(f.d), "first run crawls")
	before, _ := store.symbol_cache_count(f.d.db)

	crawled := daemon.index_warm_run(f.d)
	testing.expect(t, !crawled, "a crawled store with live rows must skip the warm-up")
	after, _ := store.symbol_cache_count(f.d.db)
	testing.expect(t, after == before, "skip left the index untouched")
}

@(test)
index_warm_reruns_when_swept_empty :: proc(t: ^testing.T) {
	f := index_warm_fixture(t)
	defer index_warm_teardown(f)

	testing.expect(t, daemon.index_warm_run(f.d), "first run crawls")
	derr := store.delete_symbol_path(f.d.db, "warm_target.go")
	testing.expectf(t, derr == nil, "delete: %v", derr)
	count, _ := store.symbol_cache_count(f.d.db)
	testing.expect(t, count == 0, "fixture rows swept away")

	crawled := daemon.index_warm_run(f.d)
	testing.expect(t, crawled, "a swept-empty index must re-warm despite the marker")
	testing.expect(t, index_warm_find(t, f, "Warm_Target") == 1, "re-warm restored the symbol")
}

@(test)
index_warm_skips_without_ts_source :: proc(t: ^testing.T) {
	f := index_warm_fixture(t)
	defer index_warm_teardown(f)

	svc.ts_source_destroy(f.d.ts)
	free(f.d.ts, context.allocator)
	f.d.ts = nil

	crawled := daemon.index_warm_run(f.d)
	testing.expect(t, !crawled, "no TS source means no warm-up attempt")
}

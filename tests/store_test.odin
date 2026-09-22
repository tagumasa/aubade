// Tests for src/store (SQLite): open with pragmas and schema, kv round
// trip, the single-transaction symbol index writer (L0 rows + L1 payload +
// old-hash cleanup), expiry, and the sweep. Uses a throwaway directory.
package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "src:platform"
import "src:store"
import "src:util"

@(test)
store_kv_roundtrip :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	// Missing key reads as absent, not error.
	value, found, gerr := store.kv_get(db, "onboarding.done", context.allocator)
	testing.expectf(t, gerr == nil, "get: %v", gerr)
	testing.expect(t, !found)
	testing.expect_value(t, value, "")

	perr := store.kv_put(db, "onboarding.done", "2026-08-20")
	testing.expectf(t, perr == nil, "put: %v", perr)
	value, found, gerr = store.kv_get(db, "onboarding.done", context.allocator)
	testing.expectf(t, gerr == nil, "get: %v", gerr)
	testing.expect(t, found)
	testing.expect_value(t, value, "2026-08-20")
	delete(value)

	// Upsert replaces.
	perr = store.kv_put(db, "onboarding.done", "later")
	testing.expectf(t, perr == nil, "put2: %v", perr)
	value, found, gerr = store.kv_get(db, "onboarding.done", context.allocator)
	testing.expect(t, found)
	testing.expect_value(t, value, "later")
	delete(value)
}

@(test)
store_write_symbol_index :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	names := []store.Symbol_Name_Row{
		{name = "Server", kind = "Struct", line = 3, parent = ""},
		{name = "Start",  kind = "Method", line = 7, parent = "Server"},
	}
	payload := []u8{1, 0, 0, 0, 42, 43}
	werr := store.write_symbol_index(db, "src/server.go", "hash1", "go", names, payload, 1000)
	testing.expectf(t, werr == nil, "write: %v", werr)

	// L0 lookup is case-insensitive and carries file + position.
	rows, lerr := store.symbol_names_lookup(db, "server", context.allocator)
	testing.expectf(t, lerr == nil, "lookup: %v", lerr)
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].name, "Server")
		testing.expect_value(t, rows[0].kind, "Struct")
		testing.expect_value(t, rows[0].path, "src/server.go")
		testing.expect_value(t, rows[0].hash, "hash1")
		testing.expect_value(t, rows[0].line, 3)
	}

	// L1 payload round trip while unexpired.
	got, lang, found, gerr := store.symbol_cache_get(db, "src/server.go", "hash1", 2000, context.allocator)
	testing.expectf(t, gerr == nil, "cache get: %v", gerr)
	testing.expect(t, found)
	testing.expect_value(t, lang, "go")
	testing.expect_value(t, len(got), 6)
	if len(got) == 6 {
		testing.expect_value(t, got[4], 42)
		testing.expect_value(t, got[5], 43)
	}
	delete(lang)
	if got != nil {
		delete(got)
	}

	// A newer hash for the same path replaces the old rows atomically.
	names2 := []store.Symbol_Name_Row{
		{name = "Server", kind = "Struct", line = 4, parent = ""},
	}
	werr = store.write_symbol_index(db, "src/server.go", "hash2", "go", names2, payload, 1000)
	testing.expectf(t, werr == nil, "write2: %v", werr)

	rows2, lerr2 := store.symbol_names_lookup(db, "Start", context.allocator)
	testing.expectf(t, lerr2 == nil, "lookup2: %v", lerr2)
	defer store.symbol_names_rows_destroy(rows2, context.allocator)
	testing.expect_value(t, len(rows2), 0)

	_, _, found2, _ := store.symbol_cache_get(db, "src/server.go", "hash1", 2000, context.allocator)
	testing.expect(t, !found2)

	// Expiry hides entries whose TTL has passed.
	_, _, found3, gerr3 := store.symbol_cache_get(db, "src/server.go", "hash2", 1000 + store.DEFAULT_TTL_MS + 1, context.allocator)
	testing.expectf(t, gerr3 == nil, "cache get3: %v", gerr3)
	testing.expect(t, !found3)
}

@(test)
store_write_symbol_index_same_hash_is_idempotent :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	names := []store.Symbol_Name_Row{
		{name = "Server", kind = "Struct", line = 3, parent = ""},
		{name = "Start",  kind = "Method", line = 7, parent = "Server"},
	}
	payload := []u8{1, 0, 0, 0}

	// Crawls rewrite unchanged files with the same (path, hash): the rows
	// must be replaced, not appended.
	for pass in 0..<3 {
		werr := store.write_symbol_index(db, "src/server.go", "hash1", "go", names, payload, i64(1000 + pass))
		testing.expectf(t, werr == nil, "write pass %d: %v", pass, werr)
	}

	probe_names := []string{"Server", "Start"}
	for name in probe_names {
		rows, lerr := store.symbol_names_lookup(db, name, context.allocator)
		testing.expectf(t, lerr == nil, "lookup %s: %v", name, lerr)
		defer store.symbol_names_rows_destroy(rows, context.allocator)
		testing.expectf(t, len(rows) == 1, "%s duplicated: %d rows", name, len(rows))
	}
}


@(test)
store_sweep_expired :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	payload := []u8{9}
	names := []store.Symbol_Name_Row{{name = "A", kind = "Struct", line = 1, parent = ""}}
	testing.expect(t, store.write_symbol_index(db, "a.go", "h1", "go", names, payload, 0, 100) == nil)
	testing.expect(t, store.write_symbol_index(db, "b.go", "h2", "go", names, payload, 10_000) == nil)

	// At now=5000 the first entry (100 ms TTL) is expired; the sweep drops
	// it and its name rows, keeping the fresh one.
	serr := store.sweep_expired(db, 5000, 0)
	testing.expectf(t, serr == nil, "sweep: %v", serr)

	rows, lerr := store.symbol_names_lookup(db, "A", context.allocator)
	testing.expectf(t, lerr == nil, "lookup: %v", lerr)
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].path, "b.go")
	}

	_, _, found, _ := store.symbol_cache_get(db, "a.go", "h1", 5000, context.allocator)
	testing.expect(t, !found)
	got_b, lang_b, found2, _ := store.symbol_cache_get(db, "b.go", "h2", 5000, context.allocator)
	testing.expect(t, found2)
	if lang_b != "" {
		delete(lang_b)
	}
	if got_b != nil {
		delete(got_b)
	}
}

@(test)
store_events_append_and_read :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	// Appended out of uid order: the read must come back in uid order.
	rows_in := []store.Event_Row{
		{uid = "00000000000003e8-00000000000000ff", ts = 1000, origin = "aabbcc01", kind = "incident.created",   version = 1, payload = "{\"v\":1}"},
		{uid = "00000000000003e7-00000000000000fe", ts = 999,  origin = "aabbcc01", kind = "sprint.started",     version = 1, payload = "{\"name\":\"s\"}"},
	}
	for i in 0..<len(rows_in) {
		aerr := store.events_append(db, &rows_in[i])
		testing.expectf(t, aerr == nil, "append %d: %v", i, aerr)
	}

	n, cerr := store.events_count(db)
	testing.expectf(t, cerr == nil, "count: %v", cerr)
	testing.expect_value(t, n, 2)

	rows, rerr := store.events_read_all(db, context.allocator)
	testing.expectf(t, rerr == nil, "read: %v", rerr)
	defer store.events_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {
		testing.expect(t, rows[0].uid == "00000000000003e7-00000000000000fe", "uid order")
		testing.expect_value(t, rows[0].ts, 999)
		testing.expect_value(t, rows[0].version, 1)
		testing.expect(t, rows[0].kind == "sprint.started")
		testing.expect(t, rows[0].payload == "{\"name\":\"s\"}")
		testing.expect(t, rows[1].kind == "incident.created")
		testing.expect(t, rows[1].origin == "aabbcc01")
	}
}

@(test)
store_events_duplicate_uid_rejected :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	row := store.Event_Row{
		uid = "000000000000000a-0000000000000001", ts = 5, origin = "aabbcc01",
		kind = "incident.created", version = 1, payload = "{}",
	}
	testing.expect(t, store.events_append(db, &row) == nil)

	// The same uid again is a typed .Invalid refusal, and nothing is written.
	aerr := store.events_append(db, &row)
	testing.expectf(t, aerr != nil, "duplicate must fail")
	kind: platform.Err_Kind
	switch e in aerr {
	case platform.Wrapped:      kind = e.kind
	case platform.Err_Kind:     kind = e
	}
	testing.expect_value(t, kind, platform.Err_Kind.Invalid)

	n, cerr := store.events_count(db)
	testing.expectf(t, cerr == nil, "count: %v", cerr)
	testing.expect_value(t, n, 1)
}

@(test)
store_events_batch_payload_fetch :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	// One full chunk (128) plus a padded remainder, so both chunk shapes run.
	total := store.EVENTS_FETCH_CHUNK + 2
	rows := make([]store.Event_Row, total, context.temp_allocator)
	uids := make([]string, total, context.temp_allocator)
	for i := 0; i < total; i += 1 {
		uids[i] = strings.concatenate({"evt-", util.int_to_dec(i, context.temp_allocator)}, context.temp_allocator)
		rows[i] = {
			uid     = uids[i],
			ts      = i64(i),
			origin  = "t",
			kind    = "incident.created",
			version = 1,
			payload = strings.concatenate({"{\"n\":", util.int_to_dec(i, context.temp_allocator), "}"}, context.temp_allocator),
		}
		aerr := store.events_append(db, &rows[i])
		testing.expectf(t, aerr == nil, "append %d: %v", i, aerr)
	}

	payloads, ferr := store.events_payloads_by_uids(db, uids, context.allocator)
	testing.expectf(t, ferr == nil, "batch fetch: %v", ferr)
	testing.expect_value(t, len(payloads), total)
	if p, ok := payloads[uids[0]]; ok {
		testing.expect_value(t, p, "{\"n\":0}")
	} else {
		testing.expectf(t, false, "first uid missing from batch result")
	}
	last_payload := strings.concatenate({"{\"n\":", util.int_to_dec(total - 1, context.temp_allocator), "}"}, context.temp_allocator)
	if p, ok := payloads[uids[total - 1]]; ok {
		testing.expect_value(t, p, last_payload)
	} else {
		testing.expectf(t, false, "last uid missing from batch result")
	}
	for uid, payload in payloads {
		_ = payload
		delete(uid, context.allocator)
		delete(payload, context.allocator)
	}
	delete(payloads)

	// A subset with a missing uid returns exactly the present rows.
	subset := []string{uids[5], "evt-missing", uids[77]}
	sub, serr := store.events_payloads_by_uids(db, subset, context.allocator)
	testing.expectf(t, serr == nil, "subset fetch: %v", serr)
	testing.expect_value(t, len(sub), 2)
	if p, ok := sub[uids[77]]; ok {
		testing.expect_value(t, p, "{\"n\":77}")
	} else {
		testing.expectf(t, false, "subset misses uid 77")
	}
	_, gone := sub["evt-missing"]
	testing.expect(t, !gone)
	for uid, payload in sub {
		_ = payload
		delete(uid, context.allocator)
		delete(payload, context.allocator)
	}
	delete(sub)

	// Equivalence with the single-uid path on a spot check.
	one, found, perr := store.event_payload_by_uid(db, uids[42], context.allocator)
	testing.expectf(t, perr == nil, "single fetch: %v", perr)
	testing.expect(t, found)
	testing.expect_value(t, one, "{\"n\":42}")
	delete(one, context.allocator)

	// An empty request is a no-op, not an error.
	empty, eerr := store.events_payloads_by_uids(db, nil, context.allocator)
	testing.expectf(t, eerr == nil, "empty fetch: %v", eerr)
	testing.expect_value(t, len(empty), 0)
	delete(empty)
}

@(test)
util_cache_bytes_and_pins :: proc(t: ^testing.T) {
	cost :: proc(v: []u8) -> int {
		return len(v)
	}
	release :: proc(v: []u8) {
		if v != nil {
			delete(v)
		}
	}

	c: util.Bounded_Cache(string, []u8)
	util.cache_init(&c, 10, context.allocator, release, 250, cost)
	defer util.cache_destroy(&c)

	// Every put hands the cache its own allocation (the cache owns values
	// and releases them on eviction).
	fresh_block :: proc() -> []u8 {
		b := make([]u8, 100, context.allocator)
		return b
	}
	keys := []string{"k1", "k2", "k3"}
	for key in keys {
		util.cache_put(&c, key, fresh_block())
	}
	// 300 bytes under a 250-byte cap: the oldest entry fell out.
	_, found := util.cache_get(&c, "k1")
	testing.expect(t, !found)
	_, found = util.cache_get(&c, "k3")
	testing.expect(t, found)

	// A pinned entry survives byte pressure that would otherwise evict it
	// (k2 is older than k3, but k2 is pinned and k3 is not).
	testing.expect(t, util.cache_pin(&c, "k2"))
	util.cache_put(&c, "k4", fresh_block())
	_, k2_found := util.cache_get(&c, "k2")
	_, k3_found := util.cache_get(&c, "k3")
	testing.expect(t, k2_found)
	testing.expect(t, !k3_found)
	testing.expect_value(t, util.cache_pinned_count(&c), 1)

	// Once unpinned, k2 is evictable again: the next two puts push it out
	// through the tail (k4 first, then the unpinned k2).
	util.cache_unpin(&c, "k2")
	testing.expect_value(t, util.cache_pinned_count(&c), 0)
	util.cache_put(&c, "k5", fresh_block())
	_, k4_found := util.cache_get(&c, "k4")
	testing.expect(t, !k4_found)
	util.cache_put(&c, "k6", fresh_block())
	_, k2_gone := util.cache_get(&c, "k2")
	testing.expect(t, !k2_gone)
}

@(test)
util_cache_put_charges_before_release :: proc(t: ^testing.T) {
	// Overwriting a key must charge the old value's bytes BEFORE the
	// release hook runs — afterwards byte_cost would read a dead value.
	Order_Probe :: struct {
		bytes:    int,
		released: bool,
	}
	cost :: proc(v: ^Order_Probe) -> int {
		if v.released {
			return 1 << 30 // sentinel: cost read after release
		}
		return v.bytes
	}
	release :: proc(v: ^Order_Probe) {
		v.released = true
	}

	c: util.Bounded_Cache(string, ^Order_Probe)
	util.cache_init(&c, 4, context.allocator, release, 1 << 20, cost)
	defer util.cache_destroy(&c)

	v1 := new(Order_Probe, context.temp_allocator)
	v1.bytes = 10
	util.cache_put(&c, "k", v1)
	v2 := new(Order_Probe, context.temp_allocator)
	v2.bytes = 20
	util.cache_put(&c, "k", v2)
	testing.expect(t, v1.released, "overwrite must release the old value")
	testing.expect_value(t, c.total_bytes, 20)
}

@(test)
store_open_failure_carries_sqlite_reason :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-openfail-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	// A file where a directory must be: sqlite cannot even create the
	// database, and the error must say why rather than a bare "open
	// failed".
	blocker, _ := filepath.join([]string{dir, "blocker"}, context.allocator)
	defer delete(blocker, context.allocator)
	fp, werr := os.open(blocker, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if werr != nil {
		testing.expectf(t, false, "blocker: %v", werr)
		return
	}
	os.close(fp)
	bad, _ := filepath.join([]string{blocker, "aubade.db"}, context.temp_allocator)

	_, oerr := store.db_open(bad, context.allocator)
	testing.expect(t, oerr != nil, "opening under a file must fail")
	if oerr != nil {
		msg := platform.err_message(oerr, context.temp_allocator)
		testing.expect(t, strings.contains(msg, "store: open failed: "), msg)
		testing.expect(t, len(msg) > len("store: open failed: "), msg)
	}
}

// --- Hygiene pragmas and freelist trim ---------------------------------------

// store_pragmas_pin_hygiene pins the open-time pragmas that bound the
// files a long-lived daemon leaves behind: the WAL must shrink back after
// a checkpoint spike (journal_size_limit) and dead index-churn pages must
// be returnable (auto_vacuum = INCREMENTAL, 2).
@(test)
store_pragmas_pin_hygiene :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	limit, lerr := store.pragma_int(db, "journal_size_limit")
	testing.expectf(t, lerr == nil, "journal_size_limit read: %v", lerr)
	testing.expect_value(t, limit, 8388608)
	mode, merr := store.pragma_int(db, "auto_vacuum")
	testing.expectf(t, merr == nil, "auto_vacuum read: %v", merr)
	testing.expect_value(t, mode, 2)
}

// store_freelist_trim_incremental: on an incremental store the trim hands
// dead pages back to the file system instead of stranding them at the
// churn high-water.
@(test)
store_freelist_trim_incremental :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "aubade-store-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, _ := filepath.join([]string{dir, "aubade.db"}, context.allocator)
	defer delete(db_path)

	db, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	defer store.db_close(db)

	// Churn: ~1.4 MB of kv rows, then gone — the emptied pages land on
	// the freelist. One row stays behind: the trim must not eat live
	// data.
	kerr := store.kv_put(db, "keep.me", "payload")
	testing.expectf(t, kerr == nil, "keep put: %v", kerr)
	big := strings.repeat("x", 8192, context.allocator)
	defer delete(big)
	for i in 0..<64 {
		key := util.int_to_dec(i, context.temp_allocator)
		perr := store.kv_put(db, strings.concatenate({"churn.", key}, context.temp_allocator), big)
		testing.expectf(t, perr == nil, "put %d: %v", i, perr)
	}
	for i in 0..<64 {
		key := util.int_to_dec(i, context.temp_allocator)
		derr := store.kv_delete(db, strings.concatenate({"churn.", key}, context.temp_allocator))
		testing.expectf(t, derr == nil, "delete %d: %v", i, derr)
	}

	before, gerr := store.pragma_int(db, "freelist_count")
	testing.expectf(t, gerr == nil, "freelist read: %v", gerr)
	testing.expectf(t, before > 0, "churn must leave dead pages, got %d", before)

	// Below the production threshold nothing runs; with the test's tiny
	// threshold the trim empties the freelist.
	terr := store.freelist_trim(db, 1 << 40)
	testing.expectf(t, terr == nil, "trim under threshold: %v", terr)
	mid, _ := store.pragma_int(db, "freelist_count")
	testing.expect_value(t, mid, before)
	terr = store.freelist_trim(db, 1)
	testing.expectf(t, terr == nil, "trim: %v", terr)
	after, aerr := store.pragma_int(db, "freelist_count")
	testing.expectf(t, aerr == nil, "freelist re-read: %v", aerr)
	testing.expect_value(t, after, 0)

	// The data survives the trim: the never-churned row is still found
	// with its bytes (the old probe read a key this test never wrote, so
	// its !found assertion could only pass).
	value, found, verr := store.kv_get(db, "keep.me", context.allocator)
	testing.expectf(t, verr == nil, "keep read: %v", verr)
	testing.expect(t, found, "the surviving row must still be found")
	testing.expect_value(t, value, "payload")
	delete(value, context.allocator)
}


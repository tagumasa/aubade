// Tests for the L1 parent-memory mirror: reads fill and serve from the
// mirror ahead of SQLite, expiry refuses to serve, the sweep and row-cap
// deletions drop mirrored keys with their rows, superseded hashes
// invalidate on write, and pre-wiring zero-length payloads never serve.
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:store"

mirror_test_open :: proc(t: ^testing.T) -> (db: ^store.DB, dir: string) {
	tmp, err := os.make_directory_temp("", "aubade-mirror-", context.allocator)
	if err != nil {
		testing.fail_now(t, "temp dir failed")
	}
	db_path, _ := filepath.join([]string{tmp, "aubade.db"}, context.allocator)
	defer delete(db_path)
	d, oerr := store.db_open(db_path, context.allocator)
	testing.expectf(t, oerr == nil, "open: %v", oerr)
	return d, tmp
}

mirror_test_close :: proc(db: ^store.DB, dir: string) {
	store.db_close(db)
	_ = os.remove_all(dir)
	delete(dir)
}

@(test)
store_mirror_serves_reads_and_expires :: proc(t: ^testing.T) {
	db, dir := mirror_test_open(t)
	defer mirror_test_close(db, dir)

	names := []store.Symbol_Name_Row{{name = "Server", kind = "Struct", line = 3, parent = ""}}
	payload := []u8{9, 8, 7}
	werr := store.write_symbol_index(db, "src/a.go", "h1", "go", names, payload, 1000)
	testing.expectf(t, werr == nil, "write: %v", werr)

	got, lang, found, rerr := store.symbol_cache_payload(db, "src/a.go", "h1", 1500, context.allocator)
	testing.expectf(t, rerr == nil, "read: %v", rerr)
	testing.expect(t, found, "payload readable")
	testing.expectf(t, lang == "go", "language %q", lang)
	testing.expectf(t, len(got) == 3 && got[0] == 9 && got[2] == 7, "payload bytes %v", got)
	delete(got)
	delete(lang)

	// Delete the SQLite row behind the mirror's back: the read still
	// serves, which proves the first read filled the mirror.
	derr := store.db_exec(db, "DELETE FROM symbol_cache;")
	testing.expectf(t, derr == nil, "raw delete: %v", derr)
	got2, lang2, found2, rerr2 := store.symbol_cache_payload(db, "src/a.go", "h1", 1500, context.allocator)
	testing.expectf(t, rerr2 == nil, "read2: %v", rerr2)
	testing.expect(t, found2, "mirror serves after the row is gone")
	if got2 != nil {
		delete(got2)
	}
	if lang2 != "" {
		delete(lang2)
	}

	// Past the TTL the entry refuses to serve.
	now_late := 1000 + store.DEFAULT_TTL_MS + 1
	_, _, found3, rerr3 := store.symbol_cache_payload(db, "src/a.go", "h1", now_late, context.allocator)
	testing.expectf(t, rerr3 == nil, "read3: %v", rerr3)
	testing.expect(t, !found3, "expired entry served")
}

@(test)
store_sweep_drops_mirror_entries :: proc(t: ^testing.T) {
	db, dir := mirror_test_open(t)
	defer mirror_test_close(db, dir)

	names := []store.Symbol_Name_Row{{name = "S", kind = "Struct", line = 1, parent = ""}}
	payload := []u8{1}
	werr := store.write_symbol_index(db, "p1.go", "h", "go", names, payload, 10_000)
	testing.expectf(t, werr == nil, "write p1: %v", werr)
	werr = store.write_symbol_index(db, "p2.go", "h", "go", names, payload, 11_000)
	testing.expectf(t, werr == nil, "write p2: %v", werr)
	werr = store.write_symbol_index(db, "p3.go", "h", "go", names, payload, 12_000)
	testing.expectf(t, werr == nil, "write p3: %v", werr)

	// The row cap keeps only the newest row; the two trimmed entries must
	// vanish from the mirror with their rows (a surviving mirror entry
	// would still serve — p1's TTL is far in the future).
	serr := store.sweep_expired(db, 13_000, 1)
	testing.expectf(t, serr == nil, "sweep: %v", serr)
	_, _, found1, _ := store.symbol_cache_payload(db, "p1.go", "h", 13_000, context.allocator)
	testing.expect(t, !found1, "p1 served after the cap sweep")
	_, _, found2, _ := store.symbol_cache_payload(db, "p2.go", "h", 13_000, context.allocator)
	testing.expect(t, !found2, "p2 served after the cap sweep")
	got3, lang3, found3, _ := store.symbol_cache_payload(db, "p3.go", "h", 13_000, context.allocator)
	testing.expect(t, found3, "newest row survived the cap sweep")
	if got3 != nil {
		delete(got3)
	}
	if lang3 != "" {
		delete(lang3)
	}

	// The TTL sweep removes the remainder end to end.
	serr2 := store.sweep_expired(db, 12_000 + store.DEFAULT_TTL_MS + 1, 0)
	testing.expectf(t, serr2 == nil, "sweep2: %v", serr2)
	_, _, found4, _ := store.symbol_cache_payload(db, "p3.go", "h", 12_000 + store.DEFAULT_TTL_MS + 1, context.allocator)
	testing.expect(t, !found4, "p3 served after the TTL sweep")
}

@(test)
store_write_invalidates_old_hash_mirror :: proc(t: ^testing.T) {
	db, dir := mirror_test_open(t)
	defer mirror_test_close(db, dir)

	names := []store.Symbol_Name_Row{{name = "S", kind = "Struct", line = 1, parent = ""}}
	werr := store.write_symbol_index(db, "old.go", "hA", "go", names, []u8{1}, 1000)
	testing.expectf(t, werr == nil, "write A: %v", werr)
	werr = store.write_symbol_index(db, "old.go", "hB", "go", names, []u8{2, 2}, 1100)
	testing.expectf(t, werr == nil, "write B: %v", werr)

	// The superseded hash must be gone from both layers — a surviving
	// mirror entry would still serve at now=1200 (its TTL is unexpired).
	_, _, found_a, _ := store.symbol_cache_payload(db, "old.go", "hA", 1200, context.allocator)
	testing.expect(t, !found_a, "old hash served after replacement")
	got_b, lang_b, found_b, _ := store.symbol_cache_payload(db, "old.go", "hB", 1200, context.allocator)
	testing.expect(t, found_b, "new hash missing")
	testing.expectf(t, len(got_b) == 2 && got_b[0] == 2, "payload B bytes %v", got_b)
	if got_b != nil {
		delete(got_b)
	}
	if lang_b != "" {
		delete(lang_b)
	}
}

@(test)
store_mirror_skips_empty_payloads :: proc(t: ^testing.T) {
	db, dir := mirror_test_open(t)
	defer mirror_test_close(db, dir)

	names := []store.Symbol_Name_Row{{name = "S", kind = "Struct", line = 1, parent = ""}}
	werr := store.write_symbol_index(db, "e.go", "hE", "go", names, nil, 1000)
	testing.expectf(t, werr == nil, "write: %v", werr)

	// Pre-wiring zero-length rows are not payloads: the read path misses
	// (and does not mirror them).
	_, _, found, rerr := store.symbol_cache_payload(db, "e.go", "hE", 1500, context.allocator)
	testing.expectf(t, rerr == nil, "read: %v", rerr)
	testing.expect(t, !found, "empty payload served")

	// The direct row reader still sees the row itself.
	raw, row_lang, row_found, _ := store.symbol_cache_get(db, "e.go", "hE", 1500, context.allocator)
	testing.expect(t, row_found, "row missing")
	testing.expectf(t, len(raw) == 0, "row payload %v", raw)
	if raw != nil {
		delete(raw)
	}
	if row_lang != "" {
		delete(row_lang)
	}
}

// The file_stat fingerprint tier: batched index writes record the disk
// fingerprint transactionally, get reads it back, has_path probes row
// liveness under a TTL, and the purge drops unseen paths together with
// their rows. An empty-names batch entry must replace a path's rows
// wholesale (the emptied-outline contract the incremental crawl relies
// on).
package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:platform"
import "src:store"

file_stat_open_db :: proc(t: ^testing.T) -> (string, ^store.DB) {
	dir, terr := os.make_directory_temp("", "aubade-fstat-", context.allocator)
	if terr != nil {
		testing.fail_now(t, "temp dir failed")
	}
	db_path, _ := filepath.join([]string{dir, "test.db"}, context.allocator)
	db, oerr := store.db_open(db_path, context.allocator)
	if oerr != nil {
		testing.fail_now(t, "db_open failed")
	}
	delete(db_path, context.allocator)
	return dir, db
}

file_stat_close_db :: proc(tmp: string, db: ^store.DB) {
	store.db_close(db)
	_ = os.remove_all(tmp)
	delete(tmp, context.allocator)
}

@(test)
file_stat_batch_records_fingerprints :: proc(t: ^testing.T) {
	tmp, db := file_stat_open_db(t)
	defer file_stat_close_db(tmp, db)

	writes := []store.Symbol_Write{
		{
			path = "a.go", hash = "ha", language = "go",
			names = []store.Symbol_Name_Row{{name = "A", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 111, size = 10,
		},
		{
			path = "b.go", hash = "hb", language = "go",
			names = []store.Symbol_Name_Row{{name = "B", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{2}, mtime_ns = 222, size = 20,
		},
	}
	err := store.write_symbol_index_batch(db, writes[:], 1000)
	testing.expectf(t, err == nil, "batch: %v", err)

	mtime, size, found, gerr := store.file_stat_get(db, "a.go")
	testing.expectf(t, gerr == nil, "get a: %v", gerr)
	testing.expect_value(t, found, true)
	testing.expect_value(t, mtime, 111)
	testing.expect_value(t, size, 10)

	mtime, size, found, gerr = store.file_stat_get(db, "b.go")
	testing.expectf(t, gerr == nil, "get b: %v", gerr)
	testing.expect_value(t, found, true)
	testing.expect_value(t, mtime, 222)
	testing.expect_value(t, size, 20)

	_, _, found, gerr = store.file_stat_get(db, "never.go")
	testing.expectf(t, gerr == nil, "get never: %v", gerr)
	testing.expect_value(t, found, false)

	// An upsert refreshes in place: the re-crawl of a changed file must
	// not accumulate stale generations.
	refresh := []store.Symbol_Write{
		{path = "a.go", hash = "ha2", language = "go", names = nil, payload = nil, mtime_ns = 333, size = 30},
	}
	err = store.write_symbol_index_batch(db, refresh[:], 2000)
	testing.expectf(t, err == nil, "refresh: %v", err)
	mtime, size, found, gerr = store.file_stat_get(db, "a.go")
	testing.expectf(t, gerr == nil, "get a2: %v", gerr)
	testing.expect_value(t, found, true)
	testing.expect_value(t, mtime, 333)
	testing.expect_value(t, size, 30)
}

@(test)
file_stat_purge_unseen_drops_rows_and_fingerprints :: proc(t: ^testing.T) {
	tmp, db := file_stat_open_db(t)
	defer file_stat_close_db(tmp, db)

	seen_path := "kept.go"
	writes := [3]store.Symbol_Write{
		{
			path = seen_path, hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Kept", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
		{
			path = "gone1.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Gone", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
		{
			path = "gone2.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Gone", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
	}
	err := store.write_symbol_index_batch(db, writes[:], 1000)
	testing.expectf(t, err == nil, "seed batch: %v", err)

	seen := make(map[u64]bool, 1, context.temp_allocator)
	defer delete(seen)
	seen[platform.path_hash64(seen_path)] = true
	purged, perr := store.file_stat_purge_unseen(db, seen, nil)
	testing.expectf(t, perr == nil, "purge: %v", perr)
	testing.expect_value(t, purged, 2)

	kept_rows, lerr := store.symbol_names_lookup(db, "Kept", context.allocator)
	testing.expectf(t, lerr == nil, "kept lookup: %v", lerr)
	defer store.symbol_names_rows_destroy(kept_rows, context.allocator)
	testing.expect_value(t, len(kept_rows), 1)

	gone_rows, gerr := store.symbol_names_lookup(db, "Gone", context.allocator)
	testing.expectf(t, gerr == nil, "gone lookup: %v", gerr)
	defer store.symbol_names_rows_destroy(gone_rows, context.allocator)
	testing.expect_value(t, len(gone_rows), 0)

	_, _, found, ferr := store.file_stat_get(db, "gone1.go")
	testing.expectf(t, ferr == nil, "gone fingerprint read: %v", ferr)
	testing.expect_value(t, found, false)
	_, _, found, ferr = store.file_stat_get(db, seen_path)
	testing.expectf(t, ferr == nil, "kept fingerprint read: %v", ferr)
	testing.expect_value(t, found, true)
}

@(test)
file_stat_purge_respects_keep_prefixes :: proc(t: ^testing.T) {
	tmp, db := file_stat_open_db(t)
	defer file_stat_close_db(tmp, db)

	writes := [4]store.Symbol_Write{
		{
			path = "keep.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Keep", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
		{
			path = "sub/keep.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Subkeep", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
		{
			path = "subx/gone.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Subgone", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
		{
			path = "gone.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "Gone", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 1, size = 1,
		},
	}
	err := store.write_symbol_index_batch(db, writes[:], 1000)
	testing.expectf(t, err == nil, "seed batch: %v", err)

	// The walk reached keep.go; "sub" is a subtree it could not enumerate.
	// Everything under "sub" stays; the component boundary holds —
	// "subx/gone.go" is NOT under "sub" and must purge.
	seen := make(map[u64]bool, 1, context.temp_allocator)
	defer delete(seen)
	seen[platform.path_hash64("keep.go")] = true
	purged, perr := store.file_stat_purge_unseen(db, seen, []string{"sub"})
	testing.expectf(t, perr == nil, "purge: %v", perr)
	testing.expect_value(t, purged, 2)

	subkeep, skerr := store.symbol_names_lookup(db, "Subkeep", context.allocator)
	testing.expectf(t, skerr == nil, "subkeep lookup: %v", skerr)
	defer store.symbol_names_rows_destroy(subkeep, context.allocator)
	testing.expect_value(t, len(subkeep), 1)

	subgone, sgerr := store.symbol_names_lookup(db, "Subgone", context.allocator)
	testing.expectf(t, sgerr == nil, "subgone lookup: %v", sgerr)
	defer store.symbol_names_rows_destroy(subgone, context.allocator)
	testing.expect_value(t, len(subgone), 0)

	_, _, found, ferr := store.file_stat_get(db, "sub/keep.go")
	testing.expectf(t, ferr == nil, "kept fingerprint read: %v", ferr)
	testing.expect_value(t, found, true)
	_, _, found, ferr = store.file_stat_get(db, "subx/gone.go")
	testing.expectf(t, ferr == nil, "boundary fingerprint read: %v", ferr)
	testing.expect_value(t, found, false)

	// The empty prefix — the project root itself could not be read —
	// keeps everything.
	none := make(map[u64]bool, 0, context.temp_allocator)
	defer delete(none)
	purged, perr = store.file_stat_purge_unseen(db, none, []string{""})
	testing.expectf(t, perr == nil, "root-keep purge: %v", perr)
	testing.expect_value(t, purged, 0)
}

@(test)
file_stat_empty_names_entry_replaces_rows :: proc(t: ^testing.T) {
	tmp, db := file_stat_open_db(t)
	defer file_stat_close_db(tmp, db)

	names := []store.Symbol_Name_Row{{name = "Old", kind = "Struct", line = 1, parent = ""}}
	err := store.write_symbol_index(db, "x.go", "h1", "go", names, []u8{1, 2}, 1000)
	testing.expectf(t, err == nil, "seed: %v", err)

	// The emptied-outline entry: same path, new hash, no names. The
	// transaction must drop the old rows and still record the
	// fingerprint — an emptied file stops answering AND does not
	// re-parse on every later pass.
	empty := []store.Symbol_Write{
		{path = "x.go", hash = "h2", language = "go", names = nil, payload = nil, mtime_ns = 9, size = 9},
	}
	err = store.write_symbol_index_batch(db, empty[:], 2000)
	testing.expectf(t, err == nil, "empty entry: %v", err)

	rows, lerr := store.symbol_names_lookup(db, "Old", context.allocator)
	testing.expectf(t, lerr == nil, "lookup: %v", lerr)
	defer store.symbol_names_rows_destroy(rows, context.allocator)
	testing.expect_value(t, len(rows), 0)

	has, herr := store.symbol_cache_has_path(db, "x.go", 2500)
	testing.expectf(t, herr == nil, "has_path: %v", herr)
	testing.expect_value(t, has, true)

	_, _, found, ferr := store.file_stat_get(db, "x.go")
	testing.expectf(t, ferr == nil, "fingerprint: %v", ferr)
	testing.expect_value(t, found, true)
}

@(test)
file_stat_has_path_respects_ttl :: proc(t: ^testing.T) {
	tmp, db := file_stat_open_db(t)
	defer file_stat_close_db(tmp, db)

	names := []store.Symbol_Name_Row{{name = "Ttl", kind = "Struct", line = 1, parent = ""}}
	err := store.write_symbol_index(db, "ttl.go", "h1", "go", names, []u8{1}, 1000, 100)
	testing.expectf(t, err == nil, "seed: %v", err)

	has, herr := store.symbol_cache_has_path(db, "ttl.go", 1050)
	testing.expectf(t, herr == nil, "before expiry: %v", herr)
	testing.expect_value(t, has, true)

	// Expired rows are not "live" even before the sweep physically drops
	// them: the incremental skip must re-parse a file whose rows aged
	// out, not skip it on the fingerprint alone.
	has, herr = store.symbol_cache_has_path(db, "ttl.go", 5000)
	testing.expectf(t, herr == nil, "after expiry: %v", herr)
	testing.expect_value(t, has, false)

	has, herr = store.symbol_cache_has_path(db, "absent.go", 5000)
	testing.expectf(t, herr == nil, "absent: %v", herr)
	testing.expect_value(t, has, false)
}

@(test)
fingerprint_skip_gates_on_stat_and_liveness :: proc(t: ^testing.T) {
	tmp, db := file_stat_open_db(t)
	defer file_stat_close_db(tmp, db)

	writes := [1]store.Symbol_Write{
		{
			path = "a.go", hash = "h1", language = "go",
			names = []store.Symbol_Name_Row{{name = "A", kind = "Struct", line = 1, parent = ""}},
			payload = []u8{1}, mtime_ns = 10, size = 5,
		},
	}
	err := store.write_symbol_index_batch(db, writes[:], 1000, 1000) // expires_at 2000
	testing.expectf(t, err == nil, "seed: %v", err)

	testing.expect(t, store.fingerprint_skip(db, "a.go", 10, 5, 1500), "stat match + live row")
	testing.expect(t, !store.fingerprint_skip(db, "a.go", 11, 5, 1500), "stat drift must re-parse")
	testing.expect(t, !store.fingerprint_skip(db, "a.go", 10, 5, 2500), "past TTL must re-parse")
	testing.expect(t, !store.fingerprint_skip(db, "b.go", 10, 5, 1500), "unknown path")

	// Direct row deletion deadens liveness: the crawl must re-parse even
	// under an unchanged stat.
	derr := store.delete_symbol_path(db, "a.go")
	testing.expectf(t, derr == nil, "delete: %v", derr)
	testing.expect(t, !store.fingerprint_skip(db, "a.go", 10, 5, 1500))

	// The purge (nothing seen) drops the fingerprint row entirely.
	none := make(map[u64]bool, 0, context.temp_allocator)
	defer delete(none)
	purged, perr := store.file_stat_purge_unseen(db, none, nil)
	testing.expectf(t, perr == nil, "purge: %v", perr)
	testing.expect_value(t, purged, 1)
	_, _, found, ferr := store.file_stat_get(db, "a.go")
	testing.expectf(t, ferr == nil, "read: %v", ferr)
	testing.expect_value(t, found, false)

	// A fresh batch write refreshes the mirror entry.
	err = store.write_symbol_index_batch(db, writes[:], 3000, 1000) // expires_at 4000
	testing.expectf(t, err == nil, "reseed: %v", err)
	testing.expect(t, store.fingerprint_skip(db, "a.go", 10, 5, 3500))
}

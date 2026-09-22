// The file_stat table and its accessors: the disk fingerprint tier of the
// symbol index. Every row is the (mtime_ns, size) the crawled file carried
// when its index rows last committed; the incremental crawl stats the file
// again and skips the parse when both sides agree AND live symbol rows
// still exist (store.symbol_cache_has_path). Fingerprints land inside the
// index-write transaction, so they never describe rows that failed to
// commit, and they carry no TTL — a fingerprint is a comparison key, not a
// cache. A whole-project walk purges the fingerprints (and their symbol
// rows) of paths it no longer sees, which is what makes an on-disk
// rename/delete stop answering within one pass instead of living out the
// symbol TTL — but only along routes it enumerated: paths under a subtree
// the walk could not enumerate (unreadable, depth-capped, or symlinked)
// are kept, because their absence is not provable.
package store

import "base:runtime"
import "core:strings"
import "core:sync"

import "src:platform"

// file_stat_get returns the recorded fingerprint for one path, cloned into
// nothing (two integers). found is false when the path was never committed
// by an incremental-capable crawl — among others, every row written before
// this table existed — which the caller treats as "parse it".
file_stat_get :: proc(db: ^DB, path: string) -> (mtime_ns: i64, size: i64, found: bool, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT mtime_ns, size FROM file_stat WHERE path = ?1;")
	if serr != nil {
		return 0, 0, false, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, path); berr != nil {
		return 0, 0, false, berr
	}
	has_row, rerr := stmt_step(&stmt)
	if rerr != nil {
		return 0, 0, false, rerr
	}
	if !has_row {
		return 0, 0, false, nil
	}
	return stmt_column_int(&stmt, 0), stmt_column_int(&stmt, 1), true, nil
}

// file_stat_put_txn records one fingerprint. Transaction-internal (the
// name says so): the caller owns the BEGIN/COMMIT span — the batched index
// write calls this so the fingerprint commits with the rows it describes.
file_stat_put_txn :: proc(db: ^DB, path: string, mtime_ns: i64, size: i64) -> platform.Err {
	stmt, perr := stmt_prepare(db, "INSERT INTO file_stat (path, mtime_ns, size) VALUES (?1, ?2, ?3) ON CONFLICT(path) DO UPDATE SET mtime_ns = excluded.mtime_ns, size = excluded.size;")
	if perr != nil {
		return perr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, path); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&stmt, 2, mtime_ns); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&stmt, 3, size); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	return nil
}

// file_stat_delete drops one fingerprint. Outside an open transaction the
// statement runs in autocommit; the purge calls it inside its single
// BEGIN/COMMIT span so every vanished path drops atomically together with
// its rows. The fingerprint of a vanished file must not outlive its rows
// or the next walk would keep treating the path as known.
file_stat_delete :: proc(db: ^DB, path: string) -> platform.Err {
	stmt, perr := stmt_prepare(db, "DELETE FROM file_stat WHERE path = ?1;")
	if perr != nil {
		return perr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, path); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	return nil
}

// file_stat_purge_unseen removes the fingerprints of paths absent from
// `seen`, together with those paths' symbol rows, and reports how many it
// removed. The caller passes the set of path hashes
// (platform.path_hash64 over the rel path — walk-side sets hold hashes so
// a whole-project walk does not retain every path string) a COMPLETED
// whole-project walk reached, plus `keep_prefixes`, the rel-path prefixes
// of subtrees the walk could not enumerate (unreadable, depth-capped, or
// symlinked directories). A recorded path counts as vanished only when
// the walk enumerated — or intentionally excluded (gitignore, deny) — its
// whole route; anything else recorded but not walked has left the project
// (deleted, moved away, or newly ignored).
//
// The recorded paths enumerate from the fingerprint mirror (one bulk load
// instead of a full-table read-and-clone per walk), and the vanished set —
// usually empty — drops in ONE transaction: every mirror key is collected
// before the rows go, exactly as a direct deletion. An error mid-purge
// rolls the whole purge back; the next walk re-runs the comparison against
// the same fingerprints. (Per-path independent transactions once made a
// branch switch that renames a large subtree pay one BEGIN/COMMIT pair per
// vanished file.)
file_stat_purge_unseen :: proc(db: ^DB, seen: map[u64]bool, keep_prefixes: []string) -> (purged: int, err: platform.Err) {
	if !db.fp.loaded {
		if lerr := fp_load(db); lerr != nil {
			return 0, lerr
		}
	}

	// Collect the vanished candidates under the mirror lock (cloned — the
	// drop below deletes the map-owned keys).
	sync.mutex_lock(&db.fp.mu)
	vanished := make([dynamic]string, 0, 8, context.temp_allocator)
	for path, _ in db.fp.m {
		if !seen[platform.path_hash64(path)] && !fingerprint_under_keep(path, keep_prefixes) {
			append(&vanished, strings.clone(path, context.temp_allocator))
		}
	}
	sync.mutex_unlock(&db.fp.mu)
	defer delete(vanished)
	if len(vanished) == 0 {
		return 0, nil
	}

	// Mirror keys first (they are only knowable before the rows drop),
	// then one transaction for every vanished path.
	keys := make([dynamic]string, 0, len(vanished) * 2, context.temp_allocator)
	defer delete(keys)
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	for path in vanished {
		pkeys, kerr := mirror_keys_for_path(db, path)
		defer delete(pkeys)
		if kerr != nil {
			return 0, kerr
		}
		for k in pkeys {
			append(&keys, k)
		}
	}
	if berr := db_exec(db, "BEGIN IMMEDIATE;"); berr != nil {
		return 0, berr
	}
	for path in vanished {
		if derr := delete_path_rows(db, "symbol_names", path); derr != nil {
			return 0, rollback_and(db, derr)
		}
		if derr := delete_path_rows(db, "symbol_cache", path); derr != nil {
			return 0, rollback_and(db, derr)
		}
		if derr := file_stat_delete(db, path); derr != nil {
			return 0, rollback_and(db, derr)
		}
	}
	if cerr := db_exec(db, "COMMIT;"); cerr != nil {
		return 0, rollback_and(db, cerr)
	}
	for path in vanished {
		fp_drop(db, path)
		purged += 1
	}
	mirror_drop_keys(db, keys[:])
	return purged, nil
}

// fingerprint_under_keep reports whether `path` sits inside (or equals) one
// of the walk's unenumerated subtree prefixes. Component-boundary aware:
// "sub" shields "sub/a.go" but never "subx/a.go". The empty prefix (the
// project root itself could not be read) shields every path.
fingerprint_under_keep :: proc(path: string, keep_prefixes: []string) -> bool {
	for p in keep_prefixes {
		if p == "" || p == path {
			return true
		}
		if len(path) > len(p) && path[len(p)] == '/' && strings.has_prefix(path, p) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Fingerprint map — the parent-memory mirror of this table
// ---------------------------------------------------------------------------

Fingerprint_Entry :: struct {
	mtime_ns:   i64,
	size:       i64,
	expires_at: i64, // newest symbol_cache row deadline for the path (0: no live row)
}

// Fingerprint_Map mirrors the file_stat table plus each path's payload-row
// liveness deadline, so the crawl's per-file incremental skip and the
// purge's recorded-path enumeration answer from memory instead of two
// SQLite point queries per file per walk (measured as the walk's dominant
// query cost — every query is a read transaction taking the statement
// cache's mutex). Semantics:
//   - an entry exists iff a file_stat row exists (maintained at every
//     write/delete site below — writes happen only through the batch
//     writer, which records fingerprints in the same commit);
//   - the skip applies iff the recorded (mtime_ns, size) match AND
//     expires_at > now — the same conjunction file_stat_get plus
//     symbol_cache_has_path evaluate, with liveness carried as the row's
//     deadline so time-based expiry resolves exactly as the SQL probe
//     would;
//   - TTL-sweep deletions self-resolve (the deadline passes); cap-based
//     and direct deletions drop or deaden entries explicitly.
// The map is a mirror of a bounded table, not a cache: its size tracks the
// file_stat row count (the crawled file count), keys are cloned on first
// insert and map-owned. Lazily bulk-loaded on first use; a write racing
// the load can leave a too-old entry, which merely fails toward work (the
// file re-parses and the next write refreshes it).
Fingerprint_Map :: struct {
	mu:         sync.Mutex,
	loaded:     bool,
	allocator:  runtime.Allocator,
	m:          map[string]Fingerprint_Entry,
}

fingerprint_map_init :: proc(fm: ^Fingerprint_Map, a: runtime.Allocator) {
	fm^.allocator = a
	fm^.m = make(map[string]Fingerprint_Entry, 1024, a)
}

fingerprint_map_destroy :: proc(fm: ^Fingerprint_Map) {
	// Keys are owned clones: free them before the table (a bare map
	// delete frees only the table).
	for k, _ in fm^.m {
		delete(k, fm^.allocator)
	}
	delete(fm^.m)
	fm^.m = nil
}

// fp_load bulk-loads the mirror in one statement (one consistent read
// transaction under WAL). Errors leave the map unloaded — every consumer
// fails toward work.
fp_load :: proc(db: ^DB) -> platform.Err {
	sync.mutex_lock(&db.fp.mu)
	defer sync.mutex_unlock(&db.fp.mu)
	if db.fp.loaded {
		return nil
	}
	stmt, serr := stmt_prepare(db, "SELECT fs.path, fs.mtime_ns, fs.size, COALESCE(MAX(sc.expires_at), 0) FROM file_stat fs LEFT JOIN symbol_cache sc ON sc.path = fs.path GROUP BY fs.path, fs.mtime_ns, fs.size;")
	if serr != nil {
		return serr
	}
	defer stmt_finalize(&stmt)
	for {
		has_row, rerr := stmt_step(&stmt)
		if rerr != nil {
			return rerr
		}
		if !has_row {
			break
		}
		path := stmt_column_text(&stmt, 0)
		entry := Fingerprint_Entry{
			mtime_ns  = stmt_column_int(&stmt, 1),
			size      = stmt_column_int(&stmt, 2),
			expires_at = stmt_column_int(&stmt, 3),
		}
		if _, found := db.fp.m[path]; found {
			// A partial load before an error already inserted this key;
			// update in place — assigning through a fresh clone would
			// discard the clone and leak it into the map's allocator.
			db.fp.m[path] = entry
		} else {
			db.fp.m[strings.clone(path, db.fp.allocator)] = entry
		}
	}
	db.fp.loaded = true
	return nil
}

// fp_touch records one path's committed fingerprint and row deadline after
// a batch index write. No-op before the first load (the load then reads
// the authoritative table state).
fp_touch :: proc(db: ^DB, path: string, mtime_ns, size, expires_at: i64) {
	sync.mutex_lock(&db.fp.mu)
	defer sync.mutex_unlock(&db.fp.mu)
	if !db.fp.loaded {
		return
	}
	if e, ok := db.fp.m[path]; ok {
		e.mtime_ns = mtime_ns
		e.size = size
		e.expires_at = expires_at
		db.fp.m[path] = e
	} else {
		db.fp.m[strings.clone(path, db.fp.allocator)] = Fingerprint_Entry{mtime_ns, size, expires_at}
	}
}

// fp_drop removes one path's mirror entry together with its file_stat row.
fp_drop :: proc(db: ^DB, path: string) {
	sync.mutex_lock(&db.fp.mu)
	defer sync.mutex_unlock(&db.fp.mu)
	if !db.fp.loaded {
		return
	}
	// delete_key hands back the map-owned stored key (zero-value string
	// when the key was absent — real paths are never empty).
	stored, _ := delete_key(&db.fp.m, path)
	if len(stored) > 0 {
		delete(stored, db.fp.allocator)
	}
}

// fp_mark_dead zeroes one path's row liveness after its symbol rows were
// deleted directly (the fingerprint row remains until file_stat_delete).
fp_mark_dead :: proc(db: ^DB, path: string) {
	sync.mutex_lock(&db.fp.mu)
	defer sync.mutex_unlock(&db.fp.mu)
	if !db.fp.loaded {
		return
	}
	if e, ok := db.fp.m[path]; ok {
		e.expires_at = 0
		db.fp.m[path] = e
	}
}

// fingerprint_skip reports whether the crawl's incremental skip applies
// for (path, mtime_ns, size): the recorded fingerprint matches AND a live
// payload row answers — the conjunction of file_stat_get and
// symbol_cache_has_path, answered from the mirror. Load or probe errors
// fail toward work: the file parses rather than being skipped
// unverifiable.
fingerprint_skip :: proc(db: ^DB, path: string, mtime_ns, size: i64, now_ms: i64) -> (skip: bool) {
	sync.mutex_lock(&db.fp.mu)
	if !db.fp.loaded {
		sync.mutex_unlock(&db.fp.mu)
		if lerr := fp_load(db); lerr != nil {
			return false // fail toward work
		}
		sync.mutex_lock(&db.fp.mu)
	}
	e, ok := db.fp.m[path]
	sync.mutex_unlock(&db.fp.mu)
	return ok && e.mtime_ns == mtime_ns && e.size == size && e.expires_at > now_ms
}

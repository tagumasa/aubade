// The parent-memory mirror of the L1 payload tier: a bounded cache in
// front of the symbol_cache table so outline reads hit parent memory
// before SQLite. Fill order is mirror -> SQLite -> producer: a SQLite hit
// fills the mirror, write_symbol_index refreshes it alongside the row
// upsert (after the commit — the mirror must not serve rolled-back data),
// and the sweep/row-cap deletions drop the mirrored keys together with the
// rows they came from, so a mirrored entry never out-serves a deleted row.
// Entries carry the row's expires_at deadline on the same monotonic clock
// the rows use; an expired entry is dropped on read.
//
// Ownership: the cache owns its keys (composed "path\x00hash" strings
// cloned through the key hooks) and its values (payload bytes and language
// cloned in at put). Readers clone under the cache mutex (cache_view), so
// nothing is lent past the lock and the mirror never pins — explicit
// removal is always safe.
package store

import "core:mem"
import "core:strings"

import "src:platform"
import "src:util"

MIRROR_MAX_ENTRIES :: 32_000
MIRROR_MAX_BYTES   :: 64 * 1024 * 1024

Mirror :: struct {
	cache: util.Bounded_Cache(string, Mirror_Entry),
}

Mirror_Entry :: struct {
	payload:    []u8,
	language:   string,
	expires_at: i64,
	allocator:  mem.Allocator,
}

mirror_init :: proc(m: ^Mirror, a: mem.Allocator) {
	util.cache_init(
		&m.cache,
		MIRROR_MAX_ENTRIES,
		a,
		mirror_release_entry,
		MIRROR_MAX_BYTES,
		mirror_byte_cost,
		mirror_key_clone,
		mirror_key_release,
	)
}

mirror_destroy :: proc(m: ^Mirror) {
	util.cache_destroy(&m.cache)
}

mirror_byte_cost :: proc(v: Mirror_Entry) -> int {
	return len(v.payload) + len(v.language) + 64
}

mirror_key_clone :: proc(k: string, a: mem.Allocator) -> string {
	return strings.clone(k, a)
}

mirror_key_release :: proc(k: string, a: mem.Allocator) {
	delete(k, a)
}

mirror_release_entry :: proc(v: Mirror_Entry) {
	if v.payload != nil {
		delete(v.payload, v.allocator)
	}
	if v.language != "" {
		delete(v.language, v.allocator)
	}
}

// mirror_key composes the cache key on scratch; the cache clones what it
// keeps.
mirror_key :: proc(path: string, hash: string) -> string {
	return strings.concatenate({path, "\x00", hash}, context.temp_allocator)
}

// mirror_put copies a committed row's payload into the mirror. Empty
// payloads (rows written before the payload tier was wired) are not
// mirrored — they are permanent misses until a later write refreshes them.
mirror_put :: proc(db: ^DB, path: string, hash: string, language: string, payload: []u8, expires_at: i64) {
	if len(payload) == 0 {
		return
	}
	entry := Mirror_Entry{
		payload = make([]u8, len(payload), db.allocator),
		language = strings.clone(language, db.allocator),
		expires_at = expires_at,
		allocator = db.allocator,
	}
	copy(entry.payload, payload)
	// The mirror never pins, so the put can only insert or replace —
	// a refused put (pinned entry) is unreachable here.
	_ = util.cache_put(&db.mirror.cache, mirror_key(path, hash), entry)
}

mirror_drop_keys :: proc(db: ^DB, keys: []string) {
	for k in keys {
		util.cache_remove(&db.mirror.cache, k)
	}
}

// Mirror_Bind is one bound parameter of a mirror_keys_* query: the family's
// statements vary between one text bind, two text binds, and one int bind.
Mirror_Bind :: union {string, i64}

// mirror_keys_query runs a "SELECT path, hash FROM symbol_cache …" query
// and lists the mirror keys of every row it returns. Scan failures
// propagate: an empty key list behind an error would leave stale mirror
// entries serving deleted rows.
mirror_keys_query :: proc(db: ^DB, sql: string, binds: []Mirror_Bind) -> (keys: [dynamic]string, err: platform.Err) {
	keys = make([dynamic]string, 0, 4, context.temp_allocator)
	stmt, perr := stmt_prepare(db, sql)
	if perr != nil {
		return keys, perr
	}
	defer stmt_finalize(&stmt)
	for b, i in binds {
		switch v in b {
		case string:
			if berr := stmt_bind_text(&stmt, i32(i) + 1, v); berr != nil {
				return keys, berr
			}
		case i64:
			if berr := stmt_bind_int(&stmt, i32(i) + 1, v); berr != nil {
				return keys, berr
			}
		}
	}
	for {
		has_row, rerr := stmt_step(&stmt)
		if rerr != nil {
			return keys, rerr
		}
		if !has_row {
			break
		}
		append(&keys, mirror_key(stmt_column_text(&stmt, 0), stmt_column_text(&stmt, 1)))
	}
	return keys, nil
}

// mirror_keys_for_path lists the mirror keys of every row a path has
// (all hashes) — the collect-first companion to delete_symbol_path, which
// drops the keys together with the rows it deletes.
mirror_keys_for_path :: proc(db: ^DB, path: string) -> (keys: [dynamic]string, err: platform.Err) {
	return mirror_keys_query(db, "SELECT path, hash FROM symbol_cache WHERE path = ?1;", {path})
}

// mirror_keys_other_hashes lists the mirror keys of a path's rows under
// different hashes — the keys write_symbol_index invalidates after its
// commit deletes those rows.
mirror_keys_other_hashes :: proc(db: ^DB, path: string, hash: string) -> (keys: [dynamic]string, err: platform.Err) {
	return mirror_keys_query(db, "SELECT path, hash FROM symbol_cache WHERE path = ?1 AND hash != ?2;", {path, hash})
}

// mirror_keys_expired lists the mirror keys of rows the TTL sweep will
// delete (expires_at <= now_ms).
mirror_keys_expired :: proc(db: ^DB, now_ms: i64) -> (keys: [dynamic]string, err: platform.Err) {
	return mirror_keys_query(db, "SELECT path, hash FROM symbol_cache WHERE expires_at <= ?1;", {now_ms})
}

// mirror_keys_beyond_cap lists the mirror keys of the oldest rows beyond
// the newest-first row cap the sweep trims to (<= 0: no cap, nothing).
mirror_keys_beyond_cap :: proc(db: ^DB, max_rows: int) -> (keys: [dynamic]string, err: platform.Err) {
	if max_rows <= 0 {
		return make([dynamic]string, 0, 1, context.temp_allocator), nil
	}
	return mirror_keys_query(db, "SELECT path, hash FROM symbol_cache WHERE (path, hash) NOT IN (SELECT path, hash FROM symbol_cache ORDER BY created_at DESC LIMIT ?1);", {i64(max_rows)})
}

// symbol_cache_row_get is the SQLite read behind both the mirror fallback
// and the direct reader: the row's payload, language, and expiry deadline,
// cloned into `a`, when present and unexpired at now_ms.
symbol_cache_row_get :: proc(
	db: ^DB,
	path: string,
	hash: string,
	now_ms: i64,
	a := context.allocator,
) -> (payload: []u8, language: string, expires_at: i64, found: bool, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT payload, language, expires_at FROM symbol_cache WHERE path = ?1 AND hash = ?2 AND expires_at > ?3;")
	if serr != nil {
		return nil, "", 0, false, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, path); berr != nil {
		return nil, "", 0, false, berr
	}
	if berr := stmt_bind_text(&stmt, 2, hash); berr != nil {
		return nil, "", 0, false, berr
	}
	if berr := stmt_bind_int(&stmt, 3, now_ms); berr != nil {
		return nil, "", 0, false, berr
	}
	has_row, rerr := stmt_step(&stmt)
	if rerr != nil {
		return nil, "", 0, false, rerr
	}
	if !has_row {
		return nil, "", 0, false, nil
	}
	return stmt_column_blob_clone(&stmt, 0, a), stmt_column_text_clone(&stmt, 1, a), stmt_column_int(&stmt, 2), true, nil
}

Mirror_Copy :: struct {
	now_ms:    i64,
	allocator: mem.Allocator,
	hit:       bool,
	payload:   []u8,
	language:  string,
}

// mirror_copy_payload clones a mirrored entry into the caller's allocator
// under the cache mutex (cache_view): copying after an unlocked cache_get
// would race a concurrent mirror_put eviction freeing the payload
// mid-copy.
mirror_copy_payload :: proc(v: ^Mirror_Entry, user: rawptr) {
	ctx := cast(^Mirror_Copy)user
	if v.expires_at <= ctx.now_ms {
		ctx.hit = false
		return
	}
	ctx.hit = true
	ctx.payload = make([]u8, len(v.payload), ctx.allocator)
	copy(ctx.payload, v.payload)
	ctx.language = strings.clone(v.language, ctx.allocator)
}

// symbol_cache_payload is the L1 read path: the parent-memory mirror
// first, then SQLite — a SQLite hit fills the mirror. Payload and language
// are cloned into `a` (free them through `a`). found is true only when a
// decodable payload exists; the pre-wiring zero-length rows miss here.
symbol_cache_payload :: proc(
	db: ^DB,
	path: string,
	hash: string,
	now_ms: i64,
	a := context.allocator,
) -> (payload: []u8, language: string, found: bool, err: platform.Err) {
	mc := Mirror_Copy{now_ms = now_ms, allocator = a}
	if util.cache_view(&db.mirror.cache, mirror_key(path, hash), mirror_copy_payload, &mc) {
		if mc.hit {
			return mc.payload, mc.language, true, nil
		}
		// Expired in the mirror: drop it so it cannot out-serve the row.
		// Removed outside cache_view — the callback runs under the cache
		// mutex and must not re-enter the cache.
		util.cache_remove(&db.mirror.cache, mirror_key(path, hash))
	}

	row_expires: i64
	payload, language, row_expires, found, err = symbol_cache_row_get(db, path, hash, now_ms, a)
	if err != nil || !found {
		return payload, language, false, err
	}
	if len(payload) == 0 {
		// Zero-length blobs (pre-wiring rows) are not payloads.
		delete(payload, a)
		if language != "" {
			delete(language, a)
		}
		return nil, "", false, nil
	}
	mirror_put(db, path, hash, language, payload, row_expires)
	return payload, language, true, nil
}

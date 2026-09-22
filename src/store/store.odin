// SQLite storage: connection lifecycle with the project pragmas (WAL,
// NORMAL sync, 5 s busy timeout), schema management, the kv table, and the
// symbol index writer (L1 payload upsert + L0 name rows + old-hash cleanup
// in one transaction). The events table lives in events.odin on the same
// connection.
//
// Ownership: the DB handle is owned by db_close; result strings and blobs
// returned by the query helpers are cloned into the caller's allocator.
// Prepared statements are finalized before the connection closes (the
// helpers enforce that per call).
package store

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:util"

DB :: struct {
	handle:    rawptr,
	// The parent-memory mirror of the L1 payload tier, filled by
	// write_symbol_index and the payload reads, invalidated by the sweep.
	mirror:    Mirror,
	// The parent-memory mirror of the file_stat tier plus payload-row
	// liveness deadlines (see file_stat.odin): the crawl's incremental
	// skip and the purge's recorded-path enumeration read this instead of
	// two SQLite point queries per file per walk.
	fp:        Fingerprint_Map,
	allocator: runtime.Allocator,
	// Transaction serialization: SQLite transactions are connection-global,
	// so every BEGIN..COMMIT/ROLLBACK span (the index writers, the event
	// append, the sweep's deletes) holds tx_mu for the whole span. The
	// FULLMUTEX open serializes individual C calls, not spans — without
	// this mutex two worker threads interleave into duplicate-BEGIN errors
	// or one thread's rows committing with another's transaction. Lock
	// order is tx_mu → stmt_mu; nothing takes them in reverse.
	tx_mu:     sync.Mutex,
	// Prepared-statement cache: one compiled sqlite3_stmt per distinct SQL
	// string, reused across calls (reset + clear_bindings per acquire).
	// mu is held from stmt_prepare to the matching stmt_finalize — every
	// helper pairs the two via defer — so a cached statement is never
	// stepped by two threads at once. db_close finalizes every cached
	// statement before the connection closes.
	stmt_mu:   sync.Mutex,
	stmts:     map[string]Stmt,
}

DEFAULT_TTL_MS :: i64(24 * 60 * 60 * 1000) // 24 h, the single symbol TTL

// db_open opens (creating if needed) the project database and applies the
// pragmas and schema.
db_open :: proc(path: string, a := context.allocator) -> (db: ^DB, err: platform.Err) {
	c_path, perr := strings.clone_to_cstring(path, context.temp_allocator)
	if perr != nil {
		return nil, platform.Wrapped{kind = .Internal, msg = "store: path allocation failed"}
	}
	handle: rawptr
	rc := sqlite3_open_v2(c_path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
	if rc != SQLITE_OK {
		msg := "store: open failed"
		if handle != nil {
			// The virtual handle SQLite returns on a failed open carries
			// the reason until it is closed — read it first.
			c := sqlite3_errmsg(handle)
			if c != nil {
				msg = strings.concatenate({"store: open failed: ", string(c)}, context.temp_allocator)
			}
			sqlite3_close_v2(handle)
		}
		return nil, platform.Wrapped{
			kind = .Internal,
			msg  = msg,
		}
	}
	db = new(DB, a)
	db^ = {handle = handle, allocator = a}
	// Init before anything can fail: every db_close path (including the
	// pragma/schema error paths below) destroys the mirror and fingerprint
	// map.
	mirror_init(&db.mirror, a)
	fingerprint_map_init(&db.fp, a)

	// Pragmas: incremental auto-vacuum (dead pages returnable by the daily
	// sweep), WAL journal, relaxed sync, bounded lock waits, a bounded page
	// cache, and WAL high-water truncation after checkpoints.
	// auto_vacuum must run FIRST and before the schema DDL below: it only
	// takes effect on a store with no tables, and setting journal_mode
	// first materializes the header page, which already counts as
	// non-empty for this pragma.
	pragmas := []string{
		"PRAGMA auto_vacuum = INCREMENTAL;",
		"PRAGMA journal_mode = WAL;",
		"PRAGMA synchronous = NORMAL;",
		"PRAGMA busy_timeout = 5000;",
		"PRAGMA cache_size = -65536;", // 64 MiB page cache (the store budget)
		"PRAGMA journal_size_limit = 8388608;", // 8 MiB: the WAL shrinks back after a spike
	}
	for pragma in pragmas {
		if perr := db_exec(db, pragma); perr != nil {
			db_close(db)
			return nil, perr
		}
	}
	if serr := db_exec(db, SCHEMA_SQL); serr != nil {
		db_close(db)
		return nil, serr
	}
	return db, nil
}

db_close :: proc(db: ^DB) {
	if db == nil {
		return
	}
	mirror_destroy(&db.mirror)
	fingerprint_map_destroy(&db.fp)
	sync.mutex_lock(&db.stmt_mu)
	// Keys are owned clones (see stmt_prepare). Collect then free —
	// freeing the current key mid-iteration is treated as map mutation
	// (conn_destroy's rule): the handles finalize while collecting, the
	// keys die after the map does.
	sqls := make([dynamic]string, 0, len(db.stmts), context.temp_allocator)
	for sql, stmt in db.stmts {
		sqlite3_finalize(stmt.handle)
		append(&sqls, sql)
	}
	delete(db.stmts)
	db.stmts = nil
	for sql in sqls {
		delete(sql, db.allocator)
	}
	delete(sqls)
	sync.mutex_unlock(&db.stmt_mu)
	if db.handle != nil {
		sqlite3_close_v2(db.handle)
		db.handle = nil
	}
	a := db.allocator
	free(db, a)
}

SCHEMA_SQL :: `
CREATE TABLE IF NOT EXISTS symbol_cache (
  path       TEXT NOT NULL,
  hash       TEXT NOT NULL,
  language   TEXT NOT NULL,
  payload    BLOB NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (path, hash)
);
-- The sweep's filter and sort columns: without these, every sweep (each
-- parent start, then daily) full-scans the BLOB-heavy table and sorts for
-- the row cap.
CREATE INDEX IF NOT EXISTS symbol_cache_expires ON symbol_cache(expires_at);
CREATE INDEX IF NOT EXISTS symbol_cache_recency ON symbol_cache(created_at DESC);

CREATE TABLE IF NOT EXISTS symbol_names (
  name   TEXT NOT NULL,
  kind   TEXT NOT NULL,
  path   TEXT NOT NULL,
  hash   TEXT NOT NULL,
  line   INTEGER NOT NULL,
  parent TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS symbol_names_name ON symbol_names(name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS symbol_names_path ON symbol_names(path, hash);

-- The disk fingerprint of every file the crawl committed rows for: the
-- mtime/size the file carried at that commit. The incremental crawl
-- compares a fresh stat against it to decide whether a parse is needed;
-- it is a fingerprint, not a cache, so it carries no TTL. Rows are
-- written inside the index-write transaction (a fingerprint lands only
-- when the rows it describes committed) and purged when a whole-project
-- walk no longer sees the path.
CREATE TABLE IF NOT EXISTS file_stat (
  path     TEXT PRIMARY KEY,
  mtime_ns INTEGER NOT NULL,
  size     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS kv (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- tracker: the only persistence of the event stream. uid is unique and
-- totally ordered (fixed-width hex, lexicographic == numeric), so the
-- stream order is ORDER BY uid. Events are never deleted.
CREATE TABLE IF NOT EXISTS events (
  seq     INTEGER PRIMARY KEY AUTOINCREMENT,
  uid     TEXT NOT NULL,
  ts      INTEGER NOT NULL,
  origin  TEXT NOT NULL,
  kind    TEXT NOT NULL,
  version INTEGER NOT NULL,
  payload TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS events_uid ON events(uid);

-- tracker: rendered sprint reports (the export artifact). Fully derived
-- from events above — tracker_export regenerates any row — and stored
-- here so exports never add entries to the project tree: one row per
-- sprint id, overwritten on re-export.
CREATE TABLE IF NOT EXISTS sprint_reports (
  sprint_id   TEXT PRIMARY KEY,
  content     TEXT NOT NULL,
  rendered_ms INTEGER NOT NULL
);
`

// db_exec runs SQL with no parameters (DDL, pragmas, transaction control).
// The errmsg out-parameter is left NULL: the error text comes from
// sqlite3_errmsg on the connection instead (no sqlite3_free bookkeeping).
db_exec :: proc(db: ^DB, sql: string) -> platform.Err {
	c_sql, aerr := strings.clone_to_cstring(sql, context.temp_allocator)
	if aerr != nil {
		return platform.Wrapped{kind = .Internal, msg = "store: sql allocation failed"}
	}
	rc := sqlite3_exec(db.handle, c_sql, nil, nil, nil)
	if rc != SQLITE_OK {
		return platform.Wrapped{kind = .Internal, msg = err_msg(db, "store: exec failed")}
	}
	return nil
}

// symbol_cache_count reports the number of persistent symbol rows — a
// verification view of the L1 table (the sweep's effect is otherwise
// invisible: reads refuse expired rows whether or not the row is still
// on disk).
symbol_cache_count :: proc(db: ^DB) -> (count: int, err: platform.Err) {
	stmt, qerr := stmt_prepare(db, "SELECT COUNT(*) FROM symbol_cache;")
	if qerr != nil {
		return 0, qerr
	}
	defer stmt_finalize(&stmt)
	has_row, serr := stmt_step(&stmt)
	if serr != nil || !has_row {
		if serr == nil {
			serr = platform.Wrapped{kind = .Internal, msg = "store: count returned no row"}
		}
		return 0, serr
	}
	return int(stmt_column_int(&stmt, 0)), nil
}

// symbol_cache_has_path reports whether any live (unexpired) symbol row
// exists for a path — the incremental crawl's rows-still-there probe. A
// fingerprint alone is not freshness: the TTL sweep can drop a file's
// rows while its disk stat stands still, and that file must re-parse,
// not skip.
symbol_cache_has_path :: proc(db: ^DB, path: string, now_ms: i64) -> (has: bool, err: platform.Err) {
	stmt, qerr := stmt_prepare(db, "SELECT 1 FROM symbol_cache WHERE path = ?1 AND expires_at > ?2 LIMIT 1;")
	if qerr != nil {
		return false, qerr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, path); berr != nil {
		return false, berr
	}
	if berr := stmt_bind_int(&stmt, 2, now_ms); berr != nil {
		return false, berr
	}
	has_row, serr := stmt_step(&stmt)
	if serr != nil {
		return false, serr
	}
	return has_row, nil
}

Stmt :: struct {
	handle: rawptr,
	db:     ^DB,
}

// stmt_prepare acquires a prepared statement for one call: the statement
// is compiled once per distinct SQL string and cached on the DB, then
// reset for reuse. The DB mutex is held until the matching stmt_finalize
// (every caller pairs the two via defer); prepare failures release it
// themselves. The returned Stmt is a copy — the cached original stays in
// the map untouched.
stmt_prepare :: proc(db: ^DB, sql: string) -> (stmt: Stmt, err: platform.Err) {
	sync.mutex_lock(&db.stmt_mu)
	if db.stmts == nil {
		db.stmts = make(map[string]Stmt, 16, db.allocator)
	}
	if cached, found := db.stmts[sql]; found {
		sqlite3_reset(cached.handle)
		sqlite3_clear_bindings(cached.handle)
		return cached, nil
	}
	c_sql, aerr := strings.clone_to_cstring(sql, context.temp_allocator)
	if aerr != nil {
		sync.mutex_unlock(&db.stmt_mu)
		return {}, platform.Wrapped{kind = .Internal, msg = "store: sql allocation failed"}
	}
	handle: rawptr
	tail: cstring
	rc := sqlite3_prepare_v2(db.handle, c_sql, i32(len(sql)) + 1, &handle, &tail)
	if rc != SQLITE_OK {
		sync.mutex_unlock(&db.stmt_mu)
		return {}, platform.Wrapped{kind = .Internal, msg = err_msg(db, "store: prepare failed")}
	}
	stmt = {handle = handle, db = db}
	// The key is cloned into the DB's allocator: every literal-SQL caller
	// pays a small fixed duplication, but the one caller that composes its
	// SQL on the request temp allocator would otherwise rot the stored key
	// the moment the frame's scratch is freed.
	db.stmts[strings.clone(sql, db.allocator)] = stmt
	return stmt, nil
}

// stmt_finalize returns a statement to the cache: the compiled handle
// stays for reuse (finalized only in db_close), and the mutex taken by
// stmt_prepare is released. The handle is nil'd so an explicit finalize
// followed by the deferred one is a no-op.
stmt_finalize :: proc(stmt: ^Stmt) {
	if stmt.handle != nil {
		sqlite3_reset(stmt.handle)
		sqlite3_clear_bindings(stmt.handle)
		stmt.handle = nil
		sync.mutex_unlock(&stmt.db.stmt_mu)
	}
}

stmt_bind_text :: proc(stmt: ^Stmt, idx: i32, text: string) -> platform.Err {
	// SQLITE_TRANSIENT copies the bytes inside the call, so the string
	// needs no NUL terminator and no interim cstring clone. An empty string
	// still needs a non-nil pointer: (nil, 0) binds SQL NULL, not '' — the
	// static "\x00" literal serves as a zero-length NUL-terminated string.
	c := cast(cstring)raw_data(text)
	if len(text) == 0 {
		empty := "\x00"
		c = cast(cstring)raw_data(empty)
	}
	rc := sqlite3_bind_text(stmt.handle, idx, c, i32(len(text)), SQLITE_TRANSIENT)
	if rc != SQLITE_OK {
		return platform.Wrapped{kind = .Internal, msg = err_msg(stmt.db, "store: bind_text failed")}
	}
	return nil
}

stmt_bind_int :: proc(stmt: ^Stmt, idx: i32, value: i64) -> platform.Err {
	rc := sqlite3_bind_int64(stmt.handle, idx, value)
	if rc != SQLITE_OK {
		return platform.Wrapped{kind = .Internal, msg = err_msg(stmt.db, "store: bind_int failed")}
	}
	return nil
}

stmt_bind_blob :: proc(stmt: ^Stmt, idx: i32, data: []u8) -> platform.Err {
	rc: i32
	if len(data) == 0 {
		// &data[0] is out of range on an empty slice; a zero-length
		// zeroblob is the same empty-blob value (payload is never NULL).
		rc = sqlite3_bind_zeroblob(stmt.handle, idx, 0)
	} else {
		rc = sqlite3_bind_blob(stmt.handle, idx, &data[0], i32(len(data)), SQLITE_TRANSIENT)
	}
	if rc != SQLITE_OK {
		return platform.Wrapped{kind = .Internal, msg = err_msg(stmt.db, "store: bind_blob failed")}
	}
	return nil
}

stmt_step :: proc(stmt: ^Stmt) -> (has_row: bool, err: platform.Err) {
	rc := sqlite3_step(stmt.handle)
	if rc == SQLITE_ROW {
		return true, nil
	}
	if rc == SQLITE_DONE {
		return false, nil
	}
	return false, platform.Wrapped{kind = .Internal, msg = err_msg(stmt.db, "store: step failed")}
}

stmt_column_text :: proc(stmt: ^Stmt, column: i32) -> string {
	c := sqlite3_column_text(stmt.handle, column)
	if c == nil {
		return ""
	}
	return string(c)
}

// stmt_column_text_clone returns a column's text cloned into `a` (the
// SQLite borrow dies at the next step/finalize).
stmt_column_text_clone :: proc(stmt: ^Stmt, column: i32, a: runtime.Allocator) -> string {
	return strings.clone(stmt_column_text(stmt, column), a)
}

stmt_column_int :: proc(stmt: ^Stmt, column: i32) -> i64 {
	return sqlite3_column_int64(stmt.handle, column)
}

// stmt_column_blob_clone returns a column's blob cloned into `a`.
stmt_column_blob_clone :: proc(stmt: ^Stmt, column: i32, a: runtime.Allocator) -> []u8 {
	n := sqlite3_column_bytes(stmt.handle, column)
	if n <= 0 {
		return nil
	}
	src := sqlite3_column_blob(stmt.handle, column)
	out := make([]u8, int(n), a)
	mem.copy(&out[0], src, int(n))
	return out
}

// query_one_text runs a one-text-bind one-text-column query: prepare, bind
// `key` at index 1, step once, clone column 0 when a row came back.
query_one_text :: proc(db: ^DB, sql: string, key: string, a := context.allocator) -> (value: string, found: bool, err: platform.Err) {
	stmt, serr := stmt_prepare(db, sql)
	if serr != nil {
		return "", false, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, key); berr != nil {
		return "", false, berr
	}
	has_row, rerr := stmt_step(&stmt)
	if rerr != nil {
		return "", false, rerr
	}
	if !has_row {
		return "", false, nil
	}
	return stmt_column_text_clone(&stmt, 0, a), true, nil
}

// ---------------------------------------------------------------------------
// kv
// ---------------------------------------------------------------------------

// kv_get reads one key without tx_mu: its callers run at init time
// (snapshot restore, warm marker probe), before any request
// thread can hold an open transaction on the connection. A caller that
// ever races a transaction span must take tx_mu itself — an unlocked read
// inside another thread's open transaction observes its uncommitted rows.
kv_get :: proc(db: ^DB, key: string, a := context.allocator) -> (value: string, found: bool, err: platform.Err) {
	return query_one_text(db, "SELECT value FROM kv WHERE key = ?1;", key, a)
}

// kv_put upserts one key. tx_mu is held for the whole statement even
// though kv_put opens no transaction of its own: SQLite transactions are
// connection-global, so an unlocked upsert interleaving another thread's
// open BEGIN..COMMIT joins that transaction (rolled back with it after
// kv_put already returned success) and perturbs the sqlite3_changes
// detector those spans rely on.
kv_put :: proc(db: ^DB, key: string, value: string) -> platform.Err {
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	stmt, serr := stmt_prepare(db, "INSERT INTO kv (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
	if serr != nil {
		return serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, key); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&stmt, 2, value); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	return nil
}

// kv_delete removes a key; deleting an absent key is not an error (the
// fold-snapshot tests use it to force the full-refold path). tx_mu for
// the same span reason as kv_put.
kv_delete :: proc(db: ^DB, key: string) -> platform.Err {
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	stmt, serr := stmt_prepare(db, "DELETE FROM kv WHERE key = ?1;")
	if serr != nil {
		return serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, key); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	return nil
}

// ---------------------------------------------------------------------------
// Sprint reports (tracker export rows)
// ---------------------------------------------------------------------------

// sprint_report_put upserts one rendered sprint report. tx_mu is held for
// the same span reason as kv_put; the writer may be the daemon's manager
// or the CLI export command, both on their own connection.
sprint_report_put :: proc(db: ^DB, sprint_id: string, content: string, rendered_ms: i64) -> platform.Err {
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	stmt, serr := stmt_prepare(db, "INSERT INTO sprint_reports (sprint_id, content, rendered_ms) VALUES (?1, ?2, ?3) ON CONFLICT(sprint_id) DO UPDATE SET content = excluded.content, rendered_ms = excluded.rendered_ms;")
	if serr != nil {
		return serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, sprint_id); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&stmt, 2, content); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&stmt, 3, rendered_ms); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	return nil
}

// sprint_report_get reads one stored report. Same unlocked-read caveat as
// kv_get: callers that can race an open transaction span must take tx_mu
// themselves.
sprint_report_get :: proc(db: ^DB, sprint_id: string, a := context.allocator) -> (content: string, found: bool, err: platform.Err) {
	return query_one_text(db, "SELECT content FROM sprint_reports WHERE sprint_id = ?1;", sprint_id, a)
}

// ---------------------------------------------------------------------------
// Symbol index (L0/L1)
// ---------------------------------------------------------------------------

Symbol_Name_Row :: struct {
	name:   string,
	kind:   string,
	line:   i64,
	parent: string,
}

Symbol_Name_Row_With_File :: struct {
	name:   string,
	kind:   string,
	path:   string,
	hash:   string,
	line:   i64,
	parent: string,
}

// rollback_and rolls the open transaction back and reports `primary`. A
// failed ROLLBACK leaves the transaction open — the next BEGIN on this
// connection wedges with "cannot start a transaction within a
// transaction" — so the rollback failure rides along as the cause chain
// instead of being dropped. The whole returned Err (wrapper and cause
// alike) is frame-scoped store-error scratch: chain links share the
// wrapper's lifetime scope, and every caller renders or re-clones it
// before the frame's temp reset — nothing here may outlive the frame.
rollback_and :: proc(db: ^DB, primary: platform.Err) -> platform.Err {
	rerr := db_exec(db, "ROLLBACK;")
	if rerr == nil {
		return primary
	}
	cause := new(platform.Wrapped, context.temp_allocator)
	cause^ = {
		kind = .Internal,
		msg  = err_msg(db, "store: rollback failed"),
	}
	kind: platform.Err_Kind = .Internal
	msg := "store: transaction failed"
	switch w in primary {
	case platform.Wrapped:
		kind = w.kind
		msg = w.msg
	case platform.Err_Kind:
		kind = w
	}
	return platform.Wrapped{kind = kind, msg = msg, cause = cause}
}

// write_symbol_index writes one file's symbol index in a single
// transaction: the L1 payload upsert keyed by (path, hash), the L0 name
// rows for this (path, hash), and the deletion of older-hash rows for the
// same path. Idempotent — the same (path, hash) overwrites.
write_symbol_index :: proc(
	db: ^DB,
	path: string,
	hash: string,
	language: string,
	names: []Symbol_Name_Row,
	payload: []u8,
	now_ms: i64,
	ttl_ms: i64 = DEFAULT_TTL_MS,
) -> platform.Err {
	// tx_mu spans the whole collect-BEGIN-COMMIT sequence (the struct
	// comment): the mirror-key collection must not race another writer's
	// commit for the same path.
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	// The superseded-hash mirror keys must be collected before the
	// transaction drops the rows; they are invalidated only after the
	// commit succeeds (the mirror must not run ahead of, or behind, the
	// committed state). A failed collection aborts the write: proceeding
	// would leave the superseded mirror entries serving dropped rows.
	old_keys, kerr := mirror_keys_other_hashes(db, path, hash)
	defer delete(old_keys)
	if kerr != nil {
		return kerr
	}
	if berr := db_exec(db, "BEGIN IMMEDIATE;"); berr != nil {
		return berr
	}
	err := write_symbol_index_txn(db, path, hash, language, names, payload, now_ms, ttl_ms)
	if err != nil {
		return rollback_and(db, err)
	}
	if cerr := db_exec(db, "COMMIT;"); cerr != nil {
		return rollback_and(db, cerr)
	}
	mirror_put(db, path, hash, language, payload, now_ms + ttl_ms)
	mirror_drop_keys(db, old_keys[:])
	return nil
}

// Symbol_Write is one file's index contribution to a batched write.
// Every string and byte slice is owned by the batch arena the crawl
// clones into — the per-file scratch resets between appends. The
// mtime/size fingerprint is the disk stat the crawler took alongside
// the parse: the batch records it in file_stat so the next incremental
// pass can skip an unchanged file without reading it.
Symbol_Write :: struct {
	path:     string,
	hash:     string,
	language: string,
	names:    []Symbol_Name_Row,
	payload:  []u8,
	mtime_ns: i64,
	size:     i64,
}

// write_symbol_index_batch commits several files' index writes in one
// transaction (the crawl path): a whole directory becomes one BEGIN/COMMIT
// instead of one per file. The ordering rules match the single-file
// variant exactly — superseded-hash mirror keys are collected before the
// rows drop, and every mirror refresh happens only after the commit
// succeeds.
write_symbol_index_batch :: proc(
	db: ^DB,
	writes: []Symbol_Write,
	now_ms: i64,
	ttl_ms: i64 = DEFAULT_TTL_MS,
) -> platform.Err {
	// tx_mu spans the whole collect-BEGIN-COMMIT sequence, exactly as in
	// the single-file variant.
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	old_keys := make([dynamic]string, 0, len(writes) * 2, context.temp_allocator)
	defer delete(old_keys)
	for w in writes {
		keys, kerr := mirror_keys_other_hashes(db, w.path, w.hash)
		for k in keys {
			append(&old_keys, k)
		}
		delete(keys)
		if kerr != nil {
			return kerr
		}
	}
	if berr := db_exec(db, "BEGIN IMMEDIATE;"); berr != nil {
		return berr
	}
	for w in writes {
		if err := write_symbol_index_txn(db, w.path, w.hash, w.language, w.names, w.payload, now_ms, ttl_ms); err != nil {
			return rollback_and(db, err)
		}
	}
	// Fingerprints commit with the rows they describe (same transaction):
	// a rolled-back batch leaves no fingerprint behind, so the next
	// incremental pass re-parses instead of silently skipping.
	for w in writes {
		if ferr := file_stat_put_txn(db, w.path, w.mtime_ns, w.size); ferr != nil {
			return rollback_and(db, ferr)
		}
	}
	if cerr := db_exec(db, "COMMIT;"); cerr != nil {
		return rollback_and(db, cerr)
	}
	// Mirror only each path's LAST write: the transaction's
	// delete_other_hashes keeps just that row (two hashes for one path in
	// one batch leave the first superseded), and mirroring every write
	// would re-supply the mirror row the transaction just deleted.
	last_of_path := make(map[string]int, len(writes), context.temp_allocator)
	defer delete(last_of_path)
	for w, i in writes {
		last_of_path[w.path] = i
	}
	for _, i in last_of_path {
		w := writes[i]
		mirror_put(db, w.path, w.hash, w.language, w.payload, now_ms + ttl_ms)
		fp_touch(db, w.path, w.mtime_ns, w.size, now_ms + ttl_ms)
	}
	mirror_drop_keys(db, old_keys[:])
	return nil
}

write_symbol_index_txn :: proc(
	db: ^DB,
	path: string,
	hash: string,
	language: string,
	names: []Symbol_Name_Row,
	payload: []u8,
	now_ms: i64,
	ttl_ms: i64,
) -> platform.Err {
	upsert, err := stmt_prepare(db, "INSERT INTO symbol_cache (path, hash, language, payload, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(path, hash) DO UPDATE SET language = excluded.language, payload = excluded.payload, created_at = excluded.created_at, expires_at = excluded.expires_at;")
	if err != nil {
		return err
	}
	defer stmt_finalize(&upsert)
	if berr := stmt_bind_text(&upsert, 1, path); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&upsert, 2, hash); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&upsert, 3, language); berr != nil {
		return berr
	}
	// The schema's payload is NOT NULL: stmt_bind_blob binds an absent
	// payload as a zero-length blob, never SQL NULL.
	if berr := stmt_bind_blob(&upsert, 4, payload); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&upsert, 5, now_ms); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&upsert, 6, now_ms + ttl_ms); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&upsert); rerr != nil {
		return rerr
	}
	stmt_finalize(&upsert) // defer double-finalize is guarded (nil check)

	// L0 rows for this path are replaced wholesale: same-hash rewrites are
	// routine (crawls refresh unchanged files), and deleting by path alone
	// also covers the older-hash cleanup.
	del_names, perr := stmt_prepare(db, "DELETE FROM symbol_names WHERE path = ?1;")
	if perr != nil {
		return perr
	}
	defer stmt_finalize(&del_names)
	if berr := stmt_bind_text(&del_names, 1, path); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&del_names); rerr != nil {
		return rerr
	}
	stmt_finalize(&del_names)

	insert, ierr := stmt_prepare(db, "INSERT INTO symbol_names (name, kind, path, hash, line, parent) VALUES (?1, ?2, ?3, ?4, ?5, ?6);")
	if ierr != nil {
		return ierr
	}
	defer stmt_finalize(&insert)
	for i in 0..<len(names) {
		if berr := stmt_bind_text(&insert, 1, names[i].name); berr != nil {
			return berr
		}
		if berr := stmt_bind_text(&insert, 2, names[i].kind); berr != nil {
			return berr
		}
		if berr := stmt_bind_text(&insert, 3, path); berr != nil {
			return berr
		}
		if berr := stmt_bind_text(&insert, 4, hash); berr != nil {
			return berr
		}
		if berr := stmt_bind_int(&insert, 5, names[i].line); berr != nil {
			return berr
		}
		if berr := stmt_bind_text(&insert, 6, names[i].parent); berr != nil {
			return berr
		}
		if _, rerr := stmt_step(&insert); rerr != nil {
			return rerr
		}
		sqlite3_reset(insert.handle)
	}
	stmt_finalize(&insert)

	// Older hashes for this path's L1 payload disappear in the same
	// transaction.
	if derr := delete_other_hashes(db, "symbol_cache", path, hash); derr != nil {
		return derr
	}
	return nil
}

delete_other_hashes :: proc(db: ^DB, table: string, path: string, hash: string) -> platform.Err {
	sql := strings.concatenate({"DELETE FROM ", table, " WHERE path = ?1 AND hash != ?2;"}, context.temp_allocator)
	stmt, err := stmt_prepare(db, sql)
	if err != nil {
		return err
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, path); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&stmt, 2, hash); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	return nil
}

// symbol_names_lookup returns the L0 rows for a name (case-insensitive),
// cloned into `a`; free with symbol_names_rows_destroy.
symbol_names_lookup :: proc(db: ^DB, name: string, a := context.allocator) -> (rows: []Symbol_Name_Row_With_File, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT name, kind, path, hash, line, parent FROM symbol_names WHERE name = ?1 COLLATE NOCASE;")
	if serr != nil {
		return nil, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, name); berr != nil {
		return nil, berr
	}
	return symbol_names_rows_collect(&stmt, a)
}

// symbol_names_lookup_glob returns the L0 rows whose name matches a `*`
// glob, cloned into `a`; free with symbol_names_rows_destroy. Matching runs
// through SQL LIKE, which folds ASCII case exactly like the exact-match
// arm's COLLATE NOCASE, so "mono_*" and "MONO_NS" behave the same in both
// arms. A leading-wildcard pattern cannot use the name index and scans the
// table once per query — acceptable at interactive tool rates.
symbol_names_lookup_glob :: proc(db: ^DB, pattern: string, a := context.allocator) -> (rows: []Symbol_Name_Row_With_File, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT name, kind, path, hash, line, parent FROM symbol_names WHERE name LIKE ?1 ESCAPE '\\';")
	if serr != nil {
		return nil, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, like_glob_pattern(pattern, context.temp_allocator)); berr != nil {
		return nil, berr
	}
	return symbol_names_rows_collect(&stmt, a)
}

// like_glob_pattern translates a user glob (`*` wildcard, everything else
// literal) into a LIKE pattern: `*` becomes `%`, while the LIKE
// metacharacters `%`, `_` and the escape character itself are escaped so
// they match literally. Byte-indexed: non-ASCII bytes copy verbatim.
like_glob_pattern :: proc(pattern: string, a: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, len(pattern) + 8, a)
	for i := 0; i < len(pattern); i += 1 {
		switch pattern[i] {
		case '*':
			append(&buf, '%')
		case '%', '_', '\\':
			append(&buf, '\\')
			append(&buf, pattern[i])
		case:
			append(&buf, pattern[i])
		}
	}
	out := strings.clone(transmute(string)(buf[:]), a)
	delete(buf)
	return out
}

// symbol_names_rows_collect steps a prepared six-column symbol_names SELECT
// to exhaustion, cloning every row into `a`; on error the partial set is
// freed through that same allocator.
symbol_names_rows_collect :: proc(stmt: ^Stmt, a: mem.Allocator) -> (rows: []Symbol_Name_Row_With_File, err: platform.Err) {
	dyn := make([dynamic]Symbol_Name_Row_With_File, 0, 8, a)
	for {
		has_row, rerr := stmt_step(stmt)
		if rerr != nil {
			symbol_names_rows_destroy(dyn[:], a)
			return nil, rerr
		}
		if !has_row {
			break
		}
		append(&dyn, Symbol_Name_Row_With_File{
			name   = stmt_column_text_clone(stmt, 0, a),
			kind   = stmt_column_text_clone(stmt, 1, a),
			path   = stmt_column_text_clone(stmt, 2, a),
			hash   = stmt_column_text_clone(stmt, 3, a),
			line   = stmt_column_int(stmt, 4),
			parent = stmt_column_text_clone(stmt, 5, a),
		})
	}
	return dyn[:], nil
}

// symbol_names_distinct_parents returns the distinct parent names of the
// rows named `name` in `path` (case-insensitive on the name), cloned into
// `a` — the one-level step the find handler's name-path chain walk ascends
// through. The empty string in the result marks a top-level row and is the
// root anchor an anchored pattern ("/Foo/bar") verifies against. Free each
// string with delete(s, a) and the slice with delete(slice) (a made dynamic
// frees through its stored allocator); request-arena callers rely on
// free_all instead.
symbol_names_distinct_parents :: proc(db: ^DB, path: string, name: string, a := context.allocator) -> (parents: []string, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT DISTINCT parent FROM symbol_names WHERE name = ?1 COLLATE NOCASE AND path = ?2;")
	if serr != nil {
		return nil, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, name); berr != nil {
		return nil, berr
	}
	if berr := stmt_bind_text(&stmt, 2, path); berr != nil {
		return nil, berr
	}
	dyn := make([dynamic]string, 0, 2, a)
	for {
		has_row, rerr := stmt_step(&stmt)
		if rerr != nil {
			for p in dyn {
				delete(p, a)
			}
			delete(dyn)
			return nil, rerr
		}
		if !has_row {
			break
		}
		append(&dyn, stmt_column_text_clone(&stmt, 0, a))
	}
	return dyn[:], nil
}

// symbol_names_rows_destroy frees the rows symbol_names_lookup cloned
// into the allocator THAT lookup received (bare deletes would free
// through the ambient context allocator instead).
symbol_names_rows_destroy :: proc(rows: []Symbol_Name_Row_With_File, a: mem.Allocator) {
	for i in 0..<len(rows) {
		if rows[i].name != "" {
			delete(rows[i].name, a)
		}
		if rows[i].kind != "" {
			delete(rows[i].kind, a)
		}
		if rows[i].path != "" {
			delete(rows[i].path, a)
		}
		if rows[i].hash != "" {
			delete(rows[i].hash, a)
		}
		if rows[i].parent != "" {
			delete(rows[i].parent, a)
		}
	}
	if rows != nil {
		delete(rows, a)
	}
}

// symbol_cache_get returns the L1 payload for (path, hash), cloned into
// `a`, when present and unexpired at now_ms. This is the direct SQLite
// read; production readers go through symbol_cache_payload (the mirror
// sits in front of it).
symbol_cache_get :: proc(
	db: ^DB,
	path: string,
	hash: string,
	now_ms: i64,
	a := context.allocator,
) -> (payload: []u8, language: string, found: bool, err: platform.Err) {
	payload, language, _, found, err = symbol_cache_row_get(db, path, hash, now_ms, a)
	return payload, language, found, err
}

// SYMBOL_CACHE_ROW_CAP is the persistent symbol-table row cap the startup
// sweep trims to (newest first). The in-memory mirror has its own
// Bounded_Cache budget; this bounds only the on-disk layer.
SYMBOL_CACHE_ROW_CAP :: 32_000

// delete_symbol_path drops every index row for one file path — L0 name
// rows and L1 payload rows, all hashes — in one transaction. The
// structural counterpart to write_symbol_index: a deleted or moved-away
// file stops serving lookups immediately instead of waiting out the TTL
// sweep. The path's mirrored keys drop with the rows.
delete_symbol_path :: proc(db: ^DB, path: string) -> platform.Err {
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	keys, kerr := mirror_keys_for_path(db, path)
	defer delete(keys)
	if kerr != nil {
		return kerr
	}
	if berr := db_exec(db, "BEGIN IMMEDIATE;"); berr != nil {
		return berr
	}
	if derr := delete_path_rows(db, "symbol_names", path); derr != nil {
		return rollback_and(db, derr)
	}
	if derr := delete_path_rows(db, "symbol_cache", path); derr != nil {
		return rollback_and(db, derr)
	}
	if cerr := db_exec(db, "COMMIT;"); cerr != nil {
		return rollback_and(db, cerr)
	}
	mirror_drop_keys(db, keys[:])
	// The fingerprint row remains (a later crawl walk deletes it once the
	// path stays unseen), but its payload rows are gone: liveness dies now
	// so the incremental skip cannot treat the path as still indexed.
	fp_mark_dead(db, path)
	return nil
}

// delete_path_rows deletes one table's rows for a path (txn-internal).
delete_path_rows :: proc(db: ^DB, table: string, path: string) -> platform.Err {
	sql := strings.concatenate({"DELETE FROM ", table, " WHERE path = ?1;"}, context.temp_allocator)
	stmt, err := stmt_prepare(db, sql)
	if err != nil {
		return err
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

// sweep_expired drops symbol cache entries whose TTL has passed, trims to
// the newest-first row cap (0 = no row cap), and removes name rows whose
// cache entry is gone. Called at parent start and once a day. The mirrored
// keys of the deleted rows drop together with them — a mirror entry must
// never out-serve its row.
sweep_expired :: proc(db: ^DB, now_ms: i64, max_rows: int) -> platform.Err {
	// tx_mu across the whole sweep: the key collection reads must not race
	// a concurrent writer's commit, and the DELETEs must not land inside
	// another thread's open transaction.
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	// Collect first, delete after: the keys of the rows being removed are
	// only knowable before the DELETEs run. A failed collection aborts the
	// sweep — the next tick retries with fresh keys.
	expired, eerr := mirror_keys_expired(db, now_ms)
	defer delete(expired)
	if eerr != nil {
		return eerr
	}
	capped, caperr := mirror_keys_beyond_cap(db, max_rows)
	defer delete(capped)
	if caperr != nil {
		return caperr
	}

	now_sql := util.int_to_dec(int(now_ms), context.temp_allocator)
	// One transaction across the three DELETEs: three autocommit writes
	// would take the write lock three times over and leave a partially
	// swept state behind an interrupted run.
	if berr := db_exec(db, "BEGIN IMMEDIATE;"); berr != nil {
		return berr
	}
	if serr := db_exec(db, strings.concatenate({"DELETE FROM symbol_cache WHERE expires_at <= ", now_sql, ";"}, context.temp_allocator)); serr != nil {
		return rollback_and(db, serr)
	}
	if max_rows > 0 {
		cap_sql := util.int_to_dec(max_rows, context.temp_allocator)
		if serr := db_exec(db, strings.concatenate({
			"DELETE FROM symbol_cache WHERE (path, hash) NOT IN (SELECT path, hash FROM symbol_cache ORDER BY created_at DESC LIMIT ",
			cap_sql, ");",
		}, context.temp_allocator)); serr != nil {
			return rollback_and(db, serr)
		}
	}
	if serr := db_exec(db, "DELETE FROM symbol_names WHERE (path, hash) NOT IN (SELECT path, hash FROM symbol_cache);"); serr != nil {
		return rollback_and(db, serr)
	}
	if cerr := db_exec(db, "COMMIT;"); cerr != nil {
		return rollback_and(db, cerr)
	}
	mirror_drop_keys(db, expired[:])
	mirror_drop_keys(db, capped[:])
	// Cap-trimmed rows may carry unexpired deadlines the fingerprint map
	// still holds; deaden those paths so the crawl's skip does not treat
	// them as still indexed (TTL-expired rows self-resolve — the deadline
	// has passed by definition). The mirror key is "path\x00hash": the
	// path is everything before the separator.
	for k in capped {
		if i := strings.index(k, "\x00"); i >= 0 {
			fp_mark_dead(db, k[:i])
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Freelist hygiene
// ---------------------------------------------------------------------------

// Dead-page budget: below it SQLite reuses the pages for future index
// churn; above it the sweep hands them back to the file system, so an
// index-churn high-water cannot strand unbounded dead space in a
// long-lived store (a real one measured 96% dead pages behind an 80 MB
// file).
FREELIST_TRIM_THRESHOLD_BYTES :: 64 * 1024 * 1024

// pragma_int reads one integer-valued pragma. Unlocked like kv_get's
// reads: a threshold check stale by
// one transaction is benign, and the trim's writes take tx_mu themselves.
pragma_int :: proc(db: ^DB, name: string) -> (value: i64, err: platform.Err) {
	stmt, serr := stmt_prepare(db, strings.concatenate({"PRAGMA ", name, ";"}, context.temp_allocator))
	if serr != nil {
		return 0, serr
	}
	defer stmt_finalize(&stmt)
	has_row, rerr := stmt_step(&stmt)
	if rerr != nil {
		return 0, rerr
	}
	if !has_row {
		return 0, platform.Wrapped{
			kind = .Internal,
			msg  = strings.concatenate({"store: pragma returned no row: ", name}, context.temp_allocator),
		}
	}
	return stmt_column_int(&stmt, 0), nil
}

// freelist_trim returns dead pages to the file system once they exceed
// threshold_bytes. A store opened by this build carries
// auto_vacuum = INCREMENTAL (db_open), so the trim is one bounded
// incremental_vacuum. The daemon's sweep thread calls this daily;
// a failure leaves the dead pages in place for the next tick.
freelist_trim :: proc(db: ^DB, threshold_bytes := FREELIST_TRIM_THRESHOLD_BYTES) -> platform.Err {
	pages, perr := pragma_int(db, "freelist_count")
	if perr != nil {
		return perr
	}
	if pages <= 0 {
		return nil
	}
	page_size, serr := pragma_int(db, "page_size")
	if serr != nil {
		return serr
	}
	if pages * page_size < i64(threshold_bytes) {
		return nil
	}
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	return db_exec(db, "PRAGMA incremental_vacuum;")
}

// err_msg renders the connection's SQLite error text. The result is
// temp-allocator scratch the caller weaves into a Wrapped message
// immediately (the package convention for error strings).
err_msg :: proc(db: ^DB, prefix: string) -> string {
	msg := "unknown error"
	if db != nil && db.handle != nil {
		c := sqlite3_errmsg(db.handle)
		if c != nil {
			msg = string(c)
		}
	}
	return strings.concatenate({prefix, ": ", msg}, context.temp_allocator)
}

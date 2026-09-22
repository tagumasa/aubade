package store

import "base:runtime"
import "core:strings"
import "core:sync"
import "src:platform"
import "src:util"

// Tracker events (the incident/sprint event stream). The table is the single
// source of truth: one transaction per event, append-only, read order is
// ORDER BY uid (the uid's fixed-width hex makes lexicographic == numeric
// order, so uid comparison is the stream's total order).

Event_Row :: struct {
	uid:     string,
	ts:      i64, // wall-clock ms UTC — ordering is by uid, not this field
	origin:  string,
	kind:    string,
	version: int,
	payload: string, // kind-specific JSON
}

// events_append writes one event in its own transaction. A uid that already
// exists returns .Invalid — ON CONFLICT DO NOTHING plus the change counter is
// the typed duplicate detection (no sqlite errmsg matching).
events_append :: proc(db: ^DB, row: ^Event_Row) -> platform.Err {
	// tx_mu spans the whole BEGIN..COMMIT (the DB struct comment): the
	// event stream is appended from request threads while index writers
	// run on others.
	sync.mutex_lock(&db.tx_mu)
	defer sync.mutex_unlock(&db.tx_mu)
	if berr := db_exec(db, "BEGIN IMMEDIATE;"); berr != nil {
		return berr
	}
	if err := events_append_txn(db, row); err != nil {
		return rollback_and(db, err)
	}
	if cerr := db_exec(db, "COMMIT;"); cerr != nil {
		return rollback_and(db, cerr)
	}
	return nil
}

events_append_txn :: proc(db: ^DB, row: ^Event_Row) -> platform.Err {
	stmt, serr := stmt_prepare(db, "INSERT INTO events (uid, ts, origin, kind, version, payload) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(uid) DO NOTHING;")
	if serr != nil {
		return serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, row.uid); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&stmt, 2, row.ts); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&stmt, 3, row.origin); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&stmt, 4, row.kind); berr != nil {
		return berr
	}
	if berr := stmt_bind_int(&stmt, 5, i64(row.version)); berr != nil {
		return berr
	}
	if berr := stmt_bind_text(&stmt, 6, row.payload); berr != nil {
		return berr
	}
	if _, rerr := stmt_step(&stmt); rerr != nil {
		return rerr
	}
	if sqlite3_changes(db.handle) == 0 {
		return platform.Wrapped{kind = .Invalid, msg = "store: duplicate event uid"}
	}
	return nil
}

// events_read_all returns the whole stream in uid order. All strings are
// cloned into a; destroy with events_rows_destroy.
// event_row_from_stmt materializes one events-table row; the SELECT's
// column order (uid, ts, origin, kind, version, payload) is fixed by
// every reader in this file.
event_row_from_stmt :: proc(stmt: ^Stmt, a: runtime.Allocator) -> Event_Row {
	return Event_Row{
		uid     = stmt_column_text_clone(stmt, 0, a),
		ts      = stmt_column_int(stmt, 1),
		origin  = stmt_column_text_clone(stmt, 2, a),
		kind    = stmt_column_text_clone(stmt, 3, a),
		version = int(stmt_column_int(stmt, 4)),
		payload = stmt_column_text_clone(stmt, 5, a),
	}
}

events_read_all :: proc(db: ^DB, a := context.allocator) -> (rows: []Event_Row, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT uid, ts, origin, kind, version, payload FROM events ORDER BY uid ASC;")
	if serr != nil {
		return nil, serr
	}
	defer stmt_finalize(&stmt)
	dyn := make([dynamic]Event_Row, 0, 64, a)
	for {
		has_row, rerr := stmt_step(&stmt)
		if rerr != nil {
			events_rows_destroy(dyn[:], a)
			return nil, rerr
		}
		if !has_row {
			break
		}
		append(&dyn, event_row_from_stmt(&stmt, a))
	}
	// A plain owned slice, not a dynamic view: destroy must free the
	// backing through the same allocator that made it.
	out := make([]Event_Row, len(dyn), a)
	for r, i in dyn {
		out[i] = r
	}
	delete(dyn)
	return out, nil
}

events_rows_destroy :: proc(rows: []Event_Row, a := context.allocator) {
	for i in 0..<len(rows) {
		if rows[i].uid != "" {
			delete(rows[i].uid, a)
		}
		if rows[i].origin != "" {
			delete(rows[i].origin, a)
		}
		if rows[i].kind != "" {
			delete(rows[i].kind, a)
		}
		if rows[i].payload != "" {
			delete(rows[i].payload, a)
		}
	}
	if rows != nil {
		delete(rows, a)
	}
}

// events_read_after returns the rows with uid strictly greater than
// after_uid, in stream order — the incremental-refold tail read. The
// watermark comes from a persisted fold snapshot; uid order is the
// stream order. Destroy with events_rows_destroy.
events_read_after :: proc(db: ^DB, after_uid: string, a := context.allocator) -> (rows: []Event_Row, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT uid, ts, origin, kind, version, payload FROM events WHERE uid > ?1 ORDER BY uid ASC;")
	if serr != nil {
		return nil, serr
	}
	defer stmt_finalize(&stmt)
	if berr := stmt_bind_text(&stmt, 1, after_uid); berr != nil {
		return nil, berr
	}
	dyn := make([dynamic]Event_Row, 0, 64, a)
	for {
		has_row, rerr := stmt_step(&stmt)
		if rerr != nil {
			events_rows_destroy(dyn[:], a)
			return nil, rerr
		}
		if !has_row {
			break
		}
		append(&dyn, event_row_from_stmt(&stmt, a))
	}
	out := make([]Event_Row, len(dyn), a)
	for r, i in dyn {
		out[i] = r
	}
	delete(dyn)
	return out, nil
}

// events_last_uid returns the greatest uid in the stream (the events_uid
// index walked backwards; fixed-width hex makes the lexicographic max
// the stream max). The snapshot staleness guard compares it against a
// snapshot's watermark.
events_last_uid :: proc(db: ^DB, a := context.allocator) -> (uid: string, found: bool, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT uid FROM events ORDER BY uid DESC LIMIT 1;")
	if serr != nil {
		return "", false, serr
	}
	defer stmt_finalize(&stmt)
	has_row, rerr := stmt_step(&stmt)
	if rerr != nil {
		return "", false, rerr
	}
	if !has_row {
		return "", false, nil
	}
	return stmt_column_text_clone(&stmt, 0, a), true, nil
}

// events_count returns the number of stored events (startup diagnostics).
events_count :: proc(db: ^DB) -> (n: i64, err: platform.Err) {
	stmt, serr := stmt_prepare(db, "SELECT COUNT(*) FROM events;")
	if serr != nil {
		return 0, serr
	}
	defer stmt_finalize(&stmt)
	has_row, rerr := stmt_step(&stmt)
	if rerr != nil {
		return 0, rerr
	}
	if !has_row {
		return 0, nil
	}
	return stmt_column_int(&stmt, 0), nil
}

// event_payload_by_uid fetches one event's payload JSON by uid (detail
// rendering walks the fold's event references through this).
event_payload_by_uid :: proc(db: ^DB, uid: string, a := context.allocator) -> (payload: string, found: bool, err: platform.Err) {
	return query_one_text(db, "SELECT payload FROM events WHERE uid = ?1;", uid, a)
}

// events_payloads_by_uids loads many payloads in one statement per chunk —
// the detail renderer's batch path (one round trip replaces one SELECT per
// event reference, which the export multiplied by sprints × incidents).
// The chunk size is fixed and a partial chunk is padded by repeating its
// last uid, so exactly one prepared-statement shape is ever cached. Keys
// and payloads are cloned into a (the detail path passes the request temp
// allocator — the same lifetime discipline as event_payload_by_uid).
EVENTS_FETCH_CHUNK :: 128

events_payloads_by_uids :: proc(db: ^DB, uids: []string, a := context.allocator) -> (payloads: map[string]string, err: platform.Err) {
	payloads = make(map[string]string, len(uids), a)
	if len(uids) == 0 {
		return payloads, nil
	}
	sql := events_fetch_chunk_sql(EVENTS_FETCH_CHUNK)
	for start := 0; start < len(uids); start += EVENTS_FETCH_CHUNK {
		stmt, serr := stmt_prepare(db, sql)
		if serr != nil {
			return payloads, serr
		}
		end := min(start + EVENTS_FETCH_CHUNK, len(uids))
		for i := 0; i < EVENTS_FETCH_CHUNK; i += 1 {
			uid := uids[end - 1]
			if start + i < end {
				uid = uids[start + i]
			}
			if berr := stmt_bind_text(&stmt, cast(i32)(i + 1), uid); berr != nil {
				stmt_finalize(&stmt)
				return payloads, berr
			}
		}
		for {
			has_row, rerr := stmt_step(&stmt)
			if rerr != nil {
				stmt_finalize(&stmt)
				return payloads, rerr
			}
			if !has_row {
				break
			}
			uid := stmt_column_text_clone(&stmt, 0, a)
			payloads[uid] = stmt_column_text_clone(&stmt, 1, a)
		}
		stmt_finalize(&stmt)
	}
	return payloads, nil
}

// events_fetch_chunk_sql renders the fixed-shape IN list for the batch
// fetch ("?1, ?2, ... ?n"). Temp-allocator scratch: stmt_prepare clones
// the key it caches, so the view only has to outlive the call.
events_fetch_chunk_sql :: proc(n: int) -> string {
	parts := make([dynamic]string, 0, n + 3, context.temp_allocator)
	append(&parts, "SELECT uid, payload FROM events WHERE uid IN (?")
	append(&parts, util.int_to_dec(1, context.temp_allocator))
	for i := 2; i <= n; i += 1 {
		append(&parts, ", ?")
		append(&parts, util.int_to_dec(i, context.temp_allocator))
	}
	append(&parts, ");")
	sql := strings.concatenate(parts[:], context.temp_allocator)
	delete(parts)
	return sql
}

// The document-sync svc face: a child's open/change/close drives the
// daemon's editor buffers. Driving the buffer layer IS the integration —
// the one installed buffer listener (the editor→services bridge) turns
// every applied open/change/close into the real-server transfer, the hot
// pin/edit/unpin, and the index-row rewrite, so this face never installs
// a listener of its own and never touches those layers directly.
//
// Changes coalesce latest-wins per document at this receive boundary: the
// pending slot holds only the newest (version, full text) and a single
// worker applies queued entries one at a time, so the apply rate, not the
// arrival rate, bounds the work. An open or change request is answered
// when its version applied or was superseded — a newer full text replaced
// it in the slot, or the document's version stream moved on — and a
// refused or dropped change recovers through the next full text, because
// Full sync carries state, not history. Every apply records the document's
// last applied version in the same file-lock critical section that
// installs the new buffer contents, so the version home (read by later
// computation faces) never leads the bytes it describes, and it survives
// editor-buffer eviction: it is document state, not buffer state.
package svc

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

import "src:editor"
import "src:platform"
import "src:safety"

METHOD_DOC_OPEN        :: "svc.doc/open"        // {relative_path, language_id?, version, content} -> {version, superseded}
METHOD_DOC_CHANGE      :: "svc.doc/change"      // {relative_path, version, content} -> {version, superseded}
METHOD_DOC_CLOSE       :: "svc.doc/close"       // {relative_path} -> {}
METHOD_DOC_HIGHLIGHTS  :: "svc.doc/highlights"  // {relative_path} -> {version, has_version, decline, captures}
METHOD_DOC_DIAGNOSTICS :: "svc.doc/diagnostics" // {relative_path} -> {version, has_version, decline, truncated, diagnostics}

// The open-document table's bound. The face is mutating and long-lived
// daemon state, so the table is capped like every other collection: a full
// table refuses new opens (retryable — the client closes documents and
// retries) instead of growing without bound. It is independent of the
// editor buffer LRU, whose entries come and go under eviction while their
// documents stay open.
DOC_SYNC_MAX_DOCUMENTS :: 256

// An apply wait is bounded: an open/change that neither applies nor is
// superseded within this budget fails with a retryable timeout, and the
// next full text recovers the document. The single worker serializes all
// documents, so the budget covers a backlog of other files' applies.
DOC_SYNC_APPLY_DEADLINE_MS :: 10_000

// Cond wake slice for the request waits. Every state change broadcasts;
// the slice only bounds how long a parked request can miss a token fire
// or its deadline in an otherwise silent face — the worker parks on the
// plain cond wait (its two interests, pending text and the stop flag, are
// both broadcast).
DOC_SYNC_WAIT_SLICE_MS :: 50

// The client document version's wire range (an LSP document version is an
// i32; the wire carries a JSON integer).
DOC_SYNC_VERSION_MIN :: -2147483648
DOC_SYNC_VERSION_MAX :: 2147483647

// Doc_Sync_Pending is the per-document latest-wins slot: at most one
// queued full text, always the newest submitted for its version stream.
Doc_Sync_Pending :: struct {
	stream:  u64,
	version: i32,
	is_open: bool,
	text:    string, // owned clone; moved out to the applying item at pickup
}

// Doc_Sync_Doc is one document's face state. Entries are only touched
// under Doc_Sync.mu; `waiters` keeps an entry alive while a parked request
// can still wake holding its pointer (a cond wait releases the mutex, so
// another thread may free between the wakes unless the count forbids it).
Doc_Sync_Doc :: struct {
	key:         string, // folded spelling; the docs map key (owned clone)
	rel_path:    string, // normalized spelling used for editor ops and listener events (owned clone)
	language_id: string, // owned clone; "" when the opener sent none
	stream:      u64, // bumped by every open: versions are monotonic within one open only
	// The version home: the last version whose full text was applied to
	// the buffer, recorded atomically with the apply (the file-lock
	// section in doc_sync_apply_under_file_lock).
	last_applied_version: i32,
	has_version:          bool,
	// The supersede watermark: the newest version replaced in-slot within
	// this stream. A request at or below it answers immediately — its text
	// will never apply.
	watermark:     i32,
	has_watermark: bool,
	is_closed:     bool, // close recorded; the entry frees once no waiter remains
	waiters:       int,
	has_pending:   bool,
	pending:       Doc_Sync_Pending,
	// The two-writer owner: the daemon connection id of the lsp
	// child that last didOpen'd the document (last open wins). 0 = no
	// editor owns it — direct buffer writes and synchronous saves apply.
	// Cleared with the whole entry when the owner closes the document or
	// disconnects.
	owner: int,
}

// Doc_Sync_Item is one pending entry moved out of its slot for apply: the
// text's ownership transfers from the slot to the item, so a newer submit
// replacing the slot cannot free the bytes mid-apply.
Doc_Sync_Item :: struct {
	key:      string, // owned clone (the entry may free while the apply runs)
	rel_path: string, // owned clone
	stream:   u64,
	version:  i32,
	is_open:  bool,
	text:     string, // moved from the slot; freed with the item
}

// Doc_Sync_Outcome is an answered open/change: `version` is the document's
// last applied version at answer time (meaningful only with has_version —
// a superseded open can answer before anything applied), and `superseded`
// marks an answer given without this request's own text having applied.
Doc_Sync_Outcome :: struct {
	version:     i32,
	has_version: bool,
	superseded:  bool,
}

// Doc_Sync is the face state. Lock order: the editor's per-file lock
// (File_Lock.mu) -> Doc_Sync.mu, never the reverse — no path holds
// Doc_Sync.mu across an editor lock (the close path drops the buffer
// strictly after releasing it).
Doc_Sync :: struct {
	project_root: string, // absolute, owned clone (containment checks)
	ed:           ^editor.Editor,
	docs:         map[string]^Doc_Sync_Doc,
	mu:           sync.Mutex, // guards the table and every per-entry field
	work:         sync.Cond,  // broadcast on submit, pickup, apply, answer, close, stop
	is_stopping:  bool,
	// The stream-number source (guarded by mu). Streams identify a
	// document GENERATION, and a generation's number must stay unique for
	// the face's lifetime: a close frees an entry nobody waits on, and a
	// per-entry counter would restart at a value an in-flight apply item
	// still carries — the record check would match the wrong generation.
	// Both open and close consume from this counter, so no number is ever
	// handed out twice.
	next_stream: u64,
	allocator:   runtime.Allocator,
}

doc_sync_init :: proc(ds: ^Doc_Sync, project_root: string, ed: ^editor.Editor, a := context.allocator) {
	ds^ = {
		project_root = strings.clone(project_root, a),
		ed           = ed,
		docs         = make(map[string]^Doc_Sync_Doc, 8, a),
		allocator    = a,
	}
}

// doc_sync_destroy frees the table. Call it only after the worker left
// (doc_sync_stop + join) and no request can still be parked: parked
// waiters hold entry pointers this free would dangle.
doc_sync_destroy :: proc(ds: ^Doc_Sync) {
	entries := ds.docs
	for _, e in entries {
		if e.has_pending && e.pending.text != "" {
			delete(e.pending.text, ds.allocator)
		}
		if e.key != "" {
			delete(e.key, ds.allocator)
		}
		if e.rel_path != "" {
			delete(e.rel_path, ds.allocator)
		}
		if e.language_id != "" {
			delete(e.language_id, ds.allocator)
		}
		free(e, ds.allocator)
	}
	delete(entries)
	if ds.project_root != "" {
		delete(ds.project_root, ds.allocator)
	}
	ds^ = {}
}

// doc_sync_check_path normalizes a caller-supplied path and refuses
// anything outside the project root. The normalized spelling is cloned
// into `a` (the request arena); the apply paths use the stored copy, so
// containment is judged once here.
doc_sync_check_path :: proc(ds: ^Doc_Sync, rel_in: string, a: mem.Allocator) -> (rel: string, err: platform.Err) {
	rel_norm := normalize_rel(rel_in, context.temp_allocator)
	if rel_norm == "" {
		return "", wrapped_err(.Invalid, "relative_path is required", a)
	}
	if _, pres := safety.pathguard_validate_contained(ds.project_root, rel_norm, context.temp_allocator); pres.reason != "" {
		return "", wrapped_err(.Invalid, strings.concatenate({"invalid relative path: ", pres.reason}, a), a)
	}
	return strings.clone(rel_norm, a), nil
}

// doc_sync_check_version rejects an out-of-range client version at the
// face boundary; the wire integer is 64-bit but a document version is an
// i32 on both LSP sides.
doc_sync_check_version :: proc(version: i64, a: mem.Allocator) -> (i32, platform.Err) {
	if version < DOC_SYNC_VERSION_MIN || version > DOC_SYNC_VERSION_MAX {
		return 0, wrapped_err(.Invalid, "version is outside the 32-bit document-version range", a)
	}
	return i32(version), nil
}

// doc_sync_check_content refuses documents beyond the editor's own read
// bound: the buffer layer could not re-read them coherently, and the L2
// gate below the listener tombstones them anyway.
doc_sync_check_content :: proc(text: string, a: mem.Allocator) -> platform.Err {
	if len(text) > editor.MAX_FILE_BYTES {
		return wrapped_err(.Invalid, "content exceeds the document size bound", a)
	}
	return nil
}

// doc_sync_entry_free_locked removes a closed entry nobody waits on. The
// delete_key's handed-back key is deliberately discarded: it is the
// entry's own key clone, freed through e.key below.
doc_sync_entry_free_locked :: proc(ds: ^Doc_Sync, e: ^Doc_Sync_Doc) {
	if !e.is_closed || e.waiters > 0 {
		return
	}
	delete_key(&ds.docs, e.key)
	if e.has_pending && e.pending.text != "" {
		delete(e.pending.text, ds.allocator)
	}
	delete(e.key, ds.allocator)
	delete(e.rel_path, ds.allocator)
	if e.language_id != "" {
		delete(e.language_id, ds.allocator)
	}
	free(e, ds.allocator)
}

// doc_sync_result_locked computes a parked request's answer state.
// Callers hold Doc_Sync.mu. done answers the request; superseded marks
// the answers given without the request's own text having applied.
doc_sync_result_locked :: proc(e: ^Doc_Sync_Doc, stream: u64, version: i32) -> (done: bool, superseded: bool) {
	if e.stream != stream || e.is_closed {
		// The stream moved on (a re-open or a close): this text belongs to
		// a document generation that ended and will never apply.
		return true, true
	}
	if e.has_version && e.last_applied_version >= version {
		return true, e.has_watermark && e.watermark >= version
	}
	if e.has_watermark && e.watermark >= version {
		// Replaced in the slot by a newer full text before pickup.
		return true, true
	}
	if e.has_pending && e.pending.stream == stream && e.pending.version > version {
		// A newer full text is queued ahead of this one; the answer's
		// version field carries the truth, so answering now is safe.
		return true, true
	}
	return false, false
}

// doc_sync_wait parks until the request (stream, version) is answered:
// applied, superseded, the caller's token fired, the deadline passed, or
// the worker stopped. Called and returned with Doc_Sync.mu held; the wait
// loop re-checks every wake, so no outcome can be missed between the
// broadcast and the re-acquire.
doc_sync_wait :: proc(
	ds: ^Doc_Sync,
	e: ^Doc_Sync_Doc,
	stream: u64,
	version: i32,
	token: ^platform.Cancel_Token,
	deadline_ms: i64,
	a: mem.Allocator,
) -> (Doc_Sync_Outcome, platform.Err) {
	for {
		if done, superseded := doc_sync_result_locked(e, stream, version); done {
			return {version = e.last_applied_version, has_version = e.has_version, superseded = superseded}, nil
		}
		if ds.is_stopping {
			return {}, wrapped_err(.Cancelled, "document sync is stopping", a)
		}
		if token != nil {
			if terr, fired := platform.token_check(token); fired {
				return {}, terr
			}
		}
		if platform.mono_ms() >= deadline_ms {
			return {}, wrapped_err(.Retryable, "document change did not apply within its deadline", a)
		}
		sync.cond_wait_with_timeout(&ds.work, &ds.mu, time.Duration(DOC_SYNC_WAIT_SLICE_MS * 1_000_000))
	}
}

// doc_sync_put_locked installs text as the entry's pending slot content,
// superseding an older same-stream pending in place (its watermark moves
// so its request answers immediately). A different stream's pending is
// dropped outright — its waiters wake to the stream change. Caller holds
// Doc_Sync.mu.
doc_sync_put_locked :: proc(ds: ^Doc_Sync, e: ^Doc_Sync_Doc, stream: u64, version: i32, text: string, is_open: bool) {
	if e.has_pending {
		if e.pending.stream == stream {
			e.watermark = e.pending.version
			e.has_watermark = true
		}
		if e.pending.text != "" {
			delete(e.pending.text, ds.allocator)
		}
	}
	e.pending = Doc_Sync_Pending{stream = stream, version = version, is_open = is_open, text = strings.clone(text, ds.allocator)}
	e.has_pending = true
	sync.cond_broadcast(&ds.work)
}

// doc_sync_open registers the document (a fresh version stream per open)
// and queues the client's full text as the buffer's content. It answers
// once the open applied or was superseded — the open IS the document's
// first state, so on a plain success the buffer carries the text.
// `owner` records the didOpen sender as the document's two-writer owner
// when it is an lsp-mode child (last open wins); 0 keeps the document
// unowned (direct writes and synchronous saves apply).
doc_sync_open :: proc(
	ds: ^Doc_Sync,
	rel_in: string,
	language_id: string,
	version: i32,
	text: string,
	token: ^platform.Cancel_Token,
	deadline_ms: i64,
	a: mem.Allocator,
	owner: int = 0,
) -> (Doc_Sync_Outcome, platform.Err) {
	rel, perr := doc_sync_check_path(ds, rel_in, a)
	if perr != nil {
		return {}, perr
	}
	if cerr := doc_sync_check_content(text, a); cerr != nil {
		return {}, cerr
	}
	sync.mutex_lock(&ds.mu)
	key := platform.path_fold(rel, context.temp_allocator)
	e := ds.docs[key]
	if e == nil {
		if len(ds.docs) >= DOC_SYNC_MAX_DOCUMENTS {
			sync.mutex_unlock(&ds.mu)
			return {}, wrapped_err(.Retryable, "too many open documents", a)
		}
		e = new(Doc_Sync_Doc, ds.allocator)
		e^ = {
			key      = strings.clone(key, ds.allocator),
			rel_path = strings.clone(rel, ds.allocator),
		}
		ds.docs[e.key] = e
	}
	// An open restarts the version stream: queued older-stream text is
	// dropped wholesale (its waiters wake to the stream change) and the
	// applied-version record waits for this stream's first apply. The new
	// stream comes from the face's counter — unique across every entry
	// generation, so an in-flight item of an earlier generation can never
	// match it (see Doc_Sync.next_stream).
	e.stream = ds.next_stream
	ds.next_stream += 1
	stream := e.stream
	if e.language_id != "" {
		delete(e.language_id, ds.allocator)
	}
	e.language_id = strings.clone(language_id, ds.allocator)
	e.last_applied_version = 0
	e.has_version = false
	e.has_watermark = false
	e.is_closed = false
	// Last didOpen wins: a re-open by another lsp child hands the
	// ownership over; a non-lsp open (owner 0) releases it.
	e.owner = owner
	e.waiters += 1
	doc_sync_put_locked(ds, e, stream, version, text, true)
	outcome, werr := doc_sync_wait(ds, e, stream, version, token, deadline_ms, a)
	e.waiters -= 1
	doc_sync_entry_free_locked(ds, e)
	sync.mutex_unlock(&ds.mu)
	return outcome, werr
}

// doc_sync_change queues a newer full text for an open document and
// answers on apply or supersede. A stale change (its version already
// covered by the applied record) answers immediately as superseded.
doc_sync_change :: proc(
	ds: ^Doc_Sync,
	rel_in: string,
	version: i32,
	text: string,
	token: ^platform.Cancel_Token,
	deadline_ms: i64,
	a: mem.Allocator,
) -> (Doc_Sync_Outcome, platform.Err) {
	rel, perr := doc_sync_check_path(ds, rel_in, a)
	if perr != nil {
		return {}, perr
	}
	if cerr := doc_sync_check_content(text, a); cerr != nil {
		return {}, cerr
	}
	sync.mutex_lock(&ds.mu)
	key := platform.path_fold(rel, context.temp_allocator)
	e := ds.docs[key]
	if e == nil || e.is_closed {
		msg := strings.concatenate({"document is not open: ", rel}, a)
		sync.mutex_unlock(&ds.mu)
		return {}, wrapped_err(.Invalid, msg, a)
	}
	if e.has_version && version <= e.last_applied_version {
		outcome := Doc_Sync_Outcome{version = e.last_applied_version, has_version = true, superseded = true}
		sync.mutex_unlock(&ds.mu)
		return outcome, nil
	}
	e.waiters += 1
	stream := e.stream
	doc_sync_put_locked(ds, e, stream, version, text, false)
	outcome, werr := doc_sync_wait(ds, e, stream, version, token, deadline_ms, a)
	e.waiters -= 1
	doc_sync_entry_free_locked(ds, e)
	sync.mutex_unlock(&ds.mu)
	return outcome, werr
}

// doc_sync_close ends the document's open state: the version record clears
// with the stream bump, queued text drops (its requests answer as
// superseded), and the buffer reverts to disk truth through the editor's
// ordinary drop path — the close notification that fires there unpins the
// hot tree and didCloses real servers. Closing an unknown or already
// closed document succeeds (idempotent, the way editors re-sync after a
// restart); closing a document whose buffer an eviction already dropped
// is the same no-op drop. The drop runs strictly outside Doc_Sync.mu, and
// only after a re-check under mu confirms the document did not re-open in
// the window between the close concluding and the drop running. `closer`
// scopes the close to the owner: a non-owner child's
// didClose leaves the document open for the child that last didOpen'd it.
doc_sync_close :: proc(ds: ^Doc_Sync, rel_in: string, a: mem.Allocator, closer: int = 0) -> platform.Err {
	rel, perr := doc_sync_check_path(ds, rel_in, a)
	if perr != nil {
		return perr
	}
	sync.mutex_lock(&ds.mu)
	key := platform.path_fold(rel, context.temp_allocator)
	e := ds.docs[key]
	if e != nil && e.owner != 0 && closer != e.owner {
		// Not the owner's close: the document stays open for its owner.
		sync.mutex_unlock(&ds.mu)
		return nil
	}
	if e != nil {
		// The close consumes a stream number of its own: items of the
		// closing generation must not match the entry again, including
		// when it survives its waiters — and a freed entry's replacement
		// draws a fresh number too, so neither path can repeat one.
		e.stream = ds.next_stream
		ds.next_stream += 1
		e.is_closed = true
		e.owner = 0
		e.last_applied_version = 0
		e.has_version = false
		e.has_watermark = false
		if e.has_pending {
			if e.pending.text != "" {
				delete(e.pending.text, ds.allocator)
			}
			e.pending.text = ""
			e.has_pending = false
		}
		sync.cond_broadcast(&ds.work)
		doc_sync_entry_free_locked(ds, e)
	}
	sync.mutex_unlock(&ds.mu)
	// A re-open completing between the unlock above and the drop would see
	// its fresh buffer dropped by the close that already concluded: re-read
	// the open state under mu and skip the drop once a live entry exists
	// again. The drop itself stays outside Doc_Sync.mu (the lock-order
	// rule — its close notification takes the editor's file lock).
	sync.mutex_lock(&ds.mu)
	live := ds.docs[key]
	reopened := live != nil && !live.is_closed
	sync.mutex_unlock(&ds.mu)
	if !reopened {
		editor.editor_drop_buffer(ds.ed, rel)
	}
	return nil
}

// doc_sync_last_applied_version reads the version home: the last version
// applied to the document's buffer, surviving editor-buffer eviction.
// has=false for an unknown or closed document.
doc_sync_last_applied_version :: proc(ds: ^Doc_Sync, rel_in: string) -> (version: i32, has: bool) {
	key := platform.path_fold(normalize_rel(rel_in, context.temp_allocator), context.temp_allocator)
	sync.mutex_lock(&ds.mu)
	if e := ds.docs[key]; e != nil && e.has_version {
		version, has = e.last_applied_version, true
	}
	sync.mutex_unlock(&ds.mu)
	return
}

// doc_sync_owner_of reports the document's two-writer owner: the daemon
// connection id of the lsp child that last didOpen'd it. has=false for an
// unknown, closed, or unowned document.
doc_sync_owner_of :: proc(ds: ^Doc_Sync, rel_in: string) -> (owner: int, has: bool) {
	key := platform.path_fold(normalize_rel(rel_in, context.temp_allocator), context.temp_allocator)
	sync.mutex_lock(&ds.mu)
	if e := ds.docs[key]; e != nil && !e.is_closed && e.owner != 0 {
		owner, has = e.owner, true
	}
	sync.mutex_unlock(&ds.mu)
	return
}

// doc_sync_owner_disconnected returns every document the gone child owned
// to the non-open state: each entry closes exactly like the owner's own
// didClose — the version record clears, queued text answers as superseded,
// and the buffer reverts to disk truth, resuming direct writes and
// synchronous saves. The closes run outside Doc_Sync.mu (the buffered rel
// spellings are the entry's own, cloned for the wait). The procedure resets
// the CALLING thread's temp allocator on the way out: callers must hold no
// live temp-allocator data across the call.
doc_sync_owner_disconnected :: proc(ds: ^Doc_Sync, conn_id: int) {
	rels := make([dynamic]string, 0, 4, context.temp_allocator)
	sync.mutex_lock(&ds.mu)
	for _, e in ds.docs {
		if !e.is_closed && e.owner == conn_id {
			append(&rels, strings.clone(e.rel_path, context.temp_allocator))
		}
	}
	sync.mutex_unlock(&ds.mu)
	for rel in rels {
		doc_sync_close(ds, rel, context.temp_allocator, conn_id)
	}
	// The scratch above dies wholesale here (free_all subsumes the
	// per-element deletes).
	free_all(context.temp_allocator)
}

// doc_sync_edit_view reads the document's current text, version, and owner
// TOGETHER — one hold of the file lock and Doc_Sync.mu — so an edit
// computed from `text` is admitted against exactly `version`: the text and
// its version are one read. The text is cloned into `a` (the
// request arena). ok=false names the shapes with nothing to compute
// against: an unknown, closed, or unowned document, or one whose buffer an
// eviction dropped (the direct path's own guards degrade safely there).
doc_sync_edit_view :: proc(ds: ^Doc_Sync, ed: ^editor.Editor, rel_in: string, a: mem.Allocator) -> (text: string, version: i32, has_version: bool, owner: int, ok: bool) {
	rel := normalize_rel(rel_in, context.temp_allocator)
	if rel == "" {
		return
	}
	key := platform.path_fold(rel, context.temp_allocator)
	// Lock order is the apply path's: file lock -> Doc_Sync.mu, never the
	// reverse. Under both, the buffer bytes and the version record are one
	// state (the apply writes them inside the same critical section).
	h := editor.file_lock(ed, rel)
	defer editor.file_release(ed, rel)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)
	sync.mutex_lock(&ds.mu)
	defer sync.mutex_unlock(&ds.mu)
	e := ds.docs[key]
	if e == nil || e.is_closed || e.owner == 0 {
		return
	}
	// The buffers map is e.mu-guarded (the editor's leaf lock; order
	// file-lock -> e.mu, the edit paths' order): a concurrent open of
	// another file inserts under e.mu alone, so the lookup takes it too.
	sync.mutex_lock(&ed.mu)
	buf, found := ed.buffers[key]
	sync.mutex_unlock(&ed.mu)
	if !found {
		return
	}
	text = strings.clone(buf.contents, a)
	version, has_version, owner, ok = e.last_applied_version, e.has_version, e.owner, true
	return
}

// doc_sync_wait_version_past parks until the document's last applied
// version moves strictly past `version` (the round trip's confirmation and
// its catch-up wait), the document leaves the open set (no
// catch-up can ever arrive), or the deadline passes. Reports whether the
// version advanced.
doc_sync_wait_version_past :: proc(ds: ^Doc_Sync, rel_in: string, version: i32, deadline_ms: i64) -> bool {
	key := platform.path_fold(normalize_rel(rel_in, context.temp_allocator), context.temp_allocator)
	sync.mutex_lock(&ds.mu)
	defer sync.mutex_unlock(&ds.mu)
	for {
		e := ds.docs[key]
		if e != nil && e.has_version && e.last_applied_version > version {
			return true
		}
		if e == nil || e.is_closed {
			return false
		}
		if platform.mono_ms() >= deadline_ms {
			return false
		}
		sync.cond_wait_with_timeout(&ds.work, &ds.mu, time.Duration(DOC_SYNC_WAIT_SLICE_MS * 1_000_000))
	}
}

// ---------------------------------------------------------------------------
// The single apply worker
// ---------------------------------------------------------------------------

// doc_sync_has_pending_locked reports whether any document carries queued
// text (caller holds Doc_Sync.mu).
doc_sync_has_pending_locked :: proc(ds: ^Doc_Sync) -> bool {
	for _, e in ds.docs {
		if e.has_pending {
			return true
		}
	}
	return false
}

// doc_sync_take_locked moves one pending entry out of its slot: the text's
// ownership transfers to the item, so the apply runs against bytes no
// newer submit can free. Caller holds Doc_Sync.mu.
doc_sync_take_locked :: proc(ds: ^Doc_Sync) -> (item: Doc_Sync_Item, ok: bool) {
	for _, e in ds.docs {
		if !e.has_pending {
			continue
		}
		item = Doc_Sync_Item{
			key      = strings.clone(e.key, ds.allocator),
			rel_path = strings.clone(e.rel_path, ds.allocator),
			stream   = e.pending.stream,
			version  = e.pending.version,
			is_open  = e.pending.is_open,
			text     = e.pending.text,
		}
		e.pending.text = ""
		e.has_pending = false
		// Waiters whose text just left the slot re-check: the answer now
		// waits on the apply completing, not on the slot contents.
		sync.cond_broadcast(&ds.work)
		return item, true
	}
	return item, false
}

doc_sync_item_destroy :: proc(ds: ^Doc_Sync, item: ^Doc_Sync_Item) {
	if item.key != "" {
		delete(item.key, ds.allocator)
	}
	if item.rel_path != "" {
		delete(item.rel_path, ds.allocator)
	}
	if item.text != "" {
		delete(item.text, ds.allocator)
	}
	item^ = {}
}

// doc_sync_apply_item applies one item through the editor buffer layer and
// prunes the buffer bound afterwards, outside every editor lock (the same
// ordering the edit paths reach with their first-registered defer).
doc_sync_apply_item :: proc(ds: ^Doc_Sync, item: ^Doc_Sync_Item) {
	doc_sync_apply_under_file_lock(ds, item)
	editor.editor_prune_buffers(ds.ed, item.rel_path)
}

// doc_sync_apply_under_file_lock drives one buffer adopt with the version
// record in the same file-lock critical section. A stale item — its
// document closed or re-opened while this apply waited for the file lock —
// applies nothing: its bytes belong to a stream that already ended, and
// the close (or the new open) owns the buffer state now.
doc_sync_apply_under_file_lock :: proc(ds: ^Doc_Sync, item: ^Doc_Sync_Item) {
	h := editor.file_lock(ds.ed, item.rel_path)
	defer editor.file_release(ds.ed, item.rel_path)
	sync.mutex_lock(&h.mu)
	defer sync.mutex_unlock(&h.mu)

	sync.mutex_lock(&ds.mu)
	e := ds.docs[item.key]
	stale := e == nil || e.stream != item.stream
	skip := !stale && !item.is_open && e.has_version && e.last_applied_version >= item.version
	sync.mutex_unlock(&ds.mu)
	if stale || skip {
		return
	}

	editor.buffer_adopt(ds.ed, item.rel_path, item.text)

	// Record the applied version and wake the answered requests inside the
	// file-lock section, so the version never leads the buffer bytes.
	sync.mutex_lock(&ds.mu)
	if live := ds.docs[item.key]; live != nil && live.stream == item.stream {
		live.last_applied_version = item.version
		live.has_version = true
		sync.cond_broadcast(&ds.work)
	}
	sync.mutex_unlock(&ds.mu)
}

// doc_sync_worker_run is the single apply worker: park until a pending
// entry exists, apply entries one at a time, exit when doc_sync_stop marks
// the shutdown (queued-but-unpicked text dies with it — its requests wake
// to the stopping flag). It runs on a daemon-lifetime thread.
doc_sync_worker_run :: proc(ds: ^Doc_Sync) {
	for {
		sync.mutex_lock(&ds.mu)
		for !ds.is_stopping && !doc_sync_has_pending_locked(ds) {
			sync.cond_wait(&ds.work, &ds.mu)
		}
		if ds.is_stopping {
			sync.mutex_unlock(&ds.mu)
			return
		}
		item, has := doc_sync_take_locked(ds)
		sync.mutex_unlock(&ds.mu)
		if !has {
			continue
		}
		doc_sync_apply_item(ds, &item)
		doc_sync_item_destroy(ds, &item)
		// Frame-loop temp reset for this long-lived thread: the buffer and
		// listener paths scratch on context.temp_allocator, and a worker
		// that never resets would grow it for the daemon's lifetime.
		free_all(context.temp_allocator)
	}
}

// doc_sync_stop makes the worker exit after its current apply. Daemon
// shutdown calls it before joining the worker thread.
doc_sync_stop :: proc(ds: ^Doc_Sync) {
	sync.mutex_lock(&ds.mu)
	ds.is_stopping = true
	sync.cond_broadcast(&ds.work)
	sync.mutex_unlock(&ds.mu)
}

// The tree-sitter diagnostics publish: the ports the host implements, the
// per-document snapshot the off-thread fire pass works from, and the fire
// pass itself. The child never holds computation: at each fire it
// asks the daemon through the host ports — first whether a real language
// server is live for the document's language (live suppresses the
// tree-sitter answer; the real server's own diagnostics are the relay's,
// not this pass's), then for the tree-sitter answer — and publishes one
// notification per document. The version stamped on a publish is data
// flowing through the path: the diagnostics response carries the version
// its computation used, and the publish forwards it rather than inferring
// one from apply order.
package lspserver

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"

import "jsonrpc:jsonrpc"
import "jsonutil:jsonutil"
import "src:lsp"
import "src:util"

// Diag_Hit is one tree-sitter diagnostic: a byte span over the daemon's
// answered text plus its message. Both walk kinds (error, missing) publish
// as severity 1 (Error), so the kind does not cross this boundary.
Diag_Hit :: struct {
	start_byte: int,
	end_byte:   int,
	message:    string,
}

// Diagnostics_Result carries one svc.doc/diagnostics answer, already
// parsed by the host into byte spans. Mirrors Highlights_Result: the
// response's version is THE VERSION THE COMPUTATION USED; `decline` is the
// daemon's typed refusal (no_grammar, source_too_large); `failed` marks a
// fetch that never answered.
Diagnostics_Result :: struct {
	version:     i32,
	has_version: bool,
	decline:     string,
	truncated:   bool, // the answer was cut at the daemon face's bound
	diagnostics: []Diag_Hit, // ascending by start_byte; arena-owned
	failed:      bool,       // the fetch itself failed (err_message says why)
	err_message: string,
}

Diagnostics_Host :: proc(host: rawptr, uri: string, arena: mem.Allocator) -> Diagnostics_Result

// Readiness_Result answers "is a real language server live for this
// language". `failed` reads as not-live at the fire pass: the tree-sitter
// answer is the safe default, and the failure surfaces through the
// diagnostics fetch that follows it.
Readiness_Result :: struct {
	live:        bool,
	failed:      bool,
	err_message: string,
}

Readiness_Host :: proc(host: rawptr, language_id: string, arena: mem.Allocator) -> Readiness_Result

// Doc_Snapshot is one document's publish-side copy: every field is owned
// by the fire pass's arena and dead when the pass returns. The line index
// serves the utf-16 column conversion; it is built once per document per
// pass from the copied text, because the view's own index stays on the
// dispatch thread.
Doc_Snapshot :: struct {
	uri:         string,
	language_id: string,
	text:        string,
	version:     i32,
	encoding:    Position_Encoding,
	line_starts: []int,
}

// publish_mark arms (or re-arms) a document's debounce window at now_ms.
// The host's doc_open/doc_change callbacks call it after the daemon
// accepted the document state — marks only follow applied state, so a
// fire's fetch reads what the client last sent.
publish_mark :: proc(s: ^Server, uri: string, now_ms: i64) {
	sync.mutex_lock(&s.mu)
	debounce_mark(&s.deb, uri, now_ms)
	sync.mutex_unlock(&s.mu)
}

// publish_next_due reports the earliest pending due point (has=false when
// no document is waiting) so the host shell can sleep until the window
// ends instead of polling hot.
publish_next_due :: proc(s: ^Server) -> (at_ms: i64, has: bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return debounce_next_due(&s.deb)
}

// server_snapshot_doc copies what one publish needs — uri, language,
// text, version, negotiated encoding — into the caller's arena under s.mu.
// ok=false means the document left the view between the drain and the
// snapshot (its close publish already went out) or was evicted.
server_snapshot_doc :: proc(s: ^Server, uri: string, a: mem.Allocator) -> (snap: Doc_Snapshot, ok: bool) {
	sync.mutex_lock(&s.mu)
	if v := s.docs[uri]; v != nil {
		snap.uri = strings.clone(v.uri, a)
		snap.language_id = strings.clone(v.language_id, a)
		snap.text = strings.clone(v.text, a)
		snap.version = v.version
		snap.encoding = s.encoding
		ok = true
	}
	sync.mutex_unlock(&s.mu)
	return
}

// publish_due is one fire pass at now_ms: drain the windows that ended,
// then publish per document. Every shape — the tree-sitter answer, a
// decline, a fetch failure, the live-server suppression — lands as exactly
// one publish, and an empty publish is version-stamped like a full one.
// s.mu is held only for the drain, the per-document snapshots, and each
// document's final send (publish_due_flush); the host calls run outside
// it. `a` is the pass's scratch arena: the drained URIs, the snapshots,
// and the notification bodies all die with it (the conn's writer clones
// what it queues).
publish_due :: proc(s: ^Server, now_ms: i64, a: mem.Allocator) {
	sync.mutex_lock(&s.mu)
	if s.is_shutdown || s.exit != .Running {
		sync.mutex_unlock(&s.mu)
		return
	}
	uris := debounce_drain_due(&s.deb, now_ms, a)
	sync.mutex_unlock(&s.mu)

	for uri in uris {
		snap, ok := server_snapshot_doc(s, uri, a)
		if !ok {
			continue
		}
		snap.line_starts = util.line_start_offsets(snap.text, a)

		hits: []Diag_Hit
		version := snap.version
		if server_live_ls(s, snap.language_id, a) {
			// A live server owns this document's diagnostics now: publish
			// the empty set that clears the tree-sitter squiggles, stamped
			// with the view's version — the state being cleared.
		} else if s.diagnostics == nil {
			publish_note_once(s, uri, "the diagnostics port is unavailable; publishing empty")
		} else {
			dr := s.diagnostics(s.host, uri, a)
			if dr.failed {
				publish_note_once(s, uri, fmt.aprintf("diagnostics unavailable for %s: %s; publishing empty", uri, dr.err_message, allocator = a))
			} else if !dr.has_version {
				// Disk truth, not the synced buffer: the version home
				// answers false when the document's buffer was evicted (or
				// its first apply is still in flight), and the spans then
				// index bytes the open view does not mirror — the disk read
				// folds line endings and strips the BOM, so a bounds check
				// cannot rule the skew out. The currency rule applies:
				// publish the empty set stamped with the view's version; the
				// next change re-adopts the buffer and the following window
				// publishes real spans.
				publish_note_once(s, uri, fmt.aprintf("diagnostics for %s were computed over disk truth the open view does not mirror; publishing empty", uri, allocator = a))
			} else {
				if dr.decline != "" {
					publish_note_once(s, uri, fmt.aprintf("diagnostics declined for %s (%s); publishing empty", uri, dr.decline, allocator = a))
				} else if dr.truncated && len(dr.diagnostics) > 0 {
					publish_note_once(s, uri, fmt.aprintf("diagnostics for %s were cut at the daemon face's bound; the published list is partial", uri, allocator = a))
				}
				hits = dr.diagnostics
				// The response's version is the version the computation
				// used — has_version gated the branch above, so this is the
				// synced-buffer version the spans index.
				version = dr.version
				if !diag_spans_index_text(hits, snap.text) {
					// The answer's spans index the daemon's bytes, not this
					// view's: a version skew degrades to an empty publish
					// (the next window re-fires on the next change), the
					// same currency rule the tokens path applies to
					// captures.
					publish_note_once(s, uri, fmt.aprintf("diagnostics for %s do not index the document's current text; publishing empty", uri, allocator = a))
					hits = nil
				}
			}
		}
		publish_due_flush(s, uri, version, hits, snap, a)
	}
}

// publish_due_flush is the pass's per-uri tail: it re-enters s.mu,
// re-checks that the document is still in the view, and sends while the
// lock is held. The fetches before it run outside the lock, so a didClose
// can land mid-pass and free the view; the re-check keeps the ordering
// total against that close (handle_did_close frees the view, drops the
// due entry, and sends its close-clear under the same mutex): a pass that
// verified the view before the close still holds the mutex when it sends,
// so its publish precedes the clear, and a pass after the close finds no
// view and stays silent — the close-clear is the LAST publishDiagnostics
// a closed document can receive.
publish_due_flush :: proc(s: ^Server, uri: string, version: i32, hits: []Diag_Hit, snap: Doc_Snapshot, a: mem.Allocator) {
	sync.mutex_lock(&s.mu)
	if s.docs[uri] != nil {
		publish_diagnostics(s, uri, version, true, hits, snap, a)
	}
	sync.mutex_unlock(&s.mu)
}

// publish_close_clear sends the empty, unversioned diagnostic set that
// clears a closed document's stale squiggles. The specification makes
// publishDiagnostics.version optional and a close names no version, so the
// member is omitted. The caller holds s.mu: the send shares the lock with
// the pass's per-uri tail (publish_due_flush), which is what makes this
// clear the last publishDiagnostics the closed document receives. It runs
// immediately on the dispatch thread — not through the debounce window.
publish_close_clear :: proc(s: ^Server, uri: string, a: mem.Allocator) {
	publish_diagnostics(s, uri, 0, false, nil, Doc_Snapshot{uri = uri}, a)
}

// server_live_ls asks the readiness port whether a real language server
// runs for the language. An absent port or a document the view never
// learned a language for read as not-live: the tree-sitter answer is the
// safe default.
server_live_ls :: proc(s: ^Server, language_id: string, a: mem.Allocator) -> bool {
	if s.readiness == nil || language_id == "" {
		return false
	}
	rr := s.readiness(s.host, language_id, a)
	return rr.live
}

// publish_note_once latches the document's one-log-line-per-open note
// under s.mu and logs outside it, so a degraded document costs one line
// whether the note comes from the dispatch thread or the publish pass.
// The caller must NOT hold s.mu. A document closed in the meantime stays
// silent — its close publish already reported what mattered.
publish_note_once :: proc(s: ^Server, uri: string, msg: string) {
	sync.mutex_lock(&s.mu)
	view := s.docs[uri]
	skip := view == nil || view.has_note
	if view != nil && !view.has_note {
		view.has_note = true
	}
	sync.mutex_unlock(&s.mu)
	if !skip {
		log_message(s, msg)
	}
}

// publish_diagnostics sends one textDocument/publishDiagnostics
// notification: {uri, version?, diagnostics}. The send rides the conn's
// outbound writer, so a full queue drops the notification instead of
// blocking the pass (or the dispatch thread, for the close clear).
publish_diagnostics :: proc(s: ^Server, uri: string, version: i32, has_version: bool, hits: []Diag_Hit, snap: Doc_Snapshot, a: mem.Allocator) {
	params := jsonutil.json_object(3, a)
	jsonutil.obj_set(&params, "uri", jsonutil.json_string(uri))
	if has_version {
		jsonutil.obj_set(&params, "version", jsonutil.json_int(i64(version)))
	}
	items := make([]json.Value, len(hits), a)
	for hit, i in hits {
		items[i] = diagnostic_json(hit, snap, a)
	}
	jsonutil.obj_set(&params, "diagnostics", jsonutil.json_array(items, a))
	_ = jsonrpc.conn_notify(s.conn, lsp.METHOD_PUBLISH_DIAGNOSTICS, json.Value(json.Object(params)), a)
}

// diagnostic_json renders one hit: the LSP range from its byte span
// (converted through the snapshot's line index under a utf-16 connection),
// severity 1 (Error) for both walk kinds, and the aubade source tag.
diagnostic_json :: proc(hit: Diag_Hit, snap: Doc_Snapshot, a: mem.Allocator) -> json.Value {
	sl, sc, el, ec := diag_span_positions(snap.text, snap.line_starts, snap.encoding, hit.start_byte, hit.end_byte)

	start := jsonutil.json_object(2, a)
	jsonutil.obj_set(&start, "line", jsonutil.json_int(i64(sl)))
	jsonutil.obj_set(&start, "character", jsonutil.json_int(i64(sc)))
	end := jsonutil.json_object(2, a)
	jsonutil.obj_set(&end, "line", jsonutil.json_int(i64(el)))
	jsonutil.obj_set(&end, "character", jsonutil.json_int(i64(ec)))
	rng := jsonutil.json_object(2, a)
	jsonutil.obj_set_object(&rng, "start", start)
	jsonutil.obj_set_object(&rng, "end", end)

	d := jsonutil.json_object(4, a)
	jsonutil.obj_set_object(&d, "range", rng)
	jsonutil.obj_set(&d, "severity", jsonutil.json_int(1))
	jsonutil.obj_set(&d, "message", jsonutil.json_string(hit.message))
	jsonutil.obj_set(&d, "source", jsonutil.json_string("aubade"))
	return json.Value(json.Object(d))
}

// diag_spans_index_text reports whether every hit's byte span sits inside
// the snapshot's text — the currency check that keeps a skewed answer from
// publishing misplaced ranges.
diag_spans_index_text :: proc(hits: []Diag_Hit, text: string) -> bool {
	for hit in hits {
		if hit.start_byte < 0 || hit.end_byte < hit.start_byte || hit.end_byte > len(text) {
			return false
		}
	}
	return true
}

// diag_span_positions converts one byte span to LSP start/end positions.
// Under utf-8 the columns are byte columns (the negotiated unit is the
// byte); under utf-16 they go through the per-line conversion, with each
// line's text excluding its '\n' delimiter — the same discipline as the
// tokens encoder.
diag_span_positions :: proc(text: string, line_starts: []int, enc: Position_Encoding, start, end: int) -> (sl, sc, el, ec: int) {
	sl = diag_line_of(line_starts, start)
	el = diag_line_of(line_starts, end)
	switch enc {
	case .Utf8:
		sc = start - line_starts[sl]
		ec = end - line_starts[el]
	case .Utf16:
		sc = diag_utf16_col(text, line_starts, sl, start)
		ec = diag_utf16_col(text, line_starts, el, end)
	}
	return
}

// diag_line_of returns the index of the line holding byte offset off
// (line_starts ascending, first entry 0).
diag_line_of :: proc(line_starts: []int, off: int) -> int {
	lo, hi := 0, len(line_starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if line_starts[mid] <= off {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// diag_utf16_col converts one absolute byte offset to its line's UTF-16
// column through the line's own text (doc_line_span: the terminator's
// halves are no line characters, and offsets at or past the line's end
// clamp to its length inside the converter).
diag_utf16_col :: proc(text: string, line_starts: []int, line: int, off: int) -> int {
	line_text, _ := doc_line_span(text, line_starts, line)
	return util.byte_offset_to_utf16_col(line_text, off - line_starts[line])
}

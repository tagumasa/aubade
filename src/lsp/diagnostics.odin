// Bounded diagnostics store: the latest diagnostics JSON per document URI,
// fed by textDocument/publishDiagnostics. Data, not a cache — but the
// per-document set is bounded all the same: beyond DIAGNOSTICS_MAX_FILES
// the oldest first-published URI is evicted (servers republish live files,
// so eviction sheds the stale tail).
package lsp

import "core:mem"
import "core:strings"
import "core:sync"

import "src:symbol"

DIAGNOSTICS_MAX_FILES :: 500

// Diag_Entry is the stored latest set for one URI plus the document version
// it was published for — the watermark behind the versionSupport drop rule.
// A fresh empty set clears the payload but KEEPS the entry as a bare
// watermark (json == "" — the marker): a late publication tagged below the
// watermark can only be dropped while the watermark lives in the store.
// The entry dies outright at document close (a new open epoch restarts
// versions at 1, so a surviving watermark would drop its early
// publications) or at eviction.
Diag_Entry :: struct {
	json:    string, // owned diagnostics-array JSON; "" = bare watermark marker
	version: i64, // last applied document version; -1 when unversioned
}

Diagnostics_Store :: struct {
	mu:        sync.Mutex,
	latest:    map[string]Diag_Entry, // uri -> owned set + version (keys owned too)
	order:     [dynamic]string,   // first-publish order, oldest first (owned)
	allocator: mem.Allocator,
}

diagnostics_store_init :: proc(s: ^Diagnostics_Store, a := context.allocator) {
	s^ = {
		latest = make(map[string]Diag_Entry, 64, a),
		order  = make([dynamic]string, 0, 64, a),
		allocator  = a,
	}
}

diagnostics_store_destroy :: proc(s: ^Diagnostics_Store) {
	sync.mutex_lock(&s.mu)
	// Keys and values are both store-owned clones; freeing only the values
	// would leak one URI per tracked document. Collect then free — freeing
	// the current key mid-iteration is treated as map mutation
	// (conn_destroy's rule) — the order rows are owned clones too.
	keys := make([dynamic]string, 0, len(s.latest) + len(s.order), context.temp_allocator)
	vals := make([dynamic]string, 0, len(s.latest), context.temp_allocator)
	for key, e in s.latest {
		append(&keys, key)
		append(&vals, e.json)
	}
	for uri in s.order {
		append(&keys, uri)
	}
	delete(s.latest)
	delete(s.order)
	for v in vals {
		if v != "" { // bare watermark markers own no payload bytes
			delete(v, s.allocator)
		}
	}
	for k in keys {
		delete(k, s.allocator)
	}
	delete(keys)
	delete(vals)
	sync.mutex_unlock(&s.mu)
}

// canonical_uri maps a server-reported file URI onto the local encoder's
// form, so store keys and reader lookups agree no matter how the server
// spelled the URI (percent-encoded non-ASCII, %23, a lowercase drive).
// The result is always owned by `a` (verbatim and undecodable inputs are
// cloned); non-file schemes keep their verbatim spelling.
canonical_uri :: proc(uri: string, a: mem.Allocator) -> string {
	if !strings.has_prefix(uri, "file://") {
		return strings.clone(uri, a)
	}
	path, ok := uri_to_path(uri, context.temp_allocator)
	if !ok || path == "" {
		return strings.clone(uri, a)
	}
	out := symbol.file_uri(path, a)
	delete(path, context.temp_allocator)
	return out
}

// diagnostics_store_set records the latest set for a URI. An empty array
// clears the payload but keeps the entry as a bare watermark (servers
// publish empty sets when diagnostics resolve). The key is canonicalized
// to the local URI form first (see canonical_uri); the stored JSON, the
// map key, and the order entry are owned by the store's allocator —
// callers keep ownership of their inputs (the producer passes a view into
// the notification's per-message arena, which dies right after dispatch).
//
// `version` is the publication's document version, -1 when it carried
// none. The client declares publishDiagnostics.versionSupport, so a
// publication tagged with a version strictly older than the last applied
// one for the URI is a stale snapshot (an async server's superseded
// computation finishing late) and is dropped — including one arriving
// after an empty clear, which is exactly why the watermark survives the
// clear; an untagged publication always applies and leaves the watermark
// alone.
diagnostics_store_set :: proc(s: ^Diagnostics_Store, server_uri: string, diagnostics_json: string, version: i64 = -1) {
	uri := canonical_uri(server_uri, s.allocator)
	sync.mutex_lock(&s.mu)
	if e, found := s.latest[uri]; found {
		if version >= 0 && e.version >= 0 && version < e.version {
			sync.mutex_unlock(&s.mu)
			delete(uri, s.allocator)
			return
		}
		if diagnostics_json == "[]" {
			// A fresh empty set clears the payload but keeps the entry as a
			// bare watermark: the document is still open, and a late
			// publication tagged below this version must still find the
			// watermark to be dropped — the drop rule runs only against a
			// stored entry. The order row stays too, so the marker ages in
			// eviction order like any entry (dropping the row here would
			// desynchronize the cap bookkeeping).
			if e.json != "" {
				delete(e.json, s.allocator)
			}
			e.json = ""
			if version >= 0 {
				e.version = version
			}
			s.latest[uri] = e
		} else {
			// The old value dies here (a marker's json is empty — nothing
			// to free, the entry turns live again); assigning onto the
			// existing key keeps the stored (owned) key bytes.
			if e.json != "" {
				delete(e.json, s.allocator)
			}
			e.json = strings.clone(diagnostics_json, s.allocator)
			if version >= 0 {
				e.version = version
			}
			s.latest[uri] = e
		}
		sync.mutex_unlock(&s.mu)
		delete(uri, s.allocator)
		return
	}
	if diagnostics_json == "[]" {
		sync.mutex_unlock(&s.mu)
		delete(uri, s.allocator)
		return
	}
	if len(s.latest) >= DIAGNOSTICS_MAX_FILES && len(s.order) > 0 {
		oldest := s.order[0]
		if e, f := s.latest[oldest]; f {
			if e.json != "" {
				delete(e.json, s.allocator)
			}
		}
		stored, _ := delete_key(&s.latest, oldest)
		delete(stored, s.allocator)
		delete(s.order[0], s.allocator)
		ordered_remove(&s.order, 0)
	}
	// The map key and the order entry own independent clones: destroy and
	// eviction free both, and a shared string would double-free.
	s.latest[strings.clone(uri, s.allocator)] = {
		json    = strings.clone(diagnostics_json, s.allocator),
		version = version,
	}
	append(&s.order, strings.clone(uri, s.allocator))
	sync.mutex_unlock(&s.mu)
	delete(uri, s.allocator)
}

// diagnostics_clear_locked removes a URI's stored entry and its order row
// outright — the document-close path only (the store mutex must be held):
// the document is gone and its next open epoch restarts versions at 1, so
// a watermark surviving the close would drop the new epoch's early
// publications. The empty-array branch of store_set does not come through
// here: it keeps the entry as a bare watermark. A no-op for untracked
// URIs.
diagnostics_clear_locked :: proc(s: ^Diagnostics_Store, uri: string) {
	e, found := s.latest[uri]
	if !found {
		return
	}
	if e.json != "" {
		delete(e.json, s.allocator)
	}
	stored, _ := delete_key(&s.latest, uri)
	delete(stored, s.allocator)
	// for binds value-then-index: u is the stored URI clone.
	for u, i in s.order {
		if u == uri {
			delete(u, s.allocator)
			ordered_remove(&s.order, i)
			break
		}
	}
}

// diagnostics_store_clear drops a URI's stored set — the client-side
// close path for a document that is no longer tracked (doc_close). The
// URI is canonicalized like store_set's, so both spellings agree.
diagnostics_store_clear :: proc(s: ^Diagnostics_Store, server_uri: string) {
	uri := canonical_uri(server_uri, s.allocator)
	sync.mutex_lock(&s.mu)
	diagnostics_clear_locked(s, uri)
	sync.mutex_unlock(&s.mu)
	delete(uri, s.allocator)
}

// diagnostics_store_count snapshots the number of URIs carrying a live
// set — bare watermark markers for still-open documents are not tracked
// sets and are not counted.
diagnostics_store_count :: proc(s: ^Diagnostics_Store) -> int {
	sync.mutex_lock(&s.mu)
	n := 0
	for _, e in s.latest {
		if e.json != "" {
			n += 1
		}
	}
	sync.mutex_unlock(&s.mu)
	return n
}

// diagnostics_store_get snapshots the latest diagnostics-array JSON for a
// URI, cloned into `a` (the caller owns the clone). ok=false when the URI
// is untracked, its set was cleared, or only a bare watermark marker
// remains.
diagnostics_store_get :: proc(s: ^Diagnostics_Store, uri: string, a := context.allocator) -> (diagnostics_json: string, ok: bool) {
	sync.mutex_lock(&s.mu)
	out := ""
	live := false
	if e, found := s.latest[uri]; found && e.json != "" {
		out = strings.clone(e.json, a)
		live = true
	}
	sync.mutex_unlock(&s.mu)
	return out, live
}

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
Diag_Entry :: struct {
	json:    string, // owned diagnostics-array JSON
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
		delete(v, s.allocator)
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
// clears the entry (servers publish empty sets when diagnostics resolve).
// The key is canonicalized to the local URI form first (see
// canonical_uri); the stored JSON, the map key, and the order entry are
// owned by the store's allocator — callers keep ownership of their inputs
// (the producer passes a view into the notification's per-message arena,
// which dies right after dispatch).
//
// `version` is the publication's document version, -1 when it carried
// none. The client declares publishDiagnostics.versionSupport, so a
// publication tagged with a version strictly older than the last applied
// one for the URI is a stale snapshot (an async server's superseded
// computation finishing late) and is dropped; an untagged publication
// always applies and leaves the watermark alone.
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
			// An empty set clears the entry; a stale order row would
			// desynchronize the eviction bookkeeping (the cap silently
			// grows). clear_locked frees the stored value, key, and
			// order row itself.
			diagnostics_clear_locked(s, uri)
		} else {
			// The old value dies here; assigning onto the existing key
			// keeps the stored (owned) key bytes.
			delete(e.json, s.allocator)
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
			delete(e.json, s.allocator)
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

// diagnostics_clear_locked removes a URI's stored set and its order row;
// the store mutex must be held (the empty-array branch of store_set and
// the document-close path share it). A no-op for untracked URIs.
diagnostics_clear_locked :: proc(s: ^Diagnostics_Store, uri: string) {
	e, found := s.latest[uri]
	if !found {
		return
	}
	delete(e.json, s.allocator)
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

// diagnostics_store_count snapshots the number of tracked URIs.
diagnostics_store_count :: proc(s: ^Diagnostics_Store) -> int {
	sync.mutex_lock(&s.mu)
	n := len(s.latest)
	sync.mutex_unlock(&s.mu)
	return n
}

// diagnostics_store_get snapshots the latest diagnostics-array JSON for a
// URI, cloned into `a` (the caller owns the clone). ok=false when the URI
// is untracked or its set was cleared.
diagnostics_store_get :: proc(s: ^Diagnostics_Store, uri: string, a := context.allocator) -> (diagnostics_json: string, ok: bool) {
	sync.mutex_lock(&s.mu)
	e, found := s.latest[uri]
	out := ""
	if found {
		out = strings.clone(e.json, a)
	}
	sync.mutex_unlock(&s.mu)
	return out, found
}
